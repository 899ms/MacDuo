import Cocoa
import MetalKit
import ScreenCaptureKit

final class DesktopPanel: NSPanel {
 override var canBecomeKey: Bool { false }
 override var canBecomeMain: Bool { false }
}

@MainActor final class DesktopApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, SCContentSharingPickerObserver {
 var window: NSWindow!
 let message=NSTextField(wrappingLabelWithString:"点击开始，选择 MacBook 内置屏幕，再缓慢合盖。")
 let detail=NSTextField(wrappingLabelWithString:"合盖越多，毛玻璃向下覆盖越多；打开时退回，未覆盖区域保持清晰。操作鼠标或键盘时恢复真实桌面。90 秒未折叠自动待机，再次合盖唤醒。")
 var startButton: NSButton!
 var state=FoldSession()
 var generation=0
 var selecting=false
 var filter: SCContentFilter?
 var screen: NSScreen?
 var renderer: FoldEngine?
 var overlay: DesktopPanel?
 var canvas: MTKView?
 var activityText="正在读取开盖角度…"
 var statusItem:NSStatusItem?
 let statusMenu=NSMenu()
 let menuStatus=NSMenuItem(title:"尚未开始",action:nil,keyEquivalent:"")
 let menuDetail=NSMenuItem(title:"",action:nil,keyEquivalent:"")
 let toggleItem=NSMenuItem(title:"开始折叠…",action:#selector(toggleMonitoring),keyEquivalent:"")
 var menuIsOpen=false
 var sensor: Process?
 var sensorPipe: Pipe?
 var guardProcess: Process?
 var heartbeat: Pipe?
 var timer: Timer?
 var mailbox=AngleMailbox()
 var fit=AngularFit()
 var lastSample=0.0
 var previousProgress: Float = -1
 var observers=[NSObjectProtocol]()
 var captureTask: Task<Void,Never>?
 var captureTimeout: Task<Void,Never>?
 var lastInputActivity: InputActivity?
 var lifecycle=MonitoringLifecycle()
 var resumeTask: Task<Void,Never>?
 var distributedObservers=[NSObjectProtocol]()
 var sensorFailures=0
 let hingeSound=HingeSound()
 let soundItem=NSMenuItem(title:"开盖音效",action:#selector(toggleSound),keyEquivalent:"")
 var unlockReference:Double?
 var standby=CaptureStandby()
 var showsControls=true

 func applicationDidFinishLaunching(_ notification: Notification) {
  window=NSWindow(contentRect:NSRect(x:0,y:0,width:420,height:330),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
  window.title="MacDuo"; window.isReleasedWhenClosed=false; window.delegate=self
  let stack=NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing=18
  stack.translatesAutoresizingMaskIntoConstraints=false; window.contentView!.addSubview(stack)
  NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:24)])
  let title=NSTextField(labelWithString:"MacDuo"); title.font = .systemFont(ofSize:22,weight:.semibold)
  startButton=NSButton(title:"选择屏幕并开始",target:self,action:#selector(start)); startButton.bezelStyle = .rounded; startButton.controlSize = .large
  for view in [title,detail,startButton!,message] { stack.addArrangedSubview(view) }
  let menuButton=NSButton(title:"菜单栏控制…",target:self,action:#selector(openStatusMenu));menuButton.bezelStyle = .rounded
  stack.addArrangedSubview(menuButton)
  let menu=NSMenu(), root=NSMenuItem(), appMenu=NSMenu()
  appMenu.addItem(withTitle:"停止并退出",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); root.submenu=appMenu; menu.addItem(root); NSApp.mainMenu=menu
  let picker=SCContentSharingPicker.shared; picker.add(self)
  hingeSound.onEvent = {[weak self] event in self?.record(event)}
  installStatusItem()
  installLifecycleObservers()
  record("launched")
  window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
  if CommandLine.arguments.contains("--ui-smoke") { DispatchQueue.main.asyncAfter(deadline:.now()+3){NSApp.terminate(nil)} }
 }
 func record(_ value: String) {
  refreshStatusMenu()
  guard !CommandLine.arguments.contains(where:{$0.hasPrefix("--test-")}) else{return}
  let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DuoFoldDesktop",isDirectory:true)
  try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  let url=directory.appendingPathComponent("lifecycle.log")
  let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "test"
  let line="\(ISO8601DateFormatter().string(from:Date())) [\(version)] \(value)\n"
  guard let data=line.data(using:.utf8) else {return}
  if !FileManager.default.fileExists(atPath:url.path) { try? data.write(to:url); return }
  if let size=(try? FileManager.default.attributesOfItem(atPath:url.path)[.size]) as? NSNumber,size.intValue>200_000 { try? data.write(to:url); return }
  if let file=try? FileHandle(forWritingTo:url) { defer{try? file.close()};_ = try? file.seekToEnd();try? file.write(contentsOf:data) }
 }
 func installLifecycleObservers() {
  let workspace=NSWorkspace.shared.notificationCenter
  let pairs:[(Notification.Name,Notification.Name,MonitoringLifecycle.Blocker)]=[
   (NSWorkspace.willSleepNotification,NSWorkspace.didWakeNotification,.systemSleep),
   (NSWorkspace.screensDidSleepNotification,NSWorkspace.screensDidWakeNotification,.displaySleep),
   (NSWorkspace.sessionDidResignActiveNotification,NSWorkspace.sessionDidBecomeActiveNotification,.inactiveSession)]
  for (pause,resume,reason) in pairs {
   observers.append(workspace.addObserver(forName:pause,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.pause(reason)}})
   observers.append(workspace.addObserver(forName:resume,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.resume(reason)}})
  }
  // Lock/unlock are distinct from system wake and fast user switching.
  let distributed=DistributedNotificationCenter.default()
  distributedObservers.append(distributed.addObserver(forName:Notification.Name("com.apple.screenIsLocked"),object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.pause(.locked)}})
  distributedObservers.append(distributed.addObserver(forName:Notification.Name("com.apple.screenIsUnlocked"),object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.resume(.locked)}})
  observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated{
   guard let self=self,self.lifecycle.enabled else{return}
   self.record("display changed; suspending transient resources")
   self.suspendMonitoring();self.scheduleResume()
  }})
 }
 func pause(_ reason: MonitoringLifecycle.Blocker) {
  lifecycle.pause(reason)
  guard lifecycle.enabled else{return}
  // Save the pre-lock open reference once; later sleep/lock notifications see a reset session.
  if unlockReference == nil, state.baseline>=70 {unlockReference=state.baseline}
  record("pause: \(reason)")
  suspendMonitoring()
 }
 func resume(_ reason: MonitoringLifecycle.Blocker) {
  lifecycle.resume(reason)
  guard lifecycle.enabled else{return}
  record("resume signal: \(reason), remaining blockers=\(lifecycle.blockers.count)")
  sensorFailures=0
  scheduleResume()
 }
 func suspendMonitoring() {
  resumeTask?.cancel();resumeTask=nil
  clearFoldResources()
  stopMonitoring()
  // Preserve selection and enabled intent, but release the visible sharing session.
  SCContentSharingPicker.shared.isActive=false
  state=FoldSession();fit.reset();mailbox=AngleMailbox();lastInputActivity=nil
 }
 func stopMonitoring() {
  hingeSound.stop()
  timer?.invalidate();timer=nil
  if let process=sensor,process.isRunning {process.terminate()};sensor=nil;sensorPipe=nil
  // Closing the pipe ends the watchdog before sleep, so wake isn't mistaken for a hang.
  try? heartbeat?.fileHandleForWriting.close();heartbeat=nil;guardProcess=nil
 }
 func scheduleResume() {
  guard lifecycle.canMonitor, timer == nil, resumeTask == nil else{return}
  resumeTask=Task {
   do {try await Task.sleep(nanoseconds:700_000_000)} catch{return}
   resumeTask=nil
   guard lifecycle.canMonitor,timer == nil else{return}
   guard filter != nil else {end("屏幕选择已结束，请重新选择屏幕。");return}
   guard let displayID=filter?.includedDisplays.first?.displayID,
    let target=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)==displayID}),
    CGDisplayIsBuiltin(displayID) != 0 else {
     // Wait for a later display/wake signal; no polling or quitting while the display is absent.
     record("waiting for selected built-in display")
     return
   }
   resumeMonitoring(on:target)
  }
 }
 func resumeMonitoring(on target: NSScreen) {
  guard lifecycle.canMonitor,timer == nil else{return}
  resumeTask?.cancel();resumeTask=nil
  screen=target
  record("resuming monitoring after desktop became available")
  startMonitoring(on:target)
 }
 @objc func start() {
  cleanup(); selecting=true; startButton.isEnabled=false
  message.stringValue="请在系统选择器中选择 MacBook 内置屏幕。"
  var configuration=SCContentSharingPickerConfiguration()
  configuration.allowedPickerModes = [.singleDisplay]
  configuration.excludedBundleIDs=[Bundle.main.bundleIdentifier!]
  configuration.allowsChangingSelectedContent=false
  let picker=SCContentSharingPicker.shared; picker.defaultConfiguration=configuration; picker.isActive=true
  window.orderOut(nil); picker.present(using:.display)
 }
 nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
  Task { @MainActor in if self.selecting { self.end("已取消屏幕选择。") } }
 }
 nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
  Task { @MainActor in self.end("系统选择器未能打开："+error.localizedDescription) }
 }
 nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
  Task { @MainActor in self.selected(filter) }
 }
 func selected(_ selection: SCContentFilter) {
  guard selecting else { return }
  selecting=false
  guard let display=selection.includedDisplays.first, CGDisplayIsBuiltin(display.displayID) != 0,
        let target=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)==display.displayID}) else {
   end("请选择 MacBook 内置屏幕，实体合盖效果只作用于该屏幕。"); return
  }
  filter=selection; screen=target; lifecycle.enable();sensorFailures=0
  message.stringValue="已开启。可以关闭此窗口，在菜单栏暂停或恢复折叠。"
  if lifecycle.canMonitor {startMonitoring(on:target)}
 }
 func startMonitoring(on target: NSScreen) {
  guard lifecycle.canMonitor,timer == nil else{return}
  state=FoldSession();fit.reset();mailbox=AngleMailbox()
  standby=CaptureStandby(now:ProcessInfo.processInfo.systemUptime)
  record("monitoring started")
  let pair=startWatchdog(); guardProcess=pair.0; heartbeat=pair.1
  lastSample=ProcessInfo.processInfo.systemUptime
  lastInputActivity=InputActivity.current()
  let worker=Process(), pipe=Pipe(); worker.executableURL=Bundle.main.executableURL; worker.arguments=["--sensor"]
  worker.standardOutput=pipe; worker.standardError=FileHandle.nullDevice; sensor=worker; sensorPipe=pipe
  let box=mailbox
  DispatchQueue.global(qos:.utility).async {
   var buffer=Data()
   while true {
    let bytes=pipe.fileHandleForReading.availableData; if bytes.isEmpty { break }; buffer.append(bytes)
    while let newline=buffer.firstIndex(of:10) {
     let line=String(data:buffer.prefix(upTo:newline),encoding:.utf8) ?? ""; buffer.removeSubrange(...newline)
     if let angle=Double(line) { box.put(angle,at:ProcessInfo.processInfo.systemUptime) }
    }
   }
  }
  do { try worker.run() } catch { end("无法启动角度传感器："+error.localizedDescription); return }
  timer=Timer(timeInterval:1/30,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.tick()}}
  RunLoop.main.add(timer!,forMode:.common)
  // The controller must not remain the keyboard target after selecting a display.
  if showsControls {NSApp.deactivate()}
 }
 func beat() { try? heartbeat?.fileHandleForWriting.write(contentsOf:Data([72])) }
 func tick() {
  guard lifecycle.canMonitor else {suspendMonitoring();return}
  beat(); let now=ProcessInfo.processInfo.systemUptime
  if let (raw,time)=mailbox.take() {
   lastSample=time;sensorFailures=0; let angle=fit.update(angle:raw,at:time).angle
   if state.phase == .idle {
    guard angle>=70 || unlockReference != nil else {activityText="已恢复监听 · 请继续打开屏幕";return}
    armAfterResume(angle:angle)
   } else { state.sample(angle) }
   if !menuIsOpen {hingeSound.sample(angle,at:now)}
   standby.observe(angle:angle,now:now)
  }
  guard now-lastSample<3 else {
   sensorFailures += 1;record("sensor unavailable; retry \(sensorFailures)")
   suspendMonitoring()
   if sensorFailures<=3 {scheduleResume()}
   else {end("角度传感器暂时不可用，请重新开始。应用未退出。")} 
   return
  }
  observeInputActivity(InputActivity.current())
  if menuIsOpen {
   if state.phase == .capturing || state.phase == .folding {clearFoldResources()}
   state.yieldToUser()
   return
  }
  if standby.shouldRest(now:now), state.phase != .capturing {enterStandby()}
  switch state.phase {
  case .armed:
   activityText=standby.resting ? "待机 · 再次合盖自动唤醒" : String(format:"%.1f° · 合盖至 %.1f° 开始",state.angle,state.baseline-3)
  case .capturing:
   activityText="正在捕获当前桌面…"
   if captureTask == nil { capture() }
  case .folding:
   activityText=String(format:"折叠中 %.1f° · 展开后继续待命",state.angle)
   let progress=Float(state.progress)
   if abs(progress-previousProgress)>0.001 { renderer?.params.progress=progress; canvas?.draw(); previousProgress=progress }
  case .finished: completeCycle()
  case .idle: break
  }
 }
 func armAfterResume(angle:Double) {
  guard lifecycle.canMonitor else{return}
  if let reference=unlockReference {
   unlockReference=nil
   state.arm(angle:max(reference,angle))
   // Capture the newly unlocked desktop, never retain or display a pre-lock image.
   if reference-angle>=3 {state.sample(angle)}
   record("unlocked desktop at \(Int(angle)) degrees; reference \(Int(reference)); phase \(state.phase)")
  } else {
   state.arm(angle:angle);record("armed at \(Int(angle)) degrees")
  }
 }
 func observeInputActivity(_ activity: InputActivity) {
  let changed=lastInputActivity.map { $0 != activity } ?? false
  lastInputActivity=activity
  guard changed else { return }
  let wasShowing=state.phase == .capturing || state.phase == .folding
  guard wasShowing || state.phase == .armed else { return }
  if wasShowing { clearFoldResources() }
  state.yieldToUser()
  if wasShowing {
   activityText="已恢复真实桌面 · 再次合盖可触发"
  }
 }
 func capture() {
  guard lifecycle.canMonitor else{return}
  guard let selection=filter else { end("屏幕选择已失效，请重新开始。"); return }
  let needsActivation = !SCContentSharingPicker.shared.isActive
  let captureStarted=ProcessInfo.processInfo.systemUptime
  standby.wake(now:captureStarted)
  record(needsActivation ? "fold requested; waking sharing session" : "fold requested")
  setMonitoringInterval(1/30)
  SCContentSharingPicker.shared.isActive=true
  let ticket=generation
  // Only a stuck screenshot request times out; waiting and folding have no deadline.
  captureTimeout=Task {
   do { try await Task.sleep(nanoseconds:10_000_000_000) } catch { return }
   guard ticket==generation, state.phase == .capturing else { return }
   end("桌面捕获未响应，已取消。请重新选择屏幕。")
  }
  captureTask=Task {
   do {
    // Let the system finish activating the existing user-selected sharing session.
    if needsActivation {try await Task.sleep(nanoseconds:120_000_000)}
    let config=SCStreamConfiguration(); config.width=1600
    config.height=Int(1600*selection.contentRect.height/max(1,selection.contentRect.width)); config.showsCursor=false; config.capturesAudio=false
    let image=try await SCScreenshotManager.captureImage(contentFilter:selection,configuration:config)
    guard ticket==generation, lifecycle.canMonitor, state.phase == .capturing, !Task.isCancelled else { return }
    observeInputActivity(InputActivity.current())
    guard ticket==generation, lifecycle.canMonitor, state.phase == .capturing, !Task.isCancelled else { return }
    // No AppKit demo image and no expensive Metal/blur preparation on the UI thread.
    let engine=try await Task.detached(priority:.userInitiated) {
     try FoldEngine(rendering:true,image:image)
    }.value
    guard ticket==generation, lifecycle.canMonitor, state.phase == .capturing, !Task.isCancelled else{return}
    observeInputActivity(InputActivity.current())
    guard ticket==generation, lifecycle.canMonitor, state.phase == .capturing, !Task.isCancelled else{return}
    captureTimeout?.cancel(); captureTimeout=nil
    engine.params.progress=Float(state.progress)
    renderer=engine; state.captured(); showOverlay()
    record(String(format:"fold visible; preparation %.0f ms",(ProcessInfo.processInfo.systemUptime-captureStarted)*1000))
   } catch {
    if ticket==generation { end("没有取得桌面画面："+error.localizedDescription+"。请重新选择屏幕。") }
   }
  }
 }
 func showOverlay() {
  guard lifecycle.canMonitor else{return}
  guard let target=screen, let engine=renderer else { end("显示器已不可用。"); return }
  let p=DesktopPanel(contentRect:target.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  p.level = .floating; p.ignoresMouseEvents=true; p.hidesOnDeactivate=false; p.isReleasedWhenClosed=false
  p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
  let v=MTKView(frame:NSRect(origin:.zero,size:target.frame.size),device:engine.device)
  v.delegate=engine; v.colorPixelFormat = .bgra8Unorm; v.depthStencilPixelFormat = .depth32Float
  v.isPaused=true; v.enableSetNeedsDisplay=false; v.autoResizeDrawable=false; v.framebufferOnly=true
  v.drawableSize=NSSize(width:1600,height:1600*target.frame.height/target.frame.width)
  p.contentView=v; overlay=p; canvas=v; p.orderFrontRegardless(); v.draw()
 }
 func setMonitoringInterval(_ interval:Double) {
  guard timer != nil else{return}
  timer?.invalidate()
  timer=Timer(timeInterval:interval,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.tick()}}
  timer?.tolerance=interval*0.15
  RunLoop.main.add(timer!,forMode:.common)
 }
 func enterStandby() {
  guard !standby.resting else{return}
  clearFoldResources()
  state.yieldToUser()
  standby.rest()
  SCContentSharingPicker.shared.isActive=false
  setMonitoringInterval(0.1)
  activityText="待机 · 再次合盖自动唤醒"
  record("90 seconds without fold motion; released rendering and deactivated sharing picker")
 }
 func completeCycle() {
  // Release this fold's texture/window and invalidate any late capture result.
  // The existing picker grant, sensor and heartbeat remain ready for the next fold.
  clearFoldResources()
  state.rearm()
  activityText=String(format:"%.1f° · 已恢复桌面，等待下次合盖",state.angle)
 }
 @objc func cancel() { end("已停止自动折叠。") }
 func end(_ reason: String) {
  record("stopped: "+reason)
  cleanup(); message.stringValue=reason;refreshStatusMenu()
  if lifecycle.blockers.isEmpty {window?.makeKeyAndOrderFront(nil)}
 }
 func clearFoldResources() {
  generation += 1
  captureTask?.cancel(); captureTask=nil
  captureTimeout?.cancel(); captureTimeout=nil
  overlay?.orderOut(nil); overlay=nil; canvas=nil; renderer=nil
  previousProgress = -1
 }
 func cleanup() {
  lifecycle.disable();unlockReference=nil;resumeTask?.cancel();resumeTask=nil
  clearFoldResources(); selecting=false
  stopMonitoring()
  filter=nil; screen=nil; state=FoldSession(); previousProgress = -1; lastInputActivity=nil
  SCContentSharingPicker.shared.isActive=false; startButton?.isEnabled=true
 }
 func windowShouldClose(_ sender:NSWindow)->Bool {sender.orderOut(nil);return false}
 func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
 func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {showController();return true}
 func applicationWillTerminate(_ notification: Notification) { record("application terminating");cleanup(); SCContentSharingPicker.shared.remove(self);if let item=statusItem {NSStatusBar.system.removeStatusItem(item)} }
}

