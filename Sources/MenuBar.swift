import Cocoa

@MainActor extension DesktopApp {
 func installStatusItem() {
  guard statusItem == nil else{return}
  let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
  item.autosaveName="DuoFoldMenuBar"
  let image=NSImage(systemSymbolName:"macbook",accessibilityDescription:"MacDuo") ?? NSImage(systemSymbolName:"display",accessibilityDescription:"MacDuo")
  image?.size=NSSize(width:16,height:16);image?.isTemplate=true
  item.button?.image=image
  item.button?.setAccessibilityLabel("MacDuo 桌面折叠")
  statusMenu.delegate=self;statusMenu.autoenablesItems=false
  let heading=NSMenuItem(title:"MacDuo",action:nil,keyEquivalent:"");heading.isEnabled=false
  menuStatus.isEnabled=false;menuDetail.isEnabled=false
  toggleItem.target=self
  statusMenu.addItem(heading);statusMenu.addItem(menuStatus);statusMenu.addItem(menuDetail)
  statusMenu.addItem(.separator())
  let fold=NSMenuItem(title:"切换到合盖模式",action:#selector(chooseFoldMode),keyEquivalent:"");fold.target=self;statusMenu.addItem(fold)
  let attention=NSMenuItem(title:"切换到注视模式（摄像头）",action:#selector(chooseAttentionMode),keyEquivalent:"");attention.target=self;statusMenu.addItem(attention)
  statusMenu.addItem(.separator());statusMenu.addItem(toggleItem)
  soundItem.target=self;statusMenu.addItem(soundItem)
  let preview=NSMenuItem(title:"试听开盖音效",action:#selector(previewSound),keyEquivalent:"");preview.target=self;preview.isEnabled=hingeSound.audioURL != nil;statusMenu.addItem(preview)
  let settings=NSMenuItem(title:"打开控制窗口…",action:#selector(showController),keyEquivalent:"");settings.target=self;statusMenu.addItem(settings)
  statusMenu.addItem(.separator())
  let quit=NSMenuItem(title:"退出 MacDuo",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");quit.target=NSApp;statusMenu.addItem(quit)
  item.menu=statusMenu;statusItem=item;refreshStatusMenu()
 }
 func refreshStatusMenu() {
  soundItem.isEnabled=hingeSound.audioURL != nil
  soundItem.title=hingeSound.audioURL == nil ? "开盖音效（未安装音频）" : "开盖音效"
  soundItem.state=hingeSound.enabled ? .on : .off
  if selecting {menuStatus.title="正在选择屏幕"}
  else if lifecycle.enabled && !lifecycle.canMonitor {menuStatus.title="系统休眠或锁屏中 · 解锁后自动恢复"}
  else if lifecycle.enabled && attentionMode {menuStatus.title=activityText}
  else if lifecycle.enabled {
   menuStatus.title=standby.resting ? "待机 · 再次合盖自动唤醒" : (state.phase == .folding ? "正在折叠" : "已开启 · 等待合盖")
  } else {menuStatus.title=filter == nil ? "尚未开始" : "已暂停"}
  menuDetail.title=activityText
  menuDetail.isHidden = !lifecycle.canMonitor || state.phase == .idle
  toggleItem.title=lifecycle.enabled ? "暂停折叠" : (filter == nil ? "开始折叠…" : "恢复折叠")
  toggleItem.isEnabled = !selecting
  statusItem?.button?.toolTip="MacDuo · "+menuStatus.title
 }
 func menuWillOpen(_ menu:NSMenu) {
  menuIsOpen=true;hingeSound.stop();attentionAmount=0;attentionSuppressedUntil=ProcessInfo.processInfo.systemUptime+2
  if state.phase == .capturing || state.phase == .folding {
   clearFoldResources();state.yieldToUser()
  }
  refreshStatusMenu()
 }
 func menuDidClose(_ menu:NSMenu) {
  menuIsOpen=false;lastInputActivity=InputActivity.current()
 }
 @objc func toggleMonitoring() {
  if lifecycle.enabled {
   lifecycle.disable();unlockReference=nil;suspendMonitoring()
   activityText="已暂停 · 点击恢复折叠可继续"
   message.stringValue=activityText
   record("paused by user from menu bar")
  } else if filter != nil {
   lifecycle.enable();sensorFailures=0;scheduleResume()
   record("resumed by user from menu bar")
  } else {start()}
  refreshStatusMenu()
 }
 @objc func previewSound() {hingeSound.play()}
 @objc func toggleSound() {hingeSound.enabled.toggle();refreshStatusMenu()}
 @objc func openStatusMenu() {statusItem?.button?.performClick(nil)}
 @objc func showController() {
  window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
 }
}
