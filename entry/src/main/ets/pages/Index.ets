import { FanService } from '../services/FanService';

/**
 * 智能风扇监控 — 仪表盘页面
 */

// ====== 连接状态条 ======
@ComponentV2
struct ConnectionBanner {
  @Consumer('fanService') fanService: FanService = FanService.getInstance();

  build() {
    Row() {
      // 状态指示灯
      Circle()
        .width(10)
        .height(10)
        .fill(this.getDotColor())

      // 状态文字
      Text(this.getBannerText())
        .fontSize(14)
        .fontColor(this.getBannerColor())
        .margin({ left: 8 })
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.getBannerBgColor())
  }

  private getDotColor(): string {
    if (this.fanService.connecting || this.fanService.reconnecting) return '#F59E0B'; // 黄色
    if (this.fanService.connected) return '#22C55E';    // 绿色
    return '#EF4444';                                     // 红色
  }

  private getBannerColor(): string {
    if (this.fanService.connecting || this.fanService.reconnecting) return '#92400E'; // 深黄
    if (this.fanService.connected) return '#166534';    // 深绿
    return '#991B1B';                                     // 深红
  }

  private getBannerBgColor(): string {
    if (this.fanService.connecting || this.fanService.reconnecting) return '#FEF3C7'; // 浅黄
    if (this.fanService.connected) return '#DCFCE7';    // 浅绿
    return '#FEE2E2';                                     // 浅红
  }

  private getBannerText(): string {
    if (this.fanService.connecting || this.fanService.reconnecting) return '正在连接...';
    if (this.fanService.connected) return '已连接';
    return '网络连接异常';
  }
}

// ====== 风扇卡片 ======
@ComponentV2
struct FanCard {
  @Consumer('fanService') fanService: FanService = FanService.getInstance();
  @Local scaleValue: number = 1.0;    // 刷新按钮缩放动画

  build() {
    Column() {
      // 风扇图标
      Text('🌀')
        .fontSize(56)
        .margin({ bottom: 12 })

      // 风扇名称
      Text('智能风扇')
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1E293B')
        .margin({ bottom: 16 })

      // 分隔线
      Divider()
        .width('60%')
        .color('#E2E8F0')
        .margin({ bottom: 16 })

      // 运行状态
      Row() {
        Text('运行状态')
          .fontSize(15)
          .fontColor('#64748B')

        // ====== 刷新中状态 ======
        if (this.fanService.globalRefreshing) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color('#3B82F6')
            .margin({ left: 8 })

          Text('刷新中...')
            .fontSize(13)
            .fontColor('#3B82F6')
            .margin({ left: 6 })

          Blank()
        } else {
          // ====== 刷新按钮（正常态） ======
          Text('🔄')
            .fontSize(14)
            .margin({ left: 6 })
            .scale({ x: this.scaleValue, y: this.scaleValue })
            .opacity((this.fanService.connected && !this.fanService.isProcessing && !this.fanService.globalRefreshing) ? 0.6 : 0.2)
            .onClick(() => {
              if (this.fanService.connected && !this.fanService.isProcessing && !this.fanService.globalRefreshing) {
                // 按压缩放动画
                this.scaleValue = 0.85;
                animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
                  this.scaleValue = 1.0;
                });
                this.fanService.globalRefresh();
              }
            })

          Blank()

          // ====== 状态显示区域 ======
          if (this.fanService.lastGlobalRefreshResult === 'success') {
            // 全局刷新成功反馈
            Row() {
              Circle()
                .width(8)
                .height(8)
                .fill('#22C55E')
                .margin({ right: 6 })

              Text('已刷新')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#166534')
            }
          } else if (this.fanService.lastGlobalRefreshResult === 'fail') {
            // 全局刷新失败反馈
            Row() {
              Circle()
                .width(8)
                .height(8)
                .fill('#EF4444')
                .margin({ right: 6 })

              Text('查询失败')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#991B1B')
            }
          } else {
            // 正常状态显示
            Row() {
              Circle()
                .width(8)
                .height(8)
                .fill(this.getStatusDotColor())
                .margin({ right: 6 })

              Text(this.fanService.statusText)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.getStatusTextColor())
            }
          }
        }
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
      .margin({ bottom: 20 })

      // 分隔线
      Divider()
        .width('60%')
        .color('#E2E8F0')
        .margin({ bottom: 20 })

      // 电子开关
      if (this.fanService.isProcessing) {
        // ====== 处理中状态 ======
        Row() {
          LoadingProgress()
            .width(18)
            .height(18)
            .color('#3B82F6')

          Text(this.fanService.operationStatus)
            .fontSize(13)
            .fontColor('#3B82F6')
            .margin({ left: 8 })
            .flexShrink(1)

          Blank()

          Toggle({ type: ToggleType.Switch, isOn: this.fanService.powerTarget })
            .selectedColor('#3B82F6')
            .enabled(false)
            .opacity(0.5)
        }
        .width('100%')
        .padding({ left: 4, right: 4 })
      } else {
        // ====== 正常状态 ======
        Row() {
          Text('电源开关')
            .fontSize(15)
            .fontColor('#64748B')

          Blank()

          Toggle({ type: ToggleType.Switch, isOn: this.fanService.power })
            .selectedColor('#3B82F6')
            .onChange((isOn: boolean) => {
              // 只在用户主动操作时触发
              if (isOn !== this.fanService.power) {
                this.fanService.togglePower();
              }
            })
            .enabled(this.fanService.connected && !this.fanService.isProcessing)
        }
        .width('100%')
        .padding({ left: 4, right: 4 })
        .opacity(this.fanService.connected ? 1.0 : 0.4)
      }
    }
    .width('85%')
    .padding({ top: 28, bottom: 28, left: 24, right: 24 })
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
    .shadow({
      radius: 12,
      color: '#00000015',
      offsetX: 0,
      offsetY: 4
    })
  }

  private getStatusDotColor(): string {
    if (this.fanService.isProcessing) return '#3B82F6';       // 蓝色：处理中
    if (this.fanService.globalRefreshing) return '#3B82F6';    // 蓝色：全局刷新中
    if (this.fanService.connecting || this.fanService.reconnecting) return '#F59E0B';
    if (!this.fanService.connected) return '#EF4444';
    if (!this.fanService.deviceOnline) return '#F59E0B';       // 黄色：设备离线
    if (this.fanService.power) return '#22C55E';
    return '#9CA3AF';
  }

  private getStatusTextColor(): string {
    if (this.fanService.isProcessing) return '#1E40AF';       // 深蓝：处理中
    if (this.fanService.globalRefreshing) return '#1E40AF';    // 深蓝：全局刷新中
    if (this.fanService.connecting || this.fanService.reconnecting) return '#92400E';
    if (!this.fanService.connected) return '#991B1B';
    if (!this.fanService.deviceOnline) return '#92400E';       // 深黄：设备离线
    if (this.fanService.power) return '#166534';
    return '#4B5563';
  }
}

// ====== 页面根组件 ======
@Entry
@ComponentV2
struct Index {
  @Provider('fanService') fanService: FanService = FanService.getInstance();

  build() {
    Column() {
      // 连接状态条
      ConnectionBanner()

      // 风扇卡片（垂直居中）
      Column() {
        Blank()
        FanCard()
        Blank()
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F1F5F9')
  }
}
