import Cocoa
import AVFoundation

@MainActor extension DesktopApp {
 @objc func changeMode(_ sender:NSPopUpButton) {setAttentionMode(sender.indexOfSelectedItem==1)}
 @objc func chooseFoldMode() {setAttentionMode(false);showController()}
 @objc func chooseAttentionMode() {setAttentionMode(true);showController()}
 func setAttentionMode(_ enabled:Bool) {
  guard attentionMode != enabled else {refreshStatusMenu();return}
  let resume=lifecycle.enabled
  suspendMonitoring();attentionMode=enabled;attentionPreferences.isHidden = !enabled;modePicker.selectItem(at:enabled ? 1:0)
  detail.stringValue=enabled ? "看向屏幕时清晰。只有「没有面向屏幕」与「没有键盘鼠标操作」同时持续到设定时间，毛玻璃才沿随机方向缓缓流动扩散；任一条件中断立即清零重新计时，所以正在用电脑时不会被模糊。仅开启本模式时使用内置摄像头，本地判断人脸朝向，不保存画面。不是精确眼球追踪。默认重新面向屏幕即自动恢复清晰；只有勾选保持模糊或身份验证时才需要手动确认。" : "合盖越多，毛玻璃向下覆盖越多；打开时退回，未覆盖区域保持清晰。操作鼠标或键盘时恢复真实桌面。90 秒未折叠自动待机，再次合盖唤醒。"
  message.stringValue=enabled ? "开启后请先面向屏幕，等待识别就绪。" : "点击开始，选择 MacBook 内置屏幕，再缓慢合盖。"
  activityText=enabled ? "已切换到注视模式 · 正在准备" : "已切换到合盖模式 · 正在准备"
  if resume {message.stringValue=activityText;scheduleResume()}
  else {activityText=enabled ? "注视模式 · 尚未开始" : "合盖模式 · 尚未开始"}
  record(enabled ? "mode changed: attention" : "mode changed: lid")
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
    self.attentionGate=AttentionGate();self.attentionIdle=AttentionIdleGate();self.attentionIdle.delay=AttentionPreferences.delaySeconds;self.attentionIdle.inputObserved(at:ProcessInfo.processInfo.systemUptime);self.attentionLastSample=ProcessInfo.processInfo.systemUptime
    monitor.onSample={ [weak self] facing in Task { @MainActor in
     guard let self=self,self.attentionTicket==ticket,self.lifecycle.canMonitor else{return}
     let now=ProcessInfo.processInfo.systemUptime
     self.attentionLastSample=now;self.attentionGate.sample(facing:facing,at:now)
    }}
    monitor.onError={ [weak self] reason in Task { @MainActor in
     guard let self=self,self.attentionTicket==ticket else{return};self.end(reason)
    }}
    self.state.arm(angle:DesktopApp.attentionReference);self.attentionAmount=0
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
 /// Attention mode drives the fold session from a fixed reference rather than a hinge angle.
 /// Re-arming must always return to that reference, or the constant trigger sample stops working.
 func attentionRearm() {
  clearFoldResources();state.arm(angle:attentionReference);attentionAmount=0
 }
 func attentionTick(now:Double) {
  let dt=attentionLastTick>0 ? min(0.1,max(0,now-attentionLastTick)) : 1.0/30
  attentionLastTick=now
  guard now-attentionLastSample<8 else {end("摄像头画面中断，已恢复桌面并停止注视模式。请检查摄像头后重新开始。");return}
  // Menu tracking must never latch a new cover or raise an input-taking panel.
  if menuIsOpen {lastInputActivity=InputActivity.current();attentionIdle.inputObserved(at:now);return}
  // Working at the machine is presence, whatever the camera thinks of the head pose.
  let activity=InputActivity.current()
  if lastInputActivity != activity {
   lastInputActivity=activity
   attentionIdle.inputObserved(at:now)
   if !attentionHold.locked {
    attentionSuppressedUntil=now+2
    attentionHold.reset();attentionRearm()
   }
  }
  // The countdown needs look-away and input idleness together; either one breaking restarts it.
  let absence=attentionIdle.start(awaySince:attentionGate.since)
  let ready=attentionGate.calibrated && attentionIdle.ready(away:attentionGate.away,awaySince:attentionGate.since,at:now) && now>=attentionSuppressedUntil
  attentionHold.update(away:ready,started:absence,keep:AttentionPreferences.keepsBlur)
  let shouldBlur=attentionHold.locked || ready
  if shouldBlur,state.phase == .armed {
   attentionDirection=Int.random(in:0...3)
   state.sample(attentionTriggerAngle);capture()
  }
  if !shouldBlur,state.phase == .capturing {attentionRearm()}
  if let engine=renderer {
   let previous=attentionAmount
   attentionAmount=max(0,min(1,attentionAmount+Float(dt/(shouldBlur ? 1.6 : -0.7))))
   if attentionAmount != previous {engine.params.progress=attentionAmount;canvas?.draw()}
   if attentionAmount==0 {attentionRearm()}
  }
  updateAttentionCard(now:now)
  let text:String
  if !attentionGate.calibrated {text="注视模式 · 请面向屏幕进行识别"}
  else if shouldBlur {text="注视模式 · 已离开，毛玻璃显示"}
  else if attentionGate.away {text=String(format:"注视模式 · 已转开 %.0f 秒，%.0f 秒后模糊",max(0,now-absence),max(0,absence+attentionIdle.delay-now))}
  else {text="注视模式 · 清晰显示"}
  if activityText != text {activityText=text;refreshStatusMenu()}
 }
}
