import Foundation

/// Continuous on-screen attention time plus a daily total that survives restarts.
/// Seconds accumulate only while the user is calibrated, facing and unblurred; a blur that
/// actually shows ends the stretch, while a short glance away merely pauses it.
struct WorkTally {
 private(set) var stretch=0.0
 private(set) var today=0.0
 private(set) var dateKey=""
 private var nextRollCheck=0.0
 mutating func present(_ dt:Double,at now:Double) {
  if now>=nextRollCheck {nextRollCheck=now+60;roll(to:Self.currentDateKey())}
  stretch+=dt;today+=dt
 }
 mutating func roll(to key:String) {
  guard key != dateKey else{return}
  dateKey=key;today=0
 }
 mutating func endStretch() {stretch=0}
 mutating func load() {
  dateKey=Self.currentDateKey()
  let defaults=UserDefaults.standard
  today=defaults.string(forKey:"attentionWorkDate")==dateKey ? defaults.double(forKey:"attentionWorkToday") : 0
 }
 func save() {
  // Never write from a tally that was never loaded (self-test runs share the real defaults).
  guard !dateKey.isEmpty else{return}
  let defaults=UserDefaults.standard
  defaults.set(dateKey,forKey:"attentionWorkDate");defaults.set(today,forKey:"attentionWorkToday")
 }
 static func currentDateKey(_ date:Date=Date())->String {
  let formatter=DateFormatter();formatter.dateFormat="yyyyMMdd";formatter.timeZone = .current
  return formatter.string(from:date)
 }
 static func clock(_ seconds:Double)->String {
  let s=max(0,Int(seconds))
  return String(format:"%d:%02d:%02d",s/3600,(s/60)%60,s%60)
 }
 static func phrase(_ seconds:Double)->String {
  let s=max(0,Int(seconds))
  if s<60 {return "\(s) 秒"}
  if s<3600 {return "\(s/60) 分钟"}
  return String(format:"%d 小时 %02d 分",s/3600,(s/60)%60)
 }
}
