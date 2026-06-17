import { MqttService } from './MqttService';
import { FanTelemetry, FanStatusPayload, FanStatusQuery, FanCommand, FindDevicesQuery, DevicesResponse, FanTopics, FanStatus } from '../models/FanDevice';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';

const TAG = 'FanService';
const DOMAIN = 0x0001;

/**
 * 风扇业务服务
 */
@ObservedV2
export class FanService {
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
  @Trace fanRunning: boolean = false;  // 风扇实际运行状态（来自 fan_status 主题）
  @Trace isProcessing: boolean = false;  // 操作进行中，锁定 UI
  @Trace operationStatus: string = '';   // 操作阶段描述文字
  @Trace powerTarget: boolean = false;   // 期望达到的电源状态
  @Trace connected: boolean = false;   // MQTT 连接状态
  @Trace connecting: boolean = false;  // 正在连接中
  @Trace errorMessage: string = '';    // 错误信息
  @Trace statusText: string = '未连接'; // 状态描述文字
  @Trace reconnecting: boolean = false;  // 是否处于重连模式
  @Trace refreshing: boolean = false;       // 是否正在刷新状态查询
  @Trace lastRefreshResult: string = '';    // 最近刷新结果: 'success' | 'fail' | ''
  @Trace deviceOnline: boolean = false;     // 风扇硬件设备是否在线（来自设备发现）
  @Trace globalRefreshing: boolean = false;  // 是否正在全局刷新
  @Trace lastGlobalRefreshResult: string = '';  // 全局刷新结果: 'success' | 'fail' | ''

  // ====== 操作确认控制 ======
  private confirmCallback: ((success: boolean) => void) | null = null;
  private readonly CONTROL_TIMEOUT_MS: number = 3000;
  private readonly QUERY_TIMEOUT_MS: number = 2000;
  private readonly REFRESH_TIMEOUT_MS: number = 2000;

  // ====== 刷新控制 ======
  private refreshTimerId: number = -1;

