import { MqttAsync } from '@ohos/mqtt';
import type {
  MqttClient,
  MqttClientOptions,
  MqttConnectOptions,
  MqttSubscribeOptions,
  MqttPublishOptions,
  MqttMessage
} from '@ohos/mqtt';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buffer } from '@kit.ArkTS';

const TAG = 'MqttService';
const DOMAIN = 0x0001;

/**
 * MQTT 连接服务 — 封装 @ohos/mqtt 客户端
 */
export class MqttService {
  private client: MqttClient | null = null;
  private messageCallback: ((topic: string, payload: string) => void) | null = null;
  private connectionLostCallback: (() => void) | null = null;

  /**
   * 创建客户端并连接 MQTT Broker
   */
  async connect(brokerUrl: string, clientId: string): Promise<void> {
    // 清理旧连接
    await this.cleanup();

    try {
      hilog.info(DOMAIN, TAG, `创建 MQTT 客户端: ${brokerUrl}, clientId: ${clientId}`);

      // 创建客户端
      const clientOpts: MqttClientOptions = {
        url: brokerUrl,
        clientId: clientId,
        persistenceType: 1 // 内存持久化
      };
      const mqttClient = MqttAsync.createMqtt(clientOpts);
      this.client = mqttClient;

      // 注册消息回调
      mqttClient.messageArrived((err: Error, msg: MqttMessage) => {
        if (err) {
          hilog.error(DOMAIN, TAG, `messageArrived 错误: ${err.message}`);
          return;
        }
        const payloadStr = msg.payload || this.bufToString(msg.payloadBinary);
        hilog.info(DOMAIN, TAG, `收到消息 topic: ${msg.topic}, payload: ${payloadStr}`);
        if (this.messageCallback) {
          this.messageCallback(msg.topic, payloadStr);
        }
      });

      // 注册断开回调
      mqttClient.connectLost((err: Error) => {
        hilog.warn(DOMAIN, TAG, `MQTT 连接断开: ${err ? err.message : 'unknown'}`);
        if (this.connectionLostCallback) {
          this.connectionLostCallback();
        }
      });

      // 连接
      const connectOpts: MqttConnectOptions = {
        cleanSession: true,
        connectTimeout: 30,
        keepAliveInterval: 60,
        userName: '',
        password: ''
      };

      hilog.info(DOMAIN, TAG, '正在连接 MQTT Broker...');
      await mqttClient.connect(connectOpts);
      hilog.info(DOMAIN, TAG, 'MQTT 连接成功');

    } catch (err) {
      hilog.error(DOMAIN, TAG, `MQTT 连接失败: ${JSON.stringify(err)}`);
      // 清理失败的客户端
      if (this.client) {
        try { await this.client.destroy(); } catch (_e) { /* ignore */ }
        this.client = null;
      }
      throw new Error(`MQTT connect failed: ${err}`);
    }
  }

  /**
   * 订阅主题
   */
  async subscribe(topic: string, qos: number = 1): Promise<void> {
    const c = this.client;
    if (!c) {
      throw new Error('MQTT 客户端未创建');
    }

    const opts: MqttSubscribeOptions = {
      topic: topic,
      qos: qos as (0 | 1 | 2)
    };

    await c.subscribe(opts);
    hilog.info(DOMAIN, TAG, `订阅成功: ${topic}`);
  }

  /**
   * 发布消息
   */
  async publish(topic: string, payload: string, qos: number = 1): Promise<void> {
    const c = this.client;
    if (!c) {
      throw new Error('MQTT 客户端未创建');
    }

    const opts: MqttPublishOptions = {
      topic: topic,
      payload: payload,
      qos: qos as (0 | 1 | 2),
      retained: false
    };

    await c.publish(opts);
    hilog.info(DOMAIN, TAG, `发布成功: ${topic} -> ${payload}`);
  }

  /**
   * 断开连接并销毁客户端
   */
  async disconnect(): Promise<void> {
    if (this.client) {
      try {
        await this.client.disconnect();
        hilog.info(DOMAIN, TAG, 'MQTT 已断开');
      } catch (_err) {
        /* ignore */
      }
      try {
        await this.client.destroy();
        hilog.info(DOMAIN, TAG, 'MQTT 客户端已销毁');
      } catch (_err) {
        /* ignore */
      }
      this.client = null;
    }
  }

  /**
   * 检查是否已连接
   */
  async isConnected(): Promise<boolean> {
    if (!this.client) {
      return false;
    }
    return await this.client.isConnected();
  }

  /**
   * 手动重连
   */
  async reconnect(): Promise<boolean> {
    if (!this.client) {
      return false;
    }
    return await this.client.reconnect();
  }

  /**
   * 注册消息回调
   */
  onMessageArrived(callback: (topic: string, payload: string) => void): void {
    this.messageCallback = callback;
  }

  /**
   * 注册连接断开回调
   */
  onConnectionLost(callback: () => void): void {
    this.connectionLostCallback = callback;
  }

  /**
   * ArrayBuffer -> string
   */
  private bufToString(buf: ArrayBuffer): string {
    if (!buf || buf.byteLength === 0) {
      return '';
    }
    try {
      return buffer.from(buf).toString('utf-8');
    } catch (_e) {
      return '';
    }
  }

  /**
   * 清理旧客户端（不抛异常）
   */
  private async cleanup(): Promise<void> {
    if (this.client) {
      try { await this.client.disconnect(); } catch (_e) { /* ignore */ }
      try { await this.client.destroy(); } catch (_e) { /* ignore */ }
      this.client = null;
      hilog.info(DOMAIN, TAG, '旧客户端已清理');
    }
  }
}
