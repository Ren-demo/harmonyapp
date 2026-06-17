import { MqttService } from './MqttService';
import { FanTelemetry, FanTopics, FanStatus } from '../models/FanDevice';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';

const TAG = 'FanService';
const DOMAIN = 0x0001;

/**
 * 风扇业务服务 — 单例 + 响应式状态管理
 */
@ObservedV2
export class FanService {
  // ====== 单例 ======
  private static instance: FanService;

  static getInstance(): FanService {
    if (!FanService.instance) {
      FanService.instance = new FanService();
    }
    return FanService.instance;
  }

  private constructor() {
  }

  // ====== 依赖 ======
  private mqttService: MqttService = new MqttService();

  // ====== 响应式状态 ======
  @Trace power: boolean = false;       // 风扇电源状态
  @Trace connected: boolean = false;   // MQTT 连接状态
  @Trace connecting: boolean = false;  // 正在连接中
  @Trace errorMessage: string = '';    // 错误信息
  @Trace statusText: string = '未连接'; // 状态描述文字
  @Trace reconnecting: boolean = false;  // 是否处于重连模式

  // ====== 重连控制 ======
  private reconnectTimer: number = -1;
  private reconnectAttempts: number = 0;
  private readonly maxReconnectDelay: number = 5000;  // 最大重连间隔 10s
  private readonly baseReconnectDelay: number = 5000;   // 基础重连间隔 5s
  private dialogCycleTimer: number = -1;
  private readonly dialogCycleInterval: number = 10000; // 弹窗周期 10s
  private brokerUrl: string = '';

  /**
   * 获取风扇当前状态（派生）
   */
  getStatus(): FanStatus {
    if (!this.connected) {
      return FanStatus.OFFLINE;
    }
    return this.power ? FanStatus.RUNNING : FanStatus.STOPPED;
  }

  /**
   * 获取状态描述文字
   */
  getStatusText(): string {
    if (this.connecting || this.reconnecting) {
      return '正在连接...';
    }
    switch (this.getStatus()) {
      case FanStatus.RUNNING:
        return '运行中';
      case FanStatus.STOPPED:
        return '已停止';
      case FanStatus.OFFLINE:
        return '未连接';
    }
  }

  /**
   * 更新状态描述文字（响应式追踪）
   */
  private updateStatusText(): void {
    this.statusText = this.getStatusText();
  }

  /**
   * 连接 MQTT Broker
   */
  async connect(brokerUrl: string, clientId: string = 'harmony-fan-app'): Promise<void> {
    this.brokerUrl = brokerUrl;
    this.connecting = true;
    hilog.info(DOMAIN, TAG, `FanService 开始连接: ${brokerUrl}`);

    try {
      await this.mqttService.connect(brokerUrl, clientId);
      this.connected = true;
      this.connecting = false;
      this.reconnecting = false;
      this.errorMessage = '';
      this.reconnectAttempts = 0;
      this.updateStatusText();
      this.stopDialogCycle();

      // 注册消息回调
      this.mqttService.onMessageArrived((topic: string, payload: string) => {
        this.handleMessage(topic, payload);
      });

      // 注册断开回调
      this.mqttService.onConnectionLost(() => {
        this.connected = false;
        this.errorMessage = '网络连接异常';
        this.updateStatusText();
        this.showToast('网络连接异常，正在重连...');
        this.startReconnect();
      });

      // 订阅遥测和状态主题
      await this.mqttService.subscribe(FanTopics.TELEMETRY, 1);
      await this.mqttService.subscribe(FanTopics.STATUS, 1);

      hilog.info(DOMAIN, TAG, 'FanService 连接成功，已订阅主题');
      this.showToast('已连接到智能风扇');

    } catch (err) {
      hilog.error(DOMAIN, TAG, `FanService 连接失败: ${JSON.stringify(err)}`);
      this.connected = false;
      this.connecting = false;
      this.errorMessage = '网络连接异常';
      this.updateStatusText();
      this.showToast('网络连接异常');
      this.startReconnect();
    }
  }

