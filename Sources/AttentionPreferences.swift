import Cocoa

@MainActor final class AttentionPreferences:NSStackView,NSTextFieldDelegate {
 let delay=NSPopUpButton()
 let hold=NSButton(checkboxWithTitle:"模糊后保持，手动恢复清晰",target:nil,action:nil)
 let authentication=NSButton(checkboxWithTitle:"恢复时使用 Touch ID／系统密码验证",target:nil,action:nil)
 let reminder=NSTextField(string:UserDefaults.standard.string(forKey:"attentionReminder") ?? "")
 let times=[1.0,3,5,10,30,60,120,300]
 var onChange:(()->Void)?
 static var delaySeconds:Double {
  let value=UserDefaults.standard.double(forKey:"attentionDelay")
  return [1.0,3,5,10,30,60,120,300].contains(value) ? value : 1
 }
 static var requiresAuthentication:Bool {UserDefaults.standard.bool(forKey:"attentionRestoreAuth")}
 static var keepsBlur:Bool {UserDefaults.standard.object(forKey:"attentionKeepsBlur") as? Bool ?? true}
 override init(frame:NSRect) {
  super.init(frame:frame);orientation = .vertical;alignment = .leading;spacing=10
  let row=NSStackView();row.orientation = .horizontal;row.spacing=8
  row.addArrangedSubview(NSTextField(labelWithString:"离开多久后模糊"))
  delay.addItems(withTitles:["1 秒","3 秒","5 秒","10 秒","30 秒","1 分钟","2 分钟","5 分钟"])
  delay.selectItem(at:times.firstIndex(of:Self.delaySeconds) ?? 0)
  delay.target=self;delay.action=#selector(changed);row.addArrangedSubview(delay)
  hold.state=Self.keepsBlur ? .on:.off;hold.target=self;hold.action=#selector(changed)
  authentication.state=Self.requiresAuthentication ? .on:.off;authentication.target=self;authentication.action=#selector(changed)
  reminder.placeholderString="待办提醒，例如：回来先完成设计稿"
  reminder.delegate=self;reminder.maximumNumberOfLines=1
  addArrangedSubview(row);addArrangedSubview(hold);addArrangedSubview(authentication)
  addArrangedSubview(NSTextField(labelWithString:"模糊画面显示离开时长与待办"));addArrangedSubview(reminder)
  reminder.widthAnchor.constraint(equalToConstant:390).isActive=true
 }
 required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
 @objc func changed() {
  UserDefaults.standard.set(times[max(0,delay.indexOfSelectedItem)],forKey:"attentionDelay")
  UserDefaults.standard.set(hold.state == .on,forKey:"attentionKeepsBlur")
  UserDefaults.standard.set(authentication.state == .on,forKey:"attentionRestoreAuth")
  onChange?()
 }
 func controlTextDidChange(_ obj:Notification) {
  let text=String(reminder.stringValue.prefix(160))
  UserDefaults.standard.set(text,forKey:"attentionReminder")
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
