import Cocoa

@MainActor final class AttentionPreferences:NSStackView,NSTextFieldDelegate {
 let delay=NSPopUpButton()
 let hold=NSButton(checkboxWithTitle:"离开后保持模糊，回来需手动确认",target:nil,action:nil)
 let authentication=NSButton(checkboxWithTitle:"恢复时使用 Touch ID／系统密码验证（自动保持模糊）",target:nil,action:nil)
 let reminder=NSTextField(string:UserDefaults.standard.string(forKey:"attentionReminder") ?? "")
 static let times=[0.0,3,5,10,15,30,60,120,300]
 static let defaultDelay=10.0
 var onChange:(()->Void)?
 // Mirrors the lock screen's password delay: a grace period, not an instant trigger.
 static var delaySeconds:Double {
  // "Immediately" stores 0, which is also what an absent key reads as; only trust a real entry.
  guard let value=UserDefaults.standard.object(forKey:"attentionDelay") as? Double else {return defaultDelay}
  return times.contains(value) ? value : defaultDelay
 }
 static var requiresAuthentication:Bool {UserDefaults.standard.bool(forKey:"attentionRestoreAuth")}
 /// Without a verification step there is nothing to confirm, so simply looking back clears the
 /// blur. Holding it is only the default once identity verification guards the restore.
 static var keepsBlur:Bool {
  requiresAuthentication || (UserDefaults.standard.object(forKey:"attentionKeepsBlur") as? Bool ?? false)
 }
 override init(frame:NSRect) {
  super.init(frame:frame);orientation = .vertical;alignment = .leading;spacing=10
  let row=NSStackView();row.orientation = .horizontal;row.spacing=8
  row.addArrangedSubview(NSTextField(labelWithString:"离开且无操作多久后模糊"))
  delay.addItems(withTitles:["立刻","3 秒","5 秒","10 秒","15 秒","30 秒","1 分钟","2 分钟","5 分钟"])
  delay.selectItem(at:Self.times.firstIndex(of:Self.delaySeconds) ?? 0)
  delay.target=self;delay.action=#selector(changed);row.addArrangedSubview(delay)
  hold.state=Self.keepsBlur ? .on:.off;hold.target=self;hold.action=#selector(changed)
  authentication.state=Self.requiresAuthentication ? .on:.off;authentication.target=self;authentication.action=#selector(changed)
  reminder.placeholderString="待办提醒，例如：回来先完成设计稿"
  reminder.delegate=self;reminder.maximumNumberOfLines=1
  let explain=NSTextField(wrappingLabelWithString:"计时要求「没有面向屏幕」与「没有键盘鼠标操作」同时成立；任一条件中断即清零重新计时。两项都不勾选时，重新面向屏幕即自动恢复清晰，无需任何操作。")
  explain.font = .systemFont(ofSize:11);explain.textColor = .secondaryLabelColor
  addArrangedSubview(row);addArrangedSubview(explain);addArrangedSubview(hold);addArrangedSubview(authentication)
  addArrangedSubview(NSTextField(labelWithString:"模糊画面显示离开时长与待办"));addArrangedSubview(reminder)
  reminder.widthAnchor.constraint(equalToConstant:390).isActive=true
 }
 required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
 @objc func changed() {
  UserDefaults.standard.set(Self.times[clamp(delay.indexOfSelectedItem,0,Self.times.count-1)],forKey:"attentionDelay")
  UserDefaults.standard.set(hold.state == .on,forKey:"attentionKeepsBlur")
  UserDefaults.standard.set(authentication.state == .on,forKey:"attentionRestoreAuth")
  onChange?()
 }
 func controlTextDidChange(_ obj:Notification) {
  let text=String(reminder.stringValue.prefix(160))
  UserDefaults.standard.set(text,forKey:"attentionReminder")
 }
}

/// Blur only once look-away and input idleness have both held for the configured delay.
/// Either condition breaking restarts the countdown, so working at the machine never blurs it.
struct AttentionIdleGate {
 var delay=10.0
 private(set) var idleSince=0.0
 mutating func inputObserved(at now:Double) {idleSince=now}
 func start(awaySince:Double)->Double {max(awaySince,idleSince)}
 func ready(away:Bool,awaySince:Double,at now:Double)->Bool {
  away && now-start(awaySince:awaySince)>=delay
 }
}

struct AttentionHold {
 var since:Double?
 var locked=false
 mutating func update(away:Bool,started:Double,keep:Bool) {
  if away {if since == nil {since=started};if keep {locked=true}}
  else if !locked {since=nil}
 }
 mutating func reset(){since=nil;locked=false}
 func elapsed(at now:Double)->String {
  let seconds=max(0,Int(now-(since ?? now)))
  return String(format:"%02d:%02d:%02d",seconds/3600,(seconds/60)%60,seconds%60)
 }
}
