import Cocoa
import AVFoundation

@MainActor extension DesktopApp {
 @objc func changeAttentionDirection(_ sender:NSPopUpButton) {
  UserDefaults.standard.set(sender.indexOfSelectedItem,forKey:"attentionDirection")
  if attentionMode {clearFoldResources();state.arm(angle:100);attentionAmount=0;attentionSuppressedUntil=ProcessInfo.processInfo.systemUptime+0.3}
 }
 @objc func changeMode(_ sender:NSPopUpButton) {setAttentionMode(sender.indexOfSelectedItem==1)}
 @objc func chooseFoldMode() {setAttentionMode(false)}
 @objc func chooseAttentionMode() {setAttentionMode(true)}
 func setAttentionMode(_ enabled:Bool) {
  guard attentionMode != enabled else{return}
  let resume=lifecycle.enabled
  suspendMonitoring();attentionMode=enabled;directionPicker.isHidden = !enabled;modePicker.selectItem(at:enabled ? 1:0)
  detail.stringValue=enabled ? "看向屏幕时清晰，转头或离开约 1 秒后毛玻璃沿所选方向逐渐扩散。仅开启本模式时使用内置摄像头，本地判断人脸朝向，不保存画面。不是精确眼球追踪。移动鼠标或按键可临时恢复。" : "合盖越多，毛玻璃向下覆盖越多；打开时退回，未覆盖区域保持清晰。操作鼠标或键盘时恢复真实桌面。90 秒未折叠自动待机，再次合盖唤醒。"
  message.stringValue=enabled ? "开启后请先面向屏幕，等待识别就绪。" : "点击开始，选择 MacBook 内置屏幕，再缓慢合盖。"
  if resume {scheduleResume()}
  refreshStatusMenu()
 }
 func startAttentionMonitoring() {
  let ticket=UUID();attentionTicket=ticket
  activityText="注视模式 · 等待摄像头授权"
  let begin: @Sendable (Bool)->Void = { [weak self] allowed in
   Task { @MainActor in
    guard let self=self,self.attentionTicket==ticket,self.attentionMode,self.lifecycle.canMonitor else{return}
    guard allowed else {self.end("摄像头未授权。请在系统设置 → 隐私与安全性 → 摄像头中允许 MacDuo，然后重新开始。");return}
    let monitor=AttentionMonitor();self.attentionMonitor=monitor
    self.attentionGate=AttentionGate();self.attentionLastSample=ProcessInfo.processInfo.systemUptime
    monitor.onSample={ [weak self] facing in Task { @MainActor in
     guard let self=self,self.attentionTicket==ticket,self.lifecycle.canMonitor else{return}
     let now=ProcessInfo.processInfo.systemUptime
     self.attentionLastSample=now;self.attentionGate.sample(facing:facing,at:now)
    }}
    monitor.onError={ [weak self] reason in Task { @MainActor in
     guard let self=self,self.attentionTicket==ticket else{return};self.end(reason)
    }}
    self.state.arm(angle:100);self.attentionAmount=0
    let pair=startWatchdog();self.guardProcess=pair.0;self.heartbeat=pair.1
    self.lastInputActivity=InputActivity.current()
    self.timer=Timer(timeInterval:1/30,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.tick()}}
    RunLoop.main.add(self.timer!,forMode:.common)
    self.activityText="注视模式 · 请面向屏幕进行识别"
    self.message.stringValue="注视模式已开启，摄像头仅在本机判断朝向。可在菜单栏暂停或切回合盖模式。"
    self.refreshStatusMenu();monitor.start()
   }
  }
  switch AVCaptureDevice.authorizationStatus(for:.video) {
  case .authorized:begin(true)
  case .notDetermined:AVCaptureDevice.requestAccess(for:.video,completionHandler:begin)
  default:begin(false)
  }
 }
 func attentionTick(now:Double) {
  let dt=attentionLastTick>0 ? min(0.1,max(0,now-attentionLastTick)) : 1.0/30
  attentionLastTick=now
  guard now-attentionLastSample<8 else {end("摄像头画面中断，已恢复桌面并停止注视模式。请检查摄像头后重新开始。");return}
  let activity=InputActivity.current()
  if lastInputActivity != activity {
   lastInputActivity=activity;attentionSuppressedUntil=now+2
   clearFoldResources();state.arm(angle:100);attentionAmount=0
  }
  let shouldBlur=attentionGate.calibrated && attentionGate.away && !menuIsOpen && now>=attentionSuppressedUntil
  if shouldBlur,state.phase == .armed {
   state.sample(50);capture()
  }
  if !shouldBlur,state.phase == .capturing {clearFoldResources();state.arm(angle:100)}
  if let engine=renderer {
   let previous=attentionAmount
   attentionAmount=max(0,min(1,attentionAmount+Float(dt/(shouldBlur ? 0.9 : -0.45))))
   if attentionAmount != previous {engine.params.progress=attentionAmount;canvas?.draw()}
   if attentionAmount==0 {clearFoldResources();state.arm(angle:100)}
  }
  let text = !attentionGate.calibrated ? "注视模式 · 请面向屏幕进行识别" : (shouldBlur ? "注视模式 · 已转开，毛玻璃显示" : "注视模式 · 清晰显示")
  if activityText != text {activityText=text;refreshStatusMenu()}
 }
}