  /**
   * 断开连接
   */
  async disconnect(): Promise<void> {
    this.stopReconnect();
    this.stopDialogCycle();
    this.reconnecting = false;
    await this.mqttService.disconnect();
    this.connected = false;
    this.updateStatusText();
    hilog.info(DOMAIN, TAG, 'FanService 已断开');
  }

  /**
   * 切换风扇电源（乐观更新）
   */
  async togglePower(): Promise<void> {
    if (!this.connected) {
      this.showToast('设备未连接');
      return;
    }

    // 乐观更新 — 先更新 UI，设备状态以遥测回传为准
    const previousPower = this.power;
    this.power = !this.power;
    this.updateStatusText();

    const newPower = this.power ? 'on' : 'off';
    const command = JSON.stringify({
      action: 'set_power',
      value: newPower
    });

    try {
      await this.mqttService.publish(FanTopics.COMMAND, command, 1);
      hilog.info(DOMAIN, TAG, `发送电源指令: ${newPower}`);
    } catch (err) {
      // 发送失败，回滚状态
      this.power = previousPower;
      this.updateStatusText();
      hilog.error(DOMAIN, TAG, `发送电源指令失败: ${JSON.stringify(err)}`);
      this.showToast('指令发送失败');
    }
  }

  /**
   * 处理收到的 MQTT 消息
   */
  private handleMessage(topic: string, payload: string): void {
    hilog.info(DOMAIN, TAG, `收到消息 topic=${topic}, payload=${payload}`);

    try {
      if (topic === FanTopics.TELEMETRY) {
        const telemetry: FanTelemetry = JSON.parse(payload) as FanTelemetry;
        this.power = telemetry.power === 'on';
        this.updateStatusText();
        hilog.info(DOMAIN, TAG, `遥测更新: power=${this.power}`);
      } else if (topic === FanTopics.STATUS) {
        this.connected = payload === 'online';
        if (this.connected) {
          this.errorMessage = '';
          this.reconnectAttempts = 0;
          this.stopReconnect();
          this.showToast('已重新连接');
        } else {
          this.errorMessage = '网络连接异常';
        }
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `消息解析失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 重连（指数退避）
   */
  private startReconnect(): void {
    if (this.reconnectTimer !== -1) {
      return; // 已在重连中
    }

    this.reconnecting = true;
    this.startDialogCycle();

    const delay = Math.min(
      this.baseReconnectDelay * Math.pow(2, this.reconnectAttempts),
      this.maxReconnectDelay
    );
    this.reconnectAttempts++;

    hilog.info(DOMAIN, TAG, `将在 ${delay}ms 后重连 (第 ${this.reconnectAttempts} 次)`);

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connect(this.brokerUrl);
    }, delay);
  }

  /**
   * 停止重连
   */
  private stopReconnect(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.reconnecting = false;
    this.stopDialogCycle();
  }

  /**
   * 启动弹窗周期
   */
  private startDialogCycle(): void {
    if (this.dialogCycleTimer !== -1) {
      return; // 已在弹窗周期中
    }
    // 立即显示第一次弹窗
    this.triggerReconnectDialog();
    // 按周期重复
    this.dialogCycleTimer = setInterval(() => {
      this.triggerReconnectDialog();
    }, this.dialogCycleInterval);
  }

  /**
   * 停止弹窗周期
   */
  private stopDialogCycle(): void {
    if (this.dialogCycleTimer !== -1) {
      clearInterval(this.dialogCycleTimer);
      this.dialogCycleTimer = -1;
    }
  }

  /**
   * 触发重连提示（底部 Toast）
   */
  private triggerReconnectDialog(): void {
    this.showToast('网络连接异常，正在重连...');
  }

  /**
   * 显示 Toast 提示
   */
  private showToast(message: string): void {
    try {
      promptAction.openToast({
        message: message,
        duration: 2000
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, `Toast 失败: ${JSON.stringify(err)}`);
    }
  }
}
