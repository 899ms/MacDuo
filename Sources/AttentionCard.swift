import Cocoa
import AVFoundation
import LocalAuthentication

final class AttentionCoverPanel:DesktopPanel {
 var requestRestore:(()->Void)?
 override var canBecomeKey:Bool {true}
 override func keyDown(with event:NSEvent) {if event.keyCode==53 {requestRestore?()}}
}

/// Liquid glass, natively: system blur underneath, a slowly flowing cool tint, a specular
/// sheen band drifting across, and a bright rim — layers instead of a flat HUD wash.
@MainActor final class AttentionCard:NSPanel {
 static let size=NSSize(width:460,height:330)
 // One luminance ladder for the whole card: hero white, secondary values, dim labels,
 // faint hints — plus the cool glass accent for the user's own reminder.
 static let primary=NSColor(calibratedWhite:1,alpha:0.98)
 static let secondary=NSColor(calibratedWhite:1,alpha:0.84)
 static let tertiary=NSColor(calibratedWhite:1,alpha:0.52)
 static let quaternary=NSColor(calibratedWhite:1,alpha:0.38)
 static let accent=NSColor(calibratedRed:0.64,green:0.90,blue:1.00,alpha:1)
 let heading=NSTextField(labelWithString:"暂时离开")
 let lead=NSTextField(labelWithString:"你此前连续注视屏幕")
 let clock=NSTextField(labelWithString:"0:00:00")
 let meta=NSTextField(labelWithString:"")
 let task=NSTextField(wrappingLabelWithString:"")
 let note=NSTextField(wrappingLabelWithString:"毛玻璃保持中")
 let restore=NSButton(title:"恢复清晰",target:nil,action:nil)
 var onRestore:(()->Void)?
 private var player:AVQueuePlayer?
 private var looper:AVPlayerLooper?
 init(screen:NSScreen) {
  // An optional companion loop (a personal asset, never shipped in public builds) widens the
  // card into a media-left layout; without it the card stays centered as before.
  // In glass style the loop lives on the full-screen frost instead of in the card.
  let glassStyle=AttentionPreferences.companionGlass && Bundle.main.url(forResource:"AttentionCompanion",withExtension:"mp4") != nil
  let companion=glassStyle ? nil : Bundle.main.url(forResource:"AttentionCompanion",withExtension:"mp4")
  let size=companion == nil ? Self.size : NSSize(width:660,height:344)
  // In glass style the hero owns the center of the screen; the card sits below center,
  // clear of the face but no longer hugging the bottom edge.
  let originY=glassStyle ? screen.frame.minY+screen.frame.height*0.32-size.height/2 : screen.frame.midY-size.height/2
  super.init(contentRect:NSRect(x:screen.frame.midX-size.width/2,y:originY,width:size.width,height:size.height),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  level=NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+1)
  isOpaque=false;backgroundColor = .clear;hasShadow=true;isReleasedWhenClosed=false
  // Liquid glass is a dark material: pin the appearance so the white type and cool tints
  // read the same over any desktop, light system theme included.
  appearance=NSAppearance(named:.vibrantDark)
  collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
  let radius:CGFloat=28
  let bounds=CGRect(origin:.zero,size:size)
  // Sample the desktop BEHIND the panel: within-window blending has nothing to blur here and
  // renders a muddy plate instead of glass.
  let background=NSVisualEffectView();background.material = .hudWindow;background.blendingMode = .behindWindow;background.state = .active
  background.wantsLayer=true;background.layer?.cornerRadius=radius;background.layer?.masksToBounds=true
  // The vibrancy material ignores the layer mask; only maskImage clips it, corners included.
  let cornerMask=NSImage(size:NSSize(width:radius*2+1,height:radius*2+1),flipped:false){rect in
   NSColor.black.setFill();NSBezierPath(roundedRect:rect,xRadius:radius,yRadius:radius).fill();return true
  }
  cornerMask.capInsets=NSEdgeInsets(top:radius,left:radius,bottom:radius,right:radius)
  cornerMask.resizingMode = .stretch
  background.maskImage=cornerMask
  contentView=background
  guard let host=background.layer else {fatalError("layer-backed visual effect view")}
  // The glass tint from the reference design: a light dark wash keeps white type readable
  // over bright desktops without giving up the transmission.
  let veil=CALayer();veil.frame=bounds
  veil.backgroundColor=NSColor(calibratedWhite:0,alpha:0.10).cgColor
  host.addSublayer(veil)
  // Flowing tint: cool glass hues whose balance drifts, so the material reads as liquid.
  let tint=CAGradientLayer();tint.frame=bounds
  tint.colors=[NSColor(calibratedRed:0.62,green:0.80,blue:1.00,alpha:0.14).cgColor,
               NSColor(calibratedWhite:1,alpha:0.13).cgColor,
               NSColor(calibratedRed:0.58,green:0.94,blue:0.96,alpha:0.12).cgColor]
  tint.locations=[0,0.45,1];tint.startPoint=CGPoint(x:0,y:1);tint.endPoint=CGPoint(x:1,y:0)
  let flow=CABasicAnimation(keyPath:"locations")
  flow.fromValue=[0,0.30,1];flow.toValue=[0,0.72,1]
  flow.duration=9;flow.autoreverses=true;flow.repeatCount = .infinity
  flow.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
  tint.add(flow,forKey:"flow");host.addSublayer(tint)
  // Specular sweep: one soft highlight band crossing every few seconds, no hard scan line.
  let sheen=CAGradientLayer();sheen.frame=bounds
  sheen.colors=[NSColor.clear.cgColor,NSColor(calibratedWhite:1,alpha:0.22).cgColor,NSColor.clear.cgColor]
  sheen.startPoint=CGPoint(x:0,y:0.9);sheen.endPoint=CGPoint(x:1,y:0.1)
  sheen.locations=[-0.4,-0.2,0]
  let sweep=CABasicAnimation(keyPath:"locations")
  sweep.fromValue=[-0.4,-0.2,0];sweep.toValue=[1,1.2,1.4]
  sweep.duration=6.5;sweep.repeatCount = .infinity
  sweep.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
  sheen.add(sweep,forKey:"sweep");host.addSublayer(sheen)
  // Top-light and rim give the pane its edge, like the inset shine of liquid glass cards.
  let topLight=CAGradientLayer();topLight.frame=CGRect(x:0,y:size.height*0.55,width:size.width,height:size.height*0.45)
  topLight.colors=[NSColor.clear.cgColor,NSColor(calibratedWhite:1,alpha:0.20).cgColor]
  topLight.startPoint=CGPoint(x:0.5,y:0);topLight.endPoint=CGPoint(x:0.5,y:1)
  host.addSublayer(topLight)
  let rim=CALayer();rim.frame=bounds;rim.cornerRadius=radius
  rim.borderWidth=1;rim.borderColor=NSColor(calibratedWhite:1,alpha:0.5).cgColor
  host.addSublayer(rim)
  let column=NSStackView();column.orientation = .vertical;column.alignment = .centerX;column.spacing=10
  var stack:NSStackView=column
  if let companion=companion {
   // The companion window is glass within glass: same radius family, same rim.
   let media=NSView();media.wantsLayer=true;media.translatesAutoresizingMaskIntoConstraints=false
   let mediaSize=NSSize(width:214,height:280)
   NSLayoutConstraint.activate([media.widthAnchor.constraint(equalToConstant:mediaSize.width),media.heightAnchor.constraint(equalToConstant:mediaSize.height)])
   let item=AVPlayerItem(url:companion)
   let queue=AVQueuePlayer();queue.isMuted=true
   queue.preventsDisplaySleepDuringVideoPlayback=false
   looper=AVPlayerLooper(player:queue,templateItem:item);player=queue
   let video=AVPlayerLayer(player:queue)
   video.frame=CGRect(origin:.zero,size:mediaSize);video.videoGravity = .resizeAspectFill
   video.cornerRadius=20;video.masksToBounds=true
   media.layer?.addSublayer(video)
   let mediaRim=CALayer();mediaRim.frame=CGRect(origin:.zero,size:mediaSize);mediaRim.cornerRadius=20
   mediaRim.borderWidth=1;mediaRim.borderColor=NSColor(calibratedWhite:1,alpha:0.4).cgColor
   media.layer?.addSublayer(mediaRim)
   let row=NSStackView();row.orientation = .horizontal;row.alignment = .centerY;row.spacing=26
   row.addArrangedSubview(media);row.addArrangedSubview(column)
   stack=row
   queue.play()
  }
  stack.translatesAutoresizingMaskIntoConstraints=false
  background.addSubview(stack)
  NSLayoutConstraint.activate([stack.leadingAnchor.constraint(greaterThanOrEqualTo:background.leadingAnchor,constant:28),stack.trailingAnchor.constraint(lessThanOrEqualTo:background.trailingAnchor,constant:-28),stack.centerXAnchor.constraint(equalTo:background.centerXAnchor),stack.centerYAnchor.constraint(equalTo:background.centerYAnchor)])
  heading.font = .systemFont(ofSize:19,weight:.semibold);heading.textColor=Self.primary
  lead.font = .systemFont(ofSize:12,weight:.medium);lead.textColor=Self.tertiary
  lead.attributedStringValue=NSAttributedString(string:lead.stringValue,attributes:[.font:lead.font!,.foregroundColor:Self.tertiary,.kern:1.5])
  clock.font = .monospacedDigitSystemFont(ofSize:46,weight:.thin);clock.textColor=Self.primary
  // A soft halo keeps the hero number reading as lit glass, not flat type.
  clock.wantsLayer=true
  let glow=NSShadow();glow.shadowColor=NSColor(calibratedRed:0.75,green:0.92,blue:1.0,alpha:0.45);glow.shadowBlurRadius=14;glow.shadowOffset=NSSize(width:0,height:0)
  clock.shadow=glow
  meta.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular);meta.textColor=Self.tertiary
  task.font = .systemFont(ofSize:14);task.alignment = .center;task.maximumNumberOfLines=2
  note.font = .systemFont(ofSize:11);note.textColor=Self.quaternary;note.alignment = .center;note.maximumNumberOfLines=2
  restore.bezelStyle = .rounded;restore.controlSize = .large;restore.target=self;restore.action=#selector(restoreClicked)
  for view in [heading,lead,clock,meta,task,note,restore] {column.addArrangedSubview(view)}
  column.setCustomSpacing(4,after:lead);column.setCustomSpacing(6,after:clock);column.setCustomSpacing(16,after:meta)
 }
 /// Stop the companion loop before the card is discarded.
 func retire() {player?.pause();player=nil;looper=nil}
 @objc func restoreClicked(){onRestore?()}
 override var canBecomeKey:Bool {true}
 override func keyDown(with event:NSEvent){if event.keyCode==53 {onRestore?()}}
 /// Dim labels, bright values: the numbers carry the information, the words only name it.
 func setMeta(away:String,today:String) {
  let line=NSMutableAttributedString()
  let label:[NSAttributedString.Key:Any]=[.font:meta.font!,.foregroundColor:Self.tertiary]
  let value:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:12,weight:.medium),.foregroundColor:Self.secondary]
  line.append(NSAttributedString(string:"已离开 ",attributes:label))
  line.append(NSAttributedString(string:away,attributes:value))
  line.append(NSAttributedString(string:"  ·  今日累计注视 ",attributes:label))
  line.append(NSAttributedString(string:today,attributes:value))
  meta.attributedStringValue=line
 }
 func setTask(reminder:String) {
  guard !reminder.isEmpty else {
   task.attributedStringValue=NSAttributedString(string:"休息一下，回来再继续。",attributes:[.font:task.font!,.foregroundColor:Self.secondary]);return
  }
  let line=NSMutableAttributedString()
  line.append(NSAttributedString(string:"待办  ",attributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:Self.tertiary,.kern:1.0]))
  line.append(NSAttributedString(string:reminder,attributes:[.font:NSFont.systemFont(ofSize:14,weight:.medium),.foregroundColor:Self.accent]))
  task.attributedStringValue=line
 }
}

