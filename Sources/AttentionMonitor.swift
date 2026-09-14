import AVFoundation
import Vision

/// Debounce head direction; never obscure the desktop before seeing a valid face.
struct AttentionGate {
 var awayDelay=1.0
 var calibrated=false
 var away=false
 var candidate:Bool?
 var since=0.0
 mutating func sample(facing:Bool,at now:Double) {
  if !calibrated {
   if !facing {candidate=nil;return}
   if candidate != false {candidate=false;since=now}
   if now-since>=0.5 {calibrated=true;candidate=nil}
   return
  }
  let next = !facing
  if next==away {candidate=nil;return}
  if candidate != next {candidate=next;since=now}
  if now-since >= (next ? awayDelay : 0.20) {away=next;candidate=nil}
 }
}

/// All camera work and Vision requests are serialized away from the UI thread.
/// No frames, landmarks or biometric identifiers are persisted or transmitted.
final class AttentionMonitor:NSObject,AVCaptureVideoDataOutputSampleBufferDelegate {
 let queue=DispatchQueue(label:"MacDuo.attention",qos:.utility)
 let session=AVCaptureSession()
 private var active=false
 private var lastFrame=0.0
 var onSample:((Bool)->Void)?
 var onDetail:((String)->Void)?
 var onError:((String)->Void)?
 func start() {
  queue.async { [self] in
   active=true
   do {
    let discovered=AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.external,.continuityCamera],mediaType:.video,position:.unspecified).devices
    onDetail?("cameras: "+discovered.map{"\($0.localizedName)[\($0.deviceType.rawValue)]"}.joined(separator:", "))
    // Only the Mac's own FaceTime camera watches for presence — never a Continuity iPhone
    // or Desk View feed, which look at the wrong thing entirely.
    guard let device=discovered.first(where:{$0.deviceType == .builtInWideAngleCamera}) else {
     throw NSError(domain:"MacDuo",code:1,userInfo:[NSLocalizedDescriptionKey:"未找到内置摄像头"])
    }
    onDetail?("using camera: \(device.localizedName)")
    let input=try AVCaptureDeviceInput(device:device)
    session.beginConfiguration();session.sessionPreset = .vga640x480
    let output=AVCaptureVideoDataOutput();output.alwaysDiscardsLateVideoFrames=true
    output.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
    guard session.canAddInput(input),session.canAddOutput(output) else {
     session.commitConfiguration()
     throw NSError(domain:"MacDuo",code:2,userInfo:[NSLocalizedDescriptionKey:"摄像头无法启动或被其他应用占用"])
    }
    session.addInput(input);session.addOutput(output)
    output.setSampleBufferDelegate(self,queue:queue)
    // The capture device runs at a modest rate; inference is additionally capped at 5 Hz.
    if let range=device.activeFormat.videoSupportedFrameRateRanges.first,range.minFrameRate<=15,range.maxFrameRate>=15 {
     if (try? device.lockForConfiguration()) != nil {
      device.activeVideoMinFrameDuration=CMTime(value:1,timescale:15)
      device.activeVideoMaxFrameDuration=CMTime(value:1,timescale:15)
      device.unlockForConfiguration()
     }
    }
    session.commitConfiguration();session.startRunning()
    if !session.isRunning {onError?("摄像头未能运行，请检查系统摄像头权限")}
   } catch {onError?(error.localizedDescription)}
  }
 }
 func stop() {
  queue.async { [self] in
   active=false;session.stopRunning()
   for output in session.outputs { (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil,queue:nil);session.removeOutput(output) }
   for input in session.inputs {session.removeInput(input)}
  }
 }
 func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
  let now=ProcessInfo.processInfo.systemUptime
  guard active,now-lastFrame>=0.2,let pixel=CMSampleBufferGetImageBuffer(sampleBuffer) else{return}
  lastFrame=now
  autoreleasepool {
   do {
    let request=VNDetectFaceRectanglesRequest();request.revision=VNDetectFaceRectanglesRequestRevision3
    try VNImageRequestHandler(cvPixelBuffer:pixel,orientation:.up,options:[:]).perform([request])
    // Follow the dominant nearby face, not any bystander in the background.
    let face=request.results?.filter{$0.confidence>=0.6}.max { a,b in
     a.boundingBox.width*a.boundingBox.height < b.boundingBox.width*b.boundingBox.height
    }
    // Generous pose tolerance. The camera sits above the display, so reading the lower half of
    // a laptop screen already tilts the head well past a strict pitch limit, and glancing at the
    // keyboard must not read as leaving. Only a clear turn away from the machine counts.
    // A detected face whose pose the request cannot resolve still means someone is present.
    let facing:Bool
    if let face=face {
     let yaw=face.yaw?.doubleValue ?? 0, pitch=face.pitch?.doubleValue ?? 0
     facing=face.boundingBox.width>=0.08 && abs(yaw)<0.60 && abs(pitch)<0.55
    } else {facing=false}
    if let face=face {
     onDetail?(String(format:"box=%.2f conf=%.2f yaw=%@ pitch=%@ facing=%@",face.boundingBox.width,face.confidence,face.yaw.map{String(format:"%.2f",$0.doubleValue)} ?? "nil",face.pitch.map{String(format:"%.2f",$0.doubleValue)} ?? "nil",facing ? "Y":"N"))
    } else {onDetail?("no face")}
    onSample?(facing)
   } catch {onError?("人脸方向识别失败："+error.localizedDescription)}
  }
 }
}
