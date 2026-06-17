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
 * 风扇运行状态响应 (fan_status 主题)
 */
export interface FanStatusPayload {
  status: string     // "running" | "stopped"
  timestamp: number
}

/**
 * 风扇状态查询请求 (quary_fan_status 主题)
 */
export interface FanStatusQuery {
  action: string     // "query"
  timestamp: number
}

/**
 * 设备发现查询
 */
export interface FindDevicesQuery {
  action: string     // "discover"
  timestamp: number
}

/**
 * 设备信息
 */
export interface DeviceInfo {
  id: string         // 设备代号，"1" = 风扇
  type: string       // 设备类型，"fan"
  status: string     // "online" | "offline"
}

/**
 * 设备发现响应 (devices_response 主题)
 */
export interface DevicesResponse {
  devices: DeviceInfo[]
}

/**
 * MQTT 主题接口
 */
interface FanTopicsType {
  readonly TELEMETRY: string
  readonly STATUS: string
  readonly FAN_STATUS: string
  readonly QUERY_FAN_STATUS: string
  readonly APP_CONTROL_FAN: string
  readonly FIND_DEVICES: string
  readonly DEVICES_RESPONSE: string
}

/**
 * MQTT 主题常量
 */
export const FanTopics: FanTopicsType = {
  TELEMETRY:         'fan/devices/fan-001/telemetry',
  STATUS:            'fan/devices/fan-001/status',
  FAN_STATUS:        'fan_status',
  QUERY_FAN_STATUS:  'quary_fan_status',
  APP_CONTROL_FAN:   'app_control_fan',
  FIND_DEVICES:      'find_devices',
  DEVICES_RESPONSE:  'devices_response'
}

/**
 * 风扇运行状态枚举
 */
export enum FanStatus {
  OFFLINE = 'offline',   // 未连接
  RUNNING = 'running',   // 运行中
  STOPPED = 'stopped'    // 停止
}