@main struct Entry {
 static func main() {
  let args=CommandLine.arguments
  if args.contains("--sensor") { runSensor() }
  if let i=args.firstIndex(of:"--watch-parent"),args.count>i+1,let pid=Int32(args[i+1]) { runWatchdog(parent:pid) }
  if args.contains("--test-hinge-sound") {
   var gate=HingeMotion()
   precondition(!gate.sample(80,at:0))
   precondition(!gate.sample(81,at:0.05))
   precondition(gate.sample(82,at:0.1))
   precondition(!gate.sample(85,at:0.15))
   precondition(!gate.sample(85,at:0.6))
   precondition(!gate.sample(84,at:0.65))
   precondition(!gate.sample(82,at:0.7))
   precondition(!gate.sample(83,at:0.75))
   precondition(gate.sample(84,at:0.8))
   var slow=HingeMotion()
   precondition(!slow.sample(80,at:0))
   for i in 1...20 {
    let fired=slow.sample(80+Double(i)*0.1,at:Double(i)*0.2)
    precondition(fired == (i==20))
   }
   for i in 21...40 {precondition(!slow.sample(82,at:Double(i)*0.2))}
   print("PASS: slow and normal opening trigger once; stationary does not retrigger; closing rearms");return
  }
  if args.contains("--test-standby") {
   _ = NSApplication.shared
   var idle=CaptureStandby(now:0)
   idle.observe(angle:110,now:0)
   for t in 1...89 {idle.observe(angle:110+Double(t%2)*0.3,now:Double(t))}
   precondition(!idle.shouldRest(now:89) && idle.shouldRest(now:90))
   idle.rest();precondition(idle.resting)
   idle.wake(now:100);precondition(!idle.resting && !idle.shouldRest(now:189))
   idle.observe(angle:100,now:180);precondition(!idle.shouldRest(now:200))
   let app=DesktopApp();app.lifecycle.enable();app.filter=SCContentFilter()
   app.state.arm(angle:110);app.state.sample(80);app.state.captured()
   app.enterStandby()
   precondition(app.standby.resting && app.renderer == nil && app.overlay == nil && app.captureTask == nil)
   precondition(app.lifecycle.enabled && app.filter != nil && !SCContentSharingPicker.shared.isActive)
   for _ in 0..<100 {app.state.sample(80);precondition(app.state.phase == .armed)}
   app.state.sample(76);precondition(app.state.phase == .capturing)
   app.cleanup()
   print("PASS: 90-second idle, jitter rejection, movement resets idle, resources released, next fold rearms");return
  }
  if args.contains("--test-session") {
   var s=FoldSession(); s.arm(angle:110)
   // More than one hour of 20 Hz samples must never end an idle or held fold.
   for _ in 0..<72_001 {
    for a in [110.0,109,111,110] { s.sample(a); precondition(s.phase == .armed && s.progress==0) }
   }
   s.sample(107); precondition(s.phase == .capturing)
   s.captured(); s.sample(80); let held=s.progress
   for _ in 0..<72_001 { s.sample(80); precondition(s.phase == .folding && s.progress==held) }
   s.sample(110); precondition(s.phase == .finished && s.progress==0)
   s=FoldSession(); s.arm(angle:100); s.sample(90); s.sample(100); s.captured(); precondition(s.phase == .finished)
   s=FoldSession(); s.arm(angle:110); s.sample(90); s.captured(); s.finish(); precondition(s.phase == .finished && s.progress==0)
   // Multiple complete folds use the same reference angle, including the 1.5° tolerance.
   s=FoldSession(); s.arm(angle:110)
   for _ in 0..<100 {
    s.sample(106); precondition(s.phase == .capturing)
    s.captured(); s.sample(75); precondition(s.phase == .folding)
    s.sample(108.5); precondition(s.phase == .finished)
    s.rearm(); precondition(s.phase == .armed && s.progress==0 && s.baseline==110)
    s.sample(109); precondition(s.phase == .armed)
   }
   // Reopening before capture completes also permits the very next cycle.
   s.sample(105); precondition(s.phase == .capturing)
   s.sample(110); s.rearm(); s.sample(104); precondition(s.phase == .capturing)
   // Work at a partially closed angle without stopping the sensor session.
   s=FoldSession(); s.arm(angle:110); s.sample(80); s.captured(); s.yieldToUser()
   for _ in 0..<1000 { s.sample(80); precondition(s.phase == .armed && s.progress==0) }
   s.sample(78); precondition(s.phase == .armed)
   s.sample(76); precondition(s.phase == .capturing)
   s.yieldToUser(); precondition(s.phase == .armed && s.baseline==76)
   print("PASS: 100 repeat cycles, partially folded interaction, no immediate retrigger, next fold works"); return
  }
  if args.contains("--test-repeat-lifecycle") {
   _ = NSApplication.shared
   let app=DesktopApp()
   // Exercise the real controller without selecting/capturing or covering any desktop.
   let heartbeatPair=startWatchdog(); app.guardProcess=heartbeatPair.0; app.heartbeat=heartbeatPair.1
   let timer=Timer(timeInterval:1,repeats:true){_ in}; app.timer=timer
   let box=app.mailbox
   app.state.arm(angle:110)
   for _ in 0..<3 {
    app.state.sample(105); app.state.captured()
    let ticket=app.generation
    app.captureTask=Task { try? await Task.sleep(nanoseconds:10_000_000_000) }
    app.captureTimeout=Task { try? await Task.sleep(nanoseconds:10_000_000_000) }
    app.state.sample(110); app.completeCycle()
    precondition(app.state.phase == .armed && app.generation != ticket)
    precondition(app.captureTask == nil && app.captureTimeout == nil && app.renderer == nil && app.overlay == nil)
    precondition(app.timer === timer && app.mailbox === box && heartbeatPair.0.isRunning)
    app.beat()
   }
   app.cleanup(); heartbeatPair.0.waitUntilExit()
   precondition(app.timer == nil && app.guardProcess == nil)
   precondition(heartbeatPair.0.terminationStatus == 0)
   print("PASS: cycle cleanup preserves monitoring; stale captures invalidated; stop releases workers"); return
  }
  if args.contains("--test-interaction-handoff") {
   _ = NSApplication.shared
   let app=DesktopApp()
   let monitor=Timer(timeInterval:1,repeats:true){_ in}; app.timer=monitor
   for wasCaptured in [false,true] {
    app.state.arm(angle:110); app.state.sample(80)
    if wasCaptured { app.state.captured() }
    app.lastInputActivity=InputActivity(counts:[0])
    app.captureTask=Task { try? await Task.sleep(nanoseconds:10_000_000_000) }
    app.captureTimeout=Task { try? await Task.sleep(nanoseconds:10_000_000_000) }
    let ticket=app.generation
    app.observeInputActivity(InputActivity(counts:[0]))
    precondition(app.generation==ticket)
    app.observeInputActivity(InputActivity(counts:[1]))
    precondition(app.state.phase == .armed && app.state.baseline==80 && app.state.progress==0)
    precondition(app.generation != ticket && app.captureTask == nil && app.captureTimeout == nil)
    precondition(app.timer === monitor)
    for _ in 0..<1000 { app.state.sample(80); precondition(app.state.phase == .armed) }
    app.state.sample(75); precondition(app.state.phase == .capturing)
   }
   app.cleanup()
   let counts=InputActivity.current().counts
   print("System activity counters: key=\(counts[0]>0), click=\(counts[2]>0), movement=\(counts[6]>0)")
   print("PASS: interaction cancels pending/visible fold, keeps monitoring, no stationary retrigger"); return
  }
  if args.contains("--test-recovery") {
   func permutations(_ values:[MonitoringLifecycle.Blocker])->[[MonitoringLifecycle.Blocker]] {
    if values.isEmpty{return [[]]}
    return values.flatMap{first in permutations(values.filter{$0 != first}).map{[first]+$0}}
   }
   let blockers:[MonitoringLifecycle.Blocker]=[.locked,.systemSleep,.displaySleep,.inactiveSession]
   for order in permutations(blockers) {
    var lifecycle=MonitoringLifecycle();lifecycle.enable()
    blockers.forEach{lifecycle.pause($0);lifecycle.pause($0)}
    for (index,reason) in order.enumerated() {
     lifecycle.resume(reason);lifecycle.resume(reason)
     precondition(lifecycle.canMonitor == (index==3))
    }
    lifecycle.pause(.locked);lifecycle.disable();lifecycle.resume(.locked)
    precondition(!lifecycle.canMonitor)
   }
   _ = NSApplication.shared
   guard let target=NSScreen.screens.first else {fatalError("No test display")}
   let app=DesktopApp();app.showsControls=false;app.lifecycle.enable()
   // Empty filter is an identity fixture only, never passed to capture APIs.
   let selection=SCContentFilter();app.filter=selection;app.screen=target
   app.startMonitoring(on:target)
   let oldSensor=app.sensor!,oldWatchdog=app.guardProcess!,oldMailbox=app.mailbox
   app.state.arm(angle:110);app.state.sample(80);app.state.captured()
   app.captureTask=Task {try? await Task.sleep(nanoseconds:10_000_000_000)}
   let ticket=app.generation
   app.pause(.locked);app.pause(.systemSleep);app.pause(.displaySleep)
   oldSensor.waitUntilExit();oldWatchdog.waitUntilExit()
   precondition(app.lifecycle.enabled && !app.lifecycle.canMonitor)
   precondition(app.sensor == nil && app.guardProcess == nil && app.timer == nil && app.overlay == nil)
   precondition(app.filter === selection && app.generation != ticket && app.captureTask == nil)
   app.resume(.systemSleep);app.resume(.displaySleep)
   app.resumeMonitoring(on:target);precondition(app.timer == nil) // Still locked.
   app.resume(.locked);app.resumeMonitoring(on:target)
   let freshSensor=app.sensor!,freshGuard=app.guardProcess!,freshTimer=app.timer!
   precondition(freshSensor.isRunning && freshGuard.isRunning && app.state.phase == .idle)
   precondition(app.mailbox !== oldMailbox && app.filter === selection)
   app.resume(.locked);app.resumeMonitoring(on:target)
   precondition(app.sensor === freshSensor && app.timer === freshTimer)
   precondition(app.unlockReference==110)
   app.armAfterResume(angle:80)
   precondition(app.state.phase == .capturing && app.state.progress>0 && app.unlockReference == nil)
   app.state.captured();app.state.sample(110)
   precondition(app.state.phase == .finished && app.state.progress==0)
   app.unlockReference=110;app.armAfterResume(angle:115)
   precondition(app.state.phase == .armed && app.state.progress==0)
   // User stop must win over every later wake/unlock callback.
   app.cleanup();freshSensor.waitUntilExit();freshGuard.waitUntilExit()
   app.resume(.locked);app.resumeMonitoring(on:target)
   precondition(app.timer == nil && !app.lifecycle.enabled && app.resumeTask == nil)
   print("PASS: 24 wake/unlock orders; live workers stop/restart; locked gate; duplicate resume; manual stop wins");return
  }
  if args.contains("--test-menu-actions") {
   _ = NSApplication.shared
   let app=DesktopApp();app.refreshStatusMenu()
   precondition(app.toggleItem.title=="开始折叠…")
   let selection=SCContentFilter();app.filter=selection;app.lifecycle.enable()
   app.refreshStatusMenu();precondition(app.toggleItem.title=="暂停折叠")
   app.toggleMonitoring()
   precondition(!app.lifecycle.enabled && app.filter === selection && app.timer == nil)
   precondition(app.toggleItem.title=="恢复折叠")
   app.resume(.locked);precondition(!app.lifecycle.enabled)
   app.toggleMonitoring()
   precondition(app.lifecycle.enabled && app.resumeTask != nil && app.filter === selection)
   app.state.arm(angle:110);app.state.sample(80);app.state.captured()
   let ticket=app.generation
   app.menuWillOpen(app.statusMenu)
   precondition(app.menuIsOpen && app.state.phase == .armed && app.generation != ticket)
   app.menuDidClose(app.statusMenu);precondition(!app.menuIsOpen)
   app.cleanup()
   print("PASS: menu pause/resume retains selection; wake respects pause; menu dismisses fold");return
  }
  if args.contains("--test-watchdog-alive") || args.contains("--test-watchdog-stall") {
   let pair=startWatchdog()
   // The old activation byte must not impose a hidden 25-second limit.
   try! pair.1.fileHandleForWriting.write(contentsOf:Data([65]))
   if args.contains("--test-watchdog-stall") { sleep(8); exit(9) }
   for _ in 0..<300 {
    try! pair.1.fileHandleForWriting.write(contentsOf:Data([72])); usleep(100_000)
   }
   try! pair.1.fileHandleForWriting.close(); pair.0.waitUntilExit()
   precondition(pair.0.terminationStatus==0)
   print("PASS: healthy parent survives 30 seconds; watchdog exits on pipe close"); return
  }
  if args.contains("--test-lower-sharp"){
   _ = NSApplication.shared
   let pair=startWatchdog()
   do{
    let source=FoldEngine.demo()
    let engine=try DispatchQueue.global(qos:.userInitiated).sync {try FoldEngine(rendering:true,image:source)}
    engine.params.progress=0.3
    engine.params.softness=0
    let a=engine.pixels(width:640,height:400)
    try! pair.1.fileHandleForWriting.write(contentsOf:Data([72]))
    engine.params.softness=1
    let b=engine.pixels(width:640,height:400)
    let lowerStart=640*200*4
    guard Array(a[lowerStart...])==Array(b[lowerStart...]) else{exit(2)}
    guard a != b else{exit(3)}
    engine.params.progress=0.4
    let visible=engine.pixels(width:640,height:400)
    let sample=(180*640+320)*4
    guard max(visible[sample],max(visible[sample+1],visible[sample+2]))>35 else{exit(4)}
    engine.params.progress=0;engine.params.softness=0
    let flat=engine.pixels(width:640,height:400)
    engine.params.softness=1
    precondition(flat==engine.pixels(width:640,height:400),"No frosting or sheen when fully open")
    engine.params.progress=0.18
    let forward=engine.pixels(width:640,height:400)
    engine.params.progress=0.6;_ = engine.pixels(width:640,height:400)
    engine.params.progress=0.18
    precondition(forward==engine.pixels(width:640,height:400),"Reversing to the same angle restores the same material")
    // With frosting disabled, every pixel must stay at its original desktop coordinate.
    engine.params.softness=0;engine.params.progress=0
    let stationary=engine.pixels(width:640,height:400)
    for progress:Float in [0.1,0.3,0.5,0.8] {
     engine.params.progress=progress
     precondition(stationary==engine.pixels(width:640,height:400),"Desktop must not geometrically fold or darken")
    }
    engine.params.softness=1
    engine.params.progress=0.2;let smallCover=engine.pixels(width:640,height:400)
    engine.params.progress=0.7;let largeCover=engine.pixels(width:640,height:400)
    let middle=640*240*4..<640*260*4
    precondition(Array(smallCover[middle])==Array(stationary[middle]),"Area below small cover must remain sharp")
    precondition(Array(largeCover[middle]) != Array(stationary[middle]),"Larger angle must advance frost beyond the old halfway boundary")
    let bottom=640*380*4..<640*400*4
    precondition(Array(largeCover[bottom])==Array(stationary[bottom]),"Uncovered bottom stays sharp")
    // Regression: the old renderer left this entire exposed region black when folding.
    for progress:Float in [0.1,0.3,0.5,0.8] {
     engine.params.progress=progress
     let frame=engine.pixels(width:640,height:400)
     if progress==0.3,let index=args.firstIndex(of:"--render-proof"),args.count>index+1 {
      let provider=CGDataProvider(data:Data(frame) as CFData)!
      let cg=CGImage(width:640,height:400,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:640*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
      try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[index+1]))
     }
     for y in 0..<190 {for x in 0..<640 {
      let i=(y*640+x)*4
      precondition(max(frame[i],max(frame[i+1],frame[i+2]))>10,"Black hole behind upper panel")
     }}
    }
    print("PASS: angle changes frost coverage, uncovered pixels stay sharp, stationary desktop and reversible material")
    try! pair.1.fileHandleForWriting.close();pair.0.waitUntilExit();exit(0)
   }catch{print(error);exit(1)}
  }
  let app=NSApplication.shared; app.setActivationPolicy(.accessory)
  let delegate=DesktopApp(); app.delegate=delegate; app.run(); withExtendedLifetime(delegate) {}
 }
}
