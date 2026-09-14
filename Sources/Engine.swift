import Cocoa
import MetalKit
import CoreImage
import AVFoundation

struct FoldParams {
 var progress:Float=0, mode:Float=0, softness:Float=0.62, shadow:Float=0.65
 var perspective:Float=0.6, aspect:Float=1.6, sourceAspect:Float=1.6, padding:Float = -1
}
final class FoldEngine:NSObject,MTKViewDelegate {
 let device:MTLDevice
 let queue:MTLCommandQueue
 let pipeline:MTLRenderPipelineState
 let desktopPipeline:MTLRenderPipelineState
 let depth:MTLDepthStencilState
 let vertices:MTLBuffer
 let count:Int
 let inFlight=DispatchSemaphore(value:2)
 var sharp:MTLTexture!,blurred:MTLTexture!,lightBlur:MTLTexture!
 var params=FoldParams()
 let ci=CIContext()
 init(rendering:Bool,image:CGImage?=nil) throws {
  guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else {throw NSError(domain:"Metal unavailable",code:1)}
  device=d;queue=q
  let url=Bundle.main.url(forResource:"Fold",withExtension:"metal")!
  let library=try d.makeLibrary(source:String(contentsOf:url,encoding:.utf8),options:nil)
  let desc=MTLRenderPipelineDescriptor();desc.vertexFunction=library.makeFunction(name:"foldVertex");desc.fragmentFunction=library.makeFunction(name:"foldFragment");desc.colorAttachments[0].pixelFormat = .bgra8Unorm;desc.depthAttachmentPixelFormat = .depth32Float
  pipeline=try d.makeRenderPipelineState(descriptor:desc)
  desc.vertexFunction=library.makeFunction(name:"desktopVertex")
  desktopPipeline=try d.makeRenderPipelineState(descriptor:desc)
  let dd=MTLDepthStencilDescriptor();dd.depthCompareFunction = .lessEqual;dd.isDepthWriteEnabled=true;depth=d.makeDepthStencilState(descriptor:dd)!
  var grid=[SIMD2<Float>]();let nx=60,ny=60
  for j in 0..<ny {for i in 0..<nx {let a=SIMD2<Float>(Float(i)/Float(nx),Float(j)/Float(ny)),b=SIMD2<Float>(Float(i+1)/Float(nx),a.y),c=SIMD2<Float>(a.x,Float(j+1)/Float(ny)),e=SIMD2<Float>(b.x,c.y);grid += [a,c,b,b,c,e]}}
  count=grid.count;vertices=d.makeBuffer(bytes:grid,length:MemoryLayout<SIMD2<Float>>.stride*grid.count)!
  super.init();try setImage(image ?? Self.demo())
 }
 static func demo()->CGImage {
  let size=NSSize(width:1600,height:1000);let image=NSImage(size:size)
  image.lockFocus();NSGradient(starting:NSColor(calibratedRed:0.09,green:0.17,blue:0.23,alpha:1),ending:NSColor(calibratedRed:0.12,green:0.45,blue:0.47,alpha:1))!.draw(in:NSRect(origin:.zero,size:size),angle:75)
  for i in 0..<9 {let path=NSBezierPath();let y=Double(200+i*37);path.move(to:NSPoint(x:0,y:0));path.line(to:NSPoint(x:0,y:y));path.curve(to:NSPoint(x:1600,y:y+80),controlPoint1:NSPoint(x:600,y:y+300),controlPoint2:NSPoint(x:1150,y:y-100));path.line(to:NSPoint(x:1600,y:0));path.close();NSColor(calibratedWhite:0.04,alpha:0.035).setFill();path.fill()}
  func text(_ value:String,_ y:CGFloat,_ size:CGFloat,_ weight:NSFont.Weight){let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:NSColor.white];let w=(value as NSString).size(withAttributes:attrs).width;(value as NSString).draw(at:NSPoint(x:(1600-w)/2,y:y),withAttributes:attrs)}
  text("MacDuo",570,78,.light);text("A little motion. A different feeling.",523,22,.regular)
  NSColor(white:1,alpha:0.14).setFill();NSBezierPath(roundedRect:NSRect(x:537,y:70,width:526,height:96),xRadius:24,yRadius:24).fill()
  let colors:[NSColor]=[.systemPink,.systemOrange,.systemYellow,.systemGreen,.systemMint,.systemCyan,.systemPurple]
  for (i,color) in colors.enumerated(){color.blended(withFraction:0.45,of:.white)!.setFill();NSBezierPath(roundedRect:NSRect(x:551+i*72,y:86,width:64,height:64),xRadius:14,yRadius:14).fill()}
  image.unlockFocus();return image.cgImage(forProposedRect:nil,context:nil,hints:nil)!
 }
 func setImage(_ image:CGImage)throws {
  func upload(_ cg:CGImage) throws -> MTLTexture {
   let w=cg.width,h=cg.height
   var bytes=[UInt8](repeating:0,count:w*h*4)
   let valid=bytes.withUnsafeMutableBytes { raw -> Bool in
    guard let context=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)else{return false}
    context.draw(cg,in:CGRect(x:0,y:0,width:w,height:h));return true
   }
   guard valid else{throw NSError(domain:"Image conversion",code:1)}
   let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:w,height:h,mipmapped:false)
   descriptor.storageMode = .shared;descriptor.usage = .shaderRead
   guard let texture=device.makeTexture(descriptor:descriptor)else{throw NSError(domain:"Texture allocation",code:1)}
   texture.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:bytes,bytesPerRow:w*4)
   return texture
  }
  sharp=try upload(image)
  let source=CIImage(cgImage:image);let filtered=source.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:16]).cropped(to:source.extent)
  guard let soft=ci.createCGImage(filtered,from:source.extent) else{throw NSError(domain:"Cannot blur image",code:1)}
  let lightlyFiltered=source.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:4]).cropped(to:source.extent)
  guard let light=ci.createCGImage(lightlyFiltered,from:source.extent) else{throw NSError(domain:"Cannot blur image",code:1)}
  lightBlur=try upload(light)
  blurred=try upload(soft);params.sourceAspect=Float(image.width)/Float(image.height)
 }
 func encode(_ target:MTLTexture,_ depthTexture:MTLTexture,_ command:MTLCommandBuffer){
  let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);pass.depthAttachment.texture=depthTexture;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare;pass.depthAttachment.clearDepth=1
  guard let encoder=command.makeRenderCommandEncoder(descriptor:pass)else{return}
  var p=params;p.aspect=Float(target.width)/Float(target.height)
  encoder.setRenderPipelineState(pipeline);encoder.setDepthStencilState(depth);encoder.setFrontFacing(.counterClockwise);encoder.setCullMode(.none)
  encoder.setVertexBuffer(vertices,offset:0,index:0);encoder.setVertexBytes(&p,length:MemoryLayout<FoldParams>.stride,index:1);encoder.setFragmentBytes(&p,length:MemoryLayout<FoldParams>.stride,index:1);encoder.setFragmentTexture(sharp,index:0);encoder.setFragmentTexture(blurred,index:1);encoder.setFragmentTexture(lightBlur,index:2)
  if p.mode<0.5 || p.mode>5.5 {
   encoder.setRenderPipelineState(desktopPipeline)
   encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:count)
  } else {
   encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:count)
  }
  encoder.endEncoding()
 }
 func draw(in view:MTKView){guard inFlight.wait(timeout:.now()) == .success else{return};guard let drawable=view.currentDrawable,let dt=view.depthStencilTexture,let cmd=queue.makeCommandBuffer()else{inFlight.signal();return};cmd.addCompletedHandler{[inFlight]_ in inFlight.signal()};encode(drawable.texture,dt,cmd);cmd.present(drawable);cmd.commit()}
 func mtkView(_ view:MTKView,drawableSizeWillChange size:CGSize){}
 func pixels(width:Int,height:Int)->[UInt8]{
  let td=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false);td.usage=[.renderTarget];td.storageMode = .shared
  let target=device.makeTexture(descriptor:td)!
  let dd=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.depth32Float,width:width,height:height,mipmapped:false);dd.usage = .renderTarget;dd.storageMode = .private
  let dt=device.makeTexture(descriptor:dd)!,cmd=queue.makeCommandBuffer()!;encode(target,dt,cmd);cmd.commit();cmd.waitUntilCompleted()
  var bytes=[UInt8](repeating:0,count:width*height*4);target.getBytes(&bytes,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0);return bytes
 }
 static func amount(_ time: Double) -> Float {
  let t = time.truncatingRemainder(dividingBy: 4)
  let x: Double
  if t < 1.5 { x = t / 1.5 }
  else if t < 2 { x = 1 }
  else if t < 3.5 { x = 1 - (t - 2) / 1.5 }
  else { x = 0 }
  return Float(x * x * (3 - 2 * x))
 }
 @MainActor func export(to url:URL,progress:@escaping(Double)->Void,cancelled:@escaping()->Bool)async throws {
  let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
  let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:1920,AVVideoHeightKey:1080,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:12_000_000]])
  let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:1920,kCVPixelBufferHeightKey as String:1080,kCVPixelBufferMetalCompatibilityKey as String:true]);writer.add(input)
  guard writer.startWriting()else{throw writer.error!};writer.startSession(atSourceTime:.zero)
  let old=params.progress;defer{params.progress=old}
  do {for frame in 0..<120 {
   if cancelled(){throw CancellationError()}
   while !input.isReadyForMoreMediaData {if writer.status == .failed {throw writer.error!};try await Task.sleep(nanoseconds:2_000_000)}
   params.progress=Self.amount(Double(frame)/30)
   let bytes=pixels(width:1920,height:1080);var optional:CVPixelBuffer?
   guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&optional)==kCVReturnSuccess,let buffer=optional else{throw NSError(domain:"Video buffer",code:1)}
   CVPixelBufferLockBaseAddress(buffer,[]);let dest=CVPixelBufferGetBaseAddress(buffer)!,stride=CVPixelBufferGetBytesPerRow(buffer)
   bytes.withUnsafeBytes {src in for y in 0..<1080{memcpy(dest.advanced(by:y*stride),src.baseAddress!.advanced(by:y*1920*4),1920*4)}}
   CVPixelBufferUnlockBaseAddress(buffer,[])
   guard adaptor.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:30))else{throw writer.error ?? NSError(domain:"Append frame",code:1)}
   progress(Double(frame+1)/120);await Task.yield()
  }
  input.markAsFinished();await writer.finishWriting();if writer.status != .completed{throw writer.error ?? NSError(domain:"Export failed",code:1)}
  }catch{writer.cancelWriting();try? FileManager.default.removeItem(at:url);throw error}
 }
}
