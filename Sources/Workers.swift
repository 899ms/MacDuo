import Cocoa
import IOKit.hid
import Darwin

final class LidSensor {
 let manager:IOHIDManager
 var device:IOHIDDevice?
 init(){manager=IOHIDManagerCreate(kCFAllocatorDefault,0);IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x05ac,kIOHIDPrimaryUsagePageKey:0x20,kIOHIDPrimaryUsageKey:0x8a] as CFDictionary);IOHIDManagerOpen(manager,0)
  if let devices=IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>{for d in devices {if IOHIDDeviceOpen(d,0)==kIOReturnSuccess{device=d;if angle() != nil{break};IOHIDDeviceClose(d,0);device=nil}}}
 }
 func angle()->Double?{guard let d=device else{return nil};var data=[UInt8](repeating:0,count:8);var count=data.count;let result=IOHIDDeviceGetReport(d,kIOHIDReportTypeFeature,1,&data,&count);guard result==kIOReturnSuccess,count>=3 else{return nil};let value=Double(Int(data[1])|(Int(data[2])<<8));return (0...360).contains(value) ? value:nil}
 deinit{if let d=device{IOHIDDeviceClose(d,0)};IOHIDManagerClose(manager,0)}
}

func runWatchdog(parent:pid_t) -> Never {
 _ = fcntl(STDIN_FILENO,F_SETFL,O_NONBLOCK)
 var last=ProcessInfo.processInfo.systemUptime
 var bytes=[UInt8](repeating:0,count:128)
 while getppid()==parent {
  let n=read(STDIN_FILENO,&bytes,bytes.count)
  let now=ProcessInfo.processInfo.systemUptime
  if n==0{exit(0)}
  // Heartbeat loss means the app is unresponsive. Elapsed session time is irrelevant.
  if n>0 { last=now }
  if now-last>4 {
   if getppid()==parent{kill(parent,SIGTERM);usleep(300_000);if getppid()==parent{kill(parent,SIGKILL)}}
   exit(0)
  }
  usleep(100_000)
 }
 exit(0)
}
func runSensor() -> Never {
 signal(SIGPIPE,SIG_DFL)
 let reader=LidSensor()
 while true {
  let line=reader.angle().map{String($0)} ?? "unavailable"
  FileHandle.standardOutput.write(Data((line+"\n").utf8))
  usleep(50_000)
 }
}
func startWatchdog()->(Process,Pipe){
 let process=Process(),pipe=Pipe()
 process.executableURL=Bundle.main.executableURL
 process.arguments=["--watch-parent",String(getpid())]
 process.standardInput=pipe;process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
 try! process.run()
 return(process,pipe)
}