  // ====== 设备发现与轮询 ======
  private devicePollTimerId: number = -1;
  private readonly DEVICE_POLL_INTERVAL: number = 10000;      // 后台轮询间隔 10s
  private readonly DEVICE_CHECK_TIMEOUT: number = 2000;       // 设备发现超时 2s
  private deviceCheckTimerId: number = -1;                    // 设备发现超时定时器

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
    if (!this.deviceOnline) {
      return FanStatus.OFFLINE;  // MQTT 已连但设备离线
    }
    return this.fanRunning ? FanStatus.RUNNING : FanStatus.STOPPED;
  }

  /**
   * 获取状态描述文字
   */
  getStatusText(): string {
    if (this.isProcessing && this.operationStatus) {
      return this.operationStatus;
    }
    if (this.globalRefreshing) {
      return '刷新中...';
    }
    if (this.connecting || this.reconnecting) {
      return '正在连接...';
    }
    if (this.connected && !this.deviceOnline) {
      return '设备离线';
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
        this.deviceOnline = false;
        this.fanRunning = false;
        this.errorMessage = '网络连接异常';

        // 停止设备轮询
        this.stopDevicePolling();

        // 取消进行中的操作
        if (this.confirmCallback) {
          this.confirmCallback(false);
        }
        if (this.isProcessing) {
          this.isProcessing = false;
          this.operationStatus = '';
          this.powerTarget = this.power;
          this.showToast('连接断开，操作失败');
        }

        this.updateStatusText();
        this.showToast('网络连接异常，正在重连...');
        this.startReconnect();
      });

      // 订阅遥测和状态主题
      await this.mqttService.subscribe(FanTopics.TELEMETRY, 1);
      await this.mqttService.subscribe(FanTopics.STATUS, 1);
      await this.mqttService.subscribe(FanTopics.FAN_STATUS, 1);
      await this.mqttService.subscribe(FanTopics.DEVICES_RESPONSE, 1);

      // 连接后自动查询设备列表 + 风扇状态
      await this.discoverDevices(true);
      await this.queryFanStatus(true);

      // 启动后台设备轮询（10s 间隔，静默）
      this.startDevicePolling();

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
    this.stopDevicePolling();
    this.reconnecting = false;
    await this.mqttService.disconnect();
    this.connected = false;
    this.deviceOnline = false;
    this.fanRunning = false;
    this.updateStatusText();
    hilog.info(DOMAIN, TAG, 'FanService 已断开');
  }

  /**
   * 切换风扇电源（确认式请求-响应流程）
   *   1. 发送指令到 app_control_fan
   *   2. 等待 fan_status 确认（3s）
   *   3. 超时则查询 quary_fan_status，再等 2s
   *   4. 仍无响应 → 操作失败，开关回弹
   */
  async togglePower(): Promise<void> {
    if (!this.connected) {
      this.showToast('设备未连接');
      return;
    }
    if (this.isProcessing) {
      this.showToast('操作进行中，请稍候');
      return;
    }

    this.isProcessing = true;
    this.powerTarget = !this.power;
    this.operationStatus = '正在发送指令...';
    this.updateStatusText();
    hilog.info(DOMAIN, TAG, `togglePower: target=${this.powerTarget ? 'on' : 'off'}`);

    try {
      // 阶段 1: 发送控制指令到 app_control_fan
      const command: FanCommand = {
        action: 'set_power',
        value: this.powerTarget ? 'on' : 'off'
      };
      await this.mqttService.publish(FanTopics.APP_CONTROL_FAN, JSON.stringify(command), 1);
      hilog.info(DOMAIN, TAG, `已发送控制指令到 app_control_fan: ${command.value}`);

      // 阶段 2: 等待 fan_status 确认（3s 超时）
      this.operationStatus = '等待风扇响应...';
      this.updateStatusText();
      let confirmed = await this.waitForConfirmation(this.CONTROL_TIMEOUT_MS);
      if (confirmed) {
        this.onOperationSuccess();
        return;
      }

      // 阶段 3: 超时，向 quary_fan_status 查询
      this.operationStatus = '响应超时，正在查询状态...';
      this.updateStatusText();
      await this.queryFanStatus(true);
      confirmed = await this.waitForConfirmation(this.QUERY_TIMEOUT_MS);
      if (confirmed) {
        this.onOperationSuccess();
        return;
      }

      // 阶段 4: 最终失败
      this.onOperationFailure('设备无响应，操作失败');

    } catch (err) {
      hilog.error(DOMAIN, TAG, `togglePower 异常: ${JSON.stringify(err)}`);
      this.onOperationFailure('指令发送失败');
    }
  }

  /**
   * 等待 fan_status 确认（Promise 桥接 handleMessage 回调）
   */
  private waitForConfirmation(timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      // 可能已有匹配的 fan_status 到达
      if (this.fanRunning === this.powerTarget) {
        resolve(true);
        return;
      }
      const timerId = setTimeout(() => {
        this.confirmCallback = null;
        resolve(false);
      }, timeoutMs);
      this.confirmCallback = (success: boolean) => {
        clearTimeout(timerId);
        this.confirmCallback = null;
        resolve(success);
      };
    });
  }

  /**
   * 操作成功：确认电源状态，清理状态
   */
  private onOperationSuccess(): void {
    this.power = this.powerTarget;
    this.isProcessing = false;
    this.operationStatus = '';
    this.confirmCallback = null;
    this.updateStatusText();
    this.showToast(this.power ? '风扇已开启' : '风扇已关闭');
    hilog.info(DOMAIN, TAG, `操作成功: power=${this.power}`);
  }

  /**
   * 操作失败：回弹状态
   */
  private onOperationFailure(reason: string): void {
    this.isProcessing = false;
    this.operationStatus = '';
    this.confirmCallback = null;
    this.powerTarget = this.power;
    this.updateStatusText();
    this.showToast(reason);
    hilog.warn(DOMAIN, TAG, `操作失败: ${reason}`);
  }

  /**
   * 主动查询风扇运行状态
   * @param silent 静默模式（不显示 toast），用于自动查询场景
   */
  async queryFanStatus(silent: boolean = false): Promise<void> {
    if (!this.connected) {
      if (!silent) {
        this.showToast('设备未连接');
      }
      return;
    }

    // 手动刷新：开始加载状态
    if (!silent) {
      this.refreshing = true;
      this.lastRefreshResult = '';
      this.clearRefreshTimer();
    }

    const query: FanStatusQuery = {
      action: 'query',
      timestamp: Date.now()
    };

    try {
      await this.mqttService.publish(FanTopics.QUERY_FAN_STATUS, JSON.stringify(query), 1);
      hilog.info(DOMAIN, TAG, '已发送风扇状态查询');

      // 手动刷新：启动超时定时器
      if (!silent) {
        this.refreshTimerId = setTimeout(() => {
          this.refreshTimerId = -1;
          this.onRefreshFail();
        }, this.REFRESH_TIMEOUT_MS);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `发送风扇状态查询失败: ${JSON.stringify(err)}`);
      if (!silent) {
        this.onRefreshFail();
        this.showToast('状态查询失败');
      }
    }
  }

  /**
   * 刷新成功回调
   */
  private onRefreshSuccess(): void {
    this.clearRefreshTimer();
    this.refreshing = false;
    this.lastRefreshResult = 'success';
    // 0.8s 后清除结果标记
    setTimeout(() => {
      this.lastRefreshResult = '';
    }, 800);
  }

  /**
   * 刷新失败回调
   */
  private onRefreshFail(): void {
    this.clearRefreshTimer();
    this.refreshing = false;
    this.lastRefreshResult = 'fail';
    // 0.8s 后清除结果标记
    setTimeout(() => {
      this.lastRefreshResult = '';
    }, 800);
  }

  /**
   * 清除刷新超时定时器
   */
  private clearRefreshTimer(): void {
    if (this.refreshTimerId !== -1) {
      clearTimeout(this.refreshTimerId);
      this.refreshTimerId = -1;
    }
  }

  /**
   * 设备发现 — 查询哪些设备在线
   * @param silent 静默模式（后台轮询/初始化），不触发 UI 加载动画和 toast
   */
  async discoverDevices(silent: boolean = false): Promise<void> {
    if (!this.connected) {
      return;
    }

    if (!silent) {
      this.globalRefreshing = true;
      this.lastGlobalRefreshResult = '';
      this.clearDeviceCheckTimer();
    }

    const query: FindDevicesQuery = {
      action: 'discover',
      timestamp: Date.now()
    };

    try {
      await this.mqttService.publish(FanTopics.FIND_DEVICES, JSON.stringify(query), 1);
      hilog.info(DOMAIN, TAG, `已发送设备发现查询 (${silent ? '静默' : '手动'})`);

      if (!silent) {
        this.deviceCheckTimerId = setTimeout(() => {
          this.deviceCheckTimerId = -1;
          this.onGlobalRefreshFail();
        }, this.DEVICE_CHECK_TIMEOUT);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, `设备发现查询失败: ${JSON.stringify(err)}`);
      if (!silent) {
        this.onGlobalRefreshFail();
        this.showToast('设备查询失败');
      }
    }
  }

  /**
   * 全局刷新 — 用户手动触发 (同时发现设备 + 查询风扇状态)
   */
  async globalRefresh(): Promise<void> {
    if (!this.connected) {
      this.showToast('设备未连接');
      return;
    }
    if (this.globalRefreshing) {
      return; // 已在刷新中
    }

    this.globalRefreshing = true;
    this.lastGlobalRefreshResult = '';

    // 并行执行设备发现和风扇状态查询
    await Promise.all([
      this.discoverDevices(false),
      this.queryFanStatus(false)
    ]);

    // 两个操作各自由 onRefreshSuccess/Fail 和 onGlobalRefreshSuccess/Fail 处理
    // 这里需要协调：等两者都完成后统一反馈
    // 简化处理：由各回调独立反馈，globalRefreshing 在最后一个回调中清除
  }

  /**
   * 设备发现成功
   */
  private onDeviceDiscoverySuccess(): void {
    this.clearDeviceCheckTimer();
    if (!this.globalRefreshing) {
      return; // 静默模式，无需 UI 反馈
    }
    // 与 queryFanStatus 的结果合并判断
    this.checkGlobalRefreshComplete();
  }

  /**
   * 全局刷新失败
   */
  private onGlobalRefreshFail(): void {
    this.clearDeviceCheckTimer();
    this.globalRefreshing = false;
    this.lastGlobalRefreshResult = 'fail';
    this.refreshing = false;   // 同时停止子刷新状态
    this.lastRefreshResult = '';
    setTimeout(() => {
      this.lastGlobalRefreshResult = '';
    }, 800);
    this.showToast('设备无响应');
  }

  /**
   * 检查全局刷新是否完全完成
   */
  private checkGlobalRefreshComplete(): void {
    // 简化：设备发现成功就算全局刷新成功
    this.globalRefreshing = false;
    this.lastGlobalRefreshResult = 'success';
    setTimeout(() => {
      this.lastGlobalRefreshResult = '';
    }, 800);
  }

  /**
   * 清除设备发现超时定时器
   */
  private clearDeviceCheckTimer(): void {
    if (this.deviceCheckTimerId !== -1) {
      clearTimeout(this.deviceCheckTimerId);
      this.deviceCheckTimerId = -1;
    }
  }

  /**
   * 启动后台设备轮询（10s 间隔，静默）
   */
  startDevicePolling(): void {
    if (this.devicePollTimerId !== -1) {
      return; // 已在轮询中
    }
    hilog.info(DOMAIN, TAG, `启动设备轮询，间隔 ${this.DEVICE_POLL_INTERVAL}ms`);
    this.devicePollTimerId = setInterval(() => {
      this.discoverDevices(true);
    }, this.DEVICE_POLL_INTERVAL);
  }

  /**
   * 停止后台设备轮询
   */
  stopDevicePolling(): void {
    if (this.devicePollTimerId !== -1) {
      clearInterval(this.devicePollTimerId);
      this.devicePollTimerId = -1;
      hilog.info(DOMAIN, TAG, '已停止设备轮询');
    }
  }

  /**
   * 处理收到的 MQTT 消息
   */
  private handleMessage(topic: string, payload: string): void {
    hilog.info(DOMAIN, TAG, `收到消息 topic=${topic}, payload=${payload}`);

    try {
      if (topic === FanTopics.DEVICES_RESPONSE) {
        const response: DevicesResponse = JSON.parse(payload) as DevicesResponse;
        // 检查风扇设备(代号=1)是否在线
        const fanDevice = response.devices?.find((d) => d.id === '1');
        const wasOnline = this.deviceOnline;
        this.deviceOnline = (fanDevice?.status === 'online');
        hilog.info(DOMAIN, TAG, `设备发现响应: 风扇${this.deviceOnline ? '在线' : '离线'}`);

        // 如果从离线变为在线，更新 UI 状态
        if (!wasOnline && this.deviceOnline) {
          this.updateStatusText();
        }

        // 清除设备发现超时定时器并通知全局刷新
        if (this.globalRefreshing) {
          this.onDeviceDiscoverySuccess();
        }
      } else if (topic === FanTopics.TELEMETRY) {
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
      } else if (topic === FanTopics.FAN_STATUS) {
        const statusPayload: FanStatusPayload = JSON.parse(payload) as FanStatusPayload;
        this.fanRunning = (statusPayload.status === 'running');
        this.updateStatusText();
        hilog.info(DOMAIN, TAG, `风扇运行状态更新: running=${this.fanRunning}`);

        // 如果正在手动刷新，标记刷新成功
        if (this.refreshing) {
          this.onRefreshSuccess();
        }

        // 如果有待确认的操作且状态匹配目标，触发成功回调
        if (this.confirmCallback && this.fanRunning === this.powerTarget) {
          hilog.info(DOMAIN, TAG, 'fan_status 确认匹配，触发操作成功回调');
          this.confirmCallback(true);
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
