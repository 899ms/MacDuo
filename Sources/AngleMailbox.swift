import Foundation

func clamp<T:Comparable>(_ value:T,_ low:T,_ high:T)->T{min(high,max(low,value))}

/// One latest-value slot: producer rate can never build a main-thread task queue.
// All mutable state is guarded by lock.
final class AngleMailbox: @unchecked Sendable {
 private let lock=NSLock()
 private var newest:(Double,Double)?
 func put(_ angle:Double,at time:Double){
  guard angle.isFinite,(0...360).contains(angle) else{return}
  lock.lock();newest=(angle,time);lock.unlock()
 }
 func take()->(Double,Double)?{
  lock.lock();defer{lock.unlock()};let value=newest;newest=nil;return value
 }
}