@MainActor extension DesktopApp {
 func updateAttentionCard(now:Double) {
  // In glass style the companion performs its first full loop alone; the card then fades in.
  let glassIntro=glassVideoLayer != nil && now-glassVideoStartedAt<glassVideoDuration
  guard attentionMode,attentionHold.since != nil,renderer != nil,attentionAmount>0.65,!glassIntro,let screen=screen else {attentionCard?.retire();attentionCard?.orderOut(nil);attentionCard=nil;return}
  if attentionCard == nil {
   let card=AttentionCard(screen:screen);card.onRestore = {[weak self] in self?.requestAttentionRestore()};attentionCard=card
   attentionCardShownAt=now
   card.orderFrontRegardless()
  }
  guard let card=attentionCard else{return}
  let blurAlpha=Double(min(1,max(0,(attentionAmount-0.65)/0.35)))
  let introAlpha=min(1.0,max(0.0,(now-attentionCardShownAt)/0.8))
  card.alphaValue=CGFloat(blurAlpha*introAlpha)
  card.clock.stringValue=WorkTally.clock(workTally.stretch)
  card.setMeta(away:attentionHold.elapsed(at:now),today:WorkTally.phrase(workTally.today))
  card.heading.stringValue=attentionHold.locked && !attentionGate.away ? "欢迎回来" : "暂时离开"
  card.setTask(reminder:UserDefaults.standard.string(forKey:"attentionReminder") ?? "")
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
  attentionRestoreNotice=nil;attentionHold.reset();attentionRearm()
  workTally.endStretch();workTally.save();attentionBlurShown=false
  let now=ProcessInfo.processInfo.systemUptime
  attentionGate=AttentionGate()
  attentionIdle=AttentionIdleGate();attentionIdle.delay=AttentionPreferences.delaySeconds;attentionIdle.inputObserved(at:now)
  attentionSuppressedUntil=now+2
  NSApp.deactivate()
 }
}
