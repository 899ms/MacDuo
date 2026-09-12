import Foundation

// Each completed fold returns to .armed. No rendering or capture between cycles.
struct FoldSession {
 enum Phase: Equatable { case idle, armed, capturing, folding, finished }
 private(set) var phase: Phase = .idle
 private(set) var baseline = 0.0
 private(set) var angle = 0.0
 private(set) var progress = 0.0
 mutating func arm(angle: Double) {
  baseline=angle; self.angle=angle; progress=0; phase = .armed
 }
 mutating func sample(_ value: Double) {
  guard phase == .armed || phase == .capturing || phase == .folding else { return }
  angle=value
  if phase == .armed {
   baseline=max(baseline,value)
   if baseline-value < 3 { return }
   phase = .capturing
  }
  if value >= baseline-1.5 { progress=0; phase = .finished; return }
  progress=max(0,min(1,(baseline-value-1.5)/max(1,baseline-1.5)))
 }
 mutating func captured() { if phase == .capturing { phase = .folding } }
 mutating func rearm() {
  guard phase == .finished else { return }
  // Keep the original open reference; tolerance must not drift lower each cycle.
  baseline=max(baseline,angle); progress=0; phase = .armed
 }
 mutating func yieldToUser() {
  guard phase == .armed || phase == .capturing || phase == .folding else { return }
  // The current working angle becomes the new reference. A held lid must not retrigger.
  arm(angle:angle)
 }
 mutating func finish() { phase = .finished; progress=0 }
}
