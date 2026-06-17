/**
 * 风扇遥测数据
 */
export interface FanTelemetry {
  power: string        // "on" | "off"
  timestamp: number
}

/**
 * 风扇控制指令
 */
export interface FanCommand {
  action: string  // "set_power"
  value: string   // "on" | "off"
}

/**
 * MQTT 主题接口
 */
interface FanTopicsType {
  readonly TELEMETRY: string
  readonly COMMAND: string
  readonly STATUS: string
}

/**
 * MQTT 主题常量
 */
export const FanTopics: FanTopicsType = {
  TELEMETRY: 'fan/devices/fan-001/telemetry',
  COMMAND:   'fan/devices/fan-001/command',
  STATUS:    'fan/devices/fan-001/status'
}

/**
 * 风扇运行状态枚举
 */
export enum FanStatus {
  OFFLINE = 'offline',   // 未连接
  RUNNING = 'running',   // 运行中
  STOPPED = 'stopped'    // 停止
}
