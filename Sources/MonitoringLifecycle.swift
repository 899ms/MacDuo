import Foundation

// User intent survives temporary loss of the desktop. Resume only after all blockers clear.
struct MonitoringLifecycle {
 enum Blocker: Hashable { case systemSleep, displaySleep, locked, inactiveSession }
 private(set) var enabled=false
 private(set) var blockers=Set<Blocker>()
 var canMonitor: Bool { enabled && blockers.isEmpty }
 mutating func enable() { enabled=true }
 mutating func disable() { enabled=false }
 mutating func pause(_ reason: Blocker) { blockers.insert(reason) }
 mutating func resume(_ reason: Blocker) { blockers.remove(reason) }
}
