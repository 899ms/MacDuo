import CoreGraphics

// Activity counts only: no key contents, event interception, or accessibility permission.
struct InputActivity: Equatable {
 let counts: [UInt32]
 static func current() -> InputActivity {
  let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
   .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged, .rightMouseDragged]
  return InputActivity(counts: types.map { CGEventSource.counterForEventType(.combinedSessionState,eventType:$0) })
 }
}
