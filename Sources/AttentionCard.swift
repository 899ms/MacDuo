import Cocoa
import LocalAuthentication

final class AttentionCoverPanel:DesktopPanel {
 var requestRestore:(()->Void)?
 override var canBecomeKey:Bool {true}
 override func keyDown(with event:NSEvent) {if event.keyCode==53 {requestRestore?()}}
}

@MainActor final class AttentionCard:NSPanel {
 let heading=NSTextField(labelWithString:"暂时离开")
 let clock=NSTextField(labelWithString:"00:00:00")
 let task=NSTextField(wrappingLabelWithString:"")
 let note=NSTextField(wrappingLabelWithString:"毛玻璃保持中")
 let restore=NSButton(title:"恢复清晰",target:nil,action:nil)
 var onRestore:(()->Void)?
 init(screen:NSScreen) {
  super.init(contentRect:NSRect(x:screen.frame.midX-210,y:screen.frame.midY-130,width:420,height:260),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  level=NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+1)
  isOpaque=false;backgroundColor = .clear;hasShadow=true;isReleasedWhenClosed=false
  collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
  let background=NSVisualEffectView();background.material = .hudWindow;background.blendingMode = .withinWindow;background.state = .active
  background.wantsLayer=true;background.layer?.cornerRadius=22;background.layer?.masksToBounds=true
  contentView=background
  let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .centerX;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false
  background.addSubview(stack)
  NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:background.leadingAnchor,constant:28),stack.trailingAnchor.constraint(equalTo:background.trailingAnchor,constant:-28),stack.centerYAnchor.constraint(equalTo:background.centerYAnchor)])
  heading.font = .systemFont(ofSize:18,weight:.semibold)
  clock.font = .monospacedDigitSystemFont(ofSize:34,weight:.light)
  task.font = .systemFont(ofSize:14);task.alignment = .center;task.maximumNumberOfLines=2
  note.font = .systemFont(ofSize:12);note.textColor = .secondaryLabelColor;note.alignment = .center;note.maximumNumberOfLines=2
  restore.bezelStyle = .rounded;restore.controlSize = .large;restore.target=self;restore.action=#selector(restoreClicked)
  for view in [heading,clock,task,note,restore] {stack.addArrangedSubview(view)}
 }
 @objc func restoreClicked(){onRestore?()}
 override var canBecomeKey:Bool {true}
 override func keyDown(with event:NSEvent){if event.keyCode==53 {onRestore?()}}
}

@MainActor extension DesktopApp {
 func updateAttentionCard(now:Double) {
  guard attentionMode,attentionHold.since != nil,renderer != nil,attentionAmount>0.65,let screen=screen else {attentionCard?.orderOut(nil);attentionCard=nil;return}
  if attentionCard == nil {
   let card=AttentionCard(screen:screen);card.onRestore = {[weak self] in self?.requestAttentionRestore()};attentionCard=card
   card.orderFrontRegardless()
  }
  guard let card=attentionCard else{return}
  card.alphaValue=CGFloat(min(1,max(0,(attentionAmount-0.65)/0.35)))
  card.clock.stringValue=attentionHold.elapsed(at:now)
  card.heading.stringValue=attentionHold.locked && !attentionGate.away ? "欢迎回来" : "暂时离开"
  let reminder=UserDefaults.standard.string(forKey:"attentionReminder") ?? ""
  card.task.stringValue=reminder.isEmpty ? "休息一下，回来再继续。" : "待办 · "+reminder
  card.note.stringValue=attentionRestoreNotice ?? (attentionHold.locked ? "已保持模糊，回到座位后确认恢复。" : "重新面向屏幕即可恢复。")
  card.restore.title=AttentionPreferences.requiresAuthentication ? "验证身份并恢复" : "恢复清晰"
  card.restore.isEnabled = !attentionAuthenticating
 }
 @objc func requestAttentionRestore() {
  guard attentionMode else {clearFoldResources();state.yieldToUser();return}
  guard !attentionAuthenticating else{return}
  guard attentionHold.locked,AttentionPreferences.requiresAuthentication else {finishAttentionRestore();return}
  let context=LAContext();var error:NSError?
  guard context.canEvaluatePolicy(.deviceOwnerAuthentication,error:&error) else {
   attentionRestoreNotice="系统身份验证不可用，可通过菜单栏暂停。";return
  }
  attentionRestoreNotice=nil;attentionAuthContext=context;attentionAuthenticating=true
  let ticket=attentionTicket
  context.evaluatePolicy(.deviceOwnerAuthentication,localizedReason:"恢复 MacDuo 清晰桌面") { [weak self] success,_ in
   Task { @MainActor in
    guard let self=self,self.attentionTicket==ticket else{return}
    self.attentionAuthenticating=false;self.attentionAuthContext=nil
    if success {self.finishAttentionRestore()}
    else {self.attentionRestoreNotice="验证未完成，仍保持模糊。可再次点击恢复。"}
   }
  }
 }
 func finishAttentionRestore() {
  attentionAuthContext?.invalidate();attentionAuthContext=nil;attentionAuthenticating=false
  attentionRestoreNotice=nil;attentionHold.reset();clearFoldResources();state.arm(angle:100);attentionAmount=0
  attentionGate=AttentionGate();attentionGate.awayDelay=AttentionPreferences.delaySeconds
  attentionSuppressedUntil=ProcessInfo.processInfo.systemUptime+2
  NSApp.deactivate()
 }
}
