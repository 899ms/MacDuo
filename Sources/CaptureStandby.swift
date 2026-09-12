// Time since meaningful lid movement, not ordinary work in other applications.
// Retain only the user-selected filter and HID monitoring while rendering is asleep.
struct CaptureStandby {
 private(set) var resting=false
 private var lastMotion:Double
 private var anchor:Double?
 init(now:Double=0) {lastMotion=now}
 mutating func observe(angle:Double,now:Double) {
  if let reference=anchor {
   if abs(angle-reference)>=2 {anchor=angle;lastMotion=now}
  } else {anchor=angle;lastMotion=now}
 }
 func shouldRest(now:Double)->Bool {!resting && now-lastMotion>=90}
 mutating func rest() {resting=true}
 mutating func wake(now:Double) {resting=false;lastMotion=now}
}
