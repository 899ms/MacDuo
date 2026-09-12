import AVFoundation
import Foundation

struct HingeMotion {
 var low:Double?
 var high:Double?
 var last:Double?
 var lastSample:Double?
 var fired=false
 mutating func sample(_ angle:Double,at now:Double)->Bool {
  if lastSample == nil || now-(lastSample ?? now)>3 {
   low=angle;high=angle;fired=false;last=angle;lastSample=now;return false
  }
  lastSample=now;last=angle
  high=max(high ?? angle,angle)
  // Ignore sensor dithering; rearm only after meaningful closing movement.
  if (high ?? angle)-angle>=2 {low=angle;high=angle;fired=false}
  low=min(low ?? angle,angle)
  if !fired,angle-(low ?? angle)>=2 {fired=true;return true}
  return false
 }
}
@MainActor final class HingeSound {
 var motion=HingeMotion()
 var player:AVAudioPlayer?
 var enabled:Bool {
  get {UserDefaults.standard.object(forKey:"hingeSoundEnabled") as? Bool ?? false}
  set {UserDefaults.standard.set(newValue,forKey:"hingeSoundEnabled");if !newValue {stop()}}
 }
 var audioURL:URL? {
  let custom=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacDuo/HingeCreak.wav")
  return FileManager.default.fileExists(atPath:custom.path) ? custom : Bundle.main.url(forResource:"HingeCreak",withExtension:"wav")
 }
 var onEvent:((String)->Void)?
 func sample(_ angle:Double,at now:Double) {
  let opening=motion.sample(angle,at:now)
  guard enabled,opening else{return}
  play()
 }
 func play() {
  do {
   if player == nil {
    guard let url=audioURL else {
     onEvent?("sound missing");return
    }
    player=try AVAudioPlayer(contentsOf:url);player?.volume=0.50;player?.prepareToPlay()
   }
   guard player?.isPlaying != true else{return}
   player?.currentTime=0
   let started=player?.play() ?? false
   onEvent?(started ? "opening sound started" : "opening sound playback failed")
  } catch {onEvent?("opening sound error: \(error.localizedDescription)")}
 }
 func stop() {player?.stop();motion=HingeMotion()}
}
