import Foundation
import CoreAudio
import AudioToolbox

// Writes a known multichannel signal to a loopback device so the renderer has
// something identifiable to fold. Output only — macOS asks for no permission.

struct Options {
    var deviceMatch = "BlackHole"
    var pattern = "ladder"
    var channel = 1
    var level = 0.5
    var seconds = 8.0
    var channels = 16
}

var o = Options()
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    func next() -> String? { i + 1 < args.count ? args[i + 1] : nil }
    switch a {
    case "--device":   if let v = next() { o.deviceMatch = v; i += 1 }
    case "--pattern":  if let v = next() { o.pattern = v; i += 1 }
    case "--channel":  if let v = next(), let n = Int(v) { o.channel = n; i += 1 }
    case "--level":    if let v = next(), let n = Double(v) { o.level = n; i += 1 }
    case "--seconds":  if let v = next(), let n = Double(v) { o.seconds = n; i += 1 }
    case "--channels": if let v = next(), let n = Int(v) { o.channels = n; i += 1 }
    case "--help":
        print("""
        bedgen — multichannel test signal generator

          --device <substring>   output device to open (default BlackHole)
          --pattern <name>       ladder | ident | full | silence   (default ladder)
          --channel <n>          1-based channel for `ident` (default 1)
          --level <0..1>         amplitude for `ident` / `full` (default 0.5)
          --channels <n>         channels to open (default 16)
          --seconds <s>          run time (default 8)

        patterns
          ladder   channel i gets a distinct tone at -2·i dBFS, so each bed slot
                   is identifiable by level alone (ch1 -2 dBFS … ch16 -32 dBFS)
          ident    only --channel carries signal, at --level
          full     every channel at --level, for headroom and limiter testing
        """)
        exit(0)
    default: break
    }
    i += 1
}

func findDevice(_ match: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
    else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
    else { return nil }
    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: CFString? = nil
        var s = UInt32(MemoryLayout<CFString?>.size)
        guard withUnsafeMutablePointer(to: &cf, {
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &s, $0)
        }) == noErr, let name = cf as String? else { continue }
        if name.localizedCaseInsensitiveContains(match) {
            var cfgAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var cs: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &cfgAddr, 0, nil, &cs) == noErr, cs > 0 else { continue }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(cs), alignment: 16)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfgAddr, 0, nil, &cs, raw) == noErr else { continue }
            let total = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                .reduce(0) { $0 + Int($1.mNumberChannels) }
            if total >= o.channels {
                print("device: \(name)  (\(total) output channels)")
                return id
            }
        }
    }
    return nil
}

guard let device = findDevice(o.deviceMatch) else {
    print("No output device matching “\(o.deviceMatch)” with at least \(o.channels) channels.")
    exit(1)
}

var rateAddr = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyNominalSampleRate,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
var rate: Float64 = 48_000
var rsize = UInt32(MemoryLayout<Float64>.size)
AudioObjectGetPropertyData(device, &rateAddr, 0, nil, &rsize, &rate)

// Per-channel amplitude and frequency.
final class Generator: @unchecked Sendable {
    var phase: [Double]
    let freq: [Double]
    let amp: [Double]
    let rate: Double
    let channels: Int

    init(options: Options, rate: Double) {
        self.rate = rate
        self.channels = options.channels
        var f = [Double](), a = [Double]()
        for c in 0..<options.channels {
            f.append(110.0 * Double(c + 2))
            switch options.pattern {
            case "ident":   a.append(c == options.channel - 1 ? options.level : 0)
            case "full":    a.append(options.level)
            case "silence": a.append(0)
            default:        a.append(pow(10, -2.0 * Double(c + 1) / 20.0))   // ladder
            }
        }
        self.freq = f
        self.amp = a
        self.phase = [Double](repeating: 0, count: options.channels)
    }

    func render(_ out: UnsafeMutablePointer<Float>, frames: Int, deviceChannels: Int) {
        for f in 0..<frames {
            for c in 0..<deviceChannels {
                var v = 0.0
                if c < channels {
                    v = amp[c] * sin(phase[c])
                    phase[c] += 2 * Double.pi * freq[c] / rate
                    if phase[c] > 2 * Double.pi { phase[c] -= 2 * Double.pi }
                }
                out[f * deviceChannels + c] = Float(v)
            }
        }
    }
}

let gen = Generator(options: o, rate: rate)
var deviceChannels = o.channels

var desc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
guard let comp = AudioComponentFindNext(nil, &desc) else { print("no HAL component"); exit(1) }
var unit: AudioUnit?
AudioComponentInstanceNew(comp, &unit)
guard let unit else { print("could not create unit"); exit(1) }

var enable: UInt32 = 1
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                     &enable, UInt32(MemoryLayout<UInt32>.size))
var dev = device
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                     &dev, UInt32(MemoryLayout<AudioDeviceID>.size))

let bytesPerFrame = UInt32(deviceChannels * MemoryLayout<Float>.size)
var format = AudioStreamBasicDescription(
    mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
    mChannelsPerFrame: UInt32(deviceChannels), mBitsPerChannel: 32, mReserved: 0)
let fstatus = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                   &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
if fstatus != noErr { print("stream format rejected: \(fstatus)"); exit(1) }

final class Ctx {
    let gen: Generator
    let channels: Int
    var callbacks = 0
    var framesWritten = 0
    var peak: Float = 0
    init(_ g: Generator, _ c: Int) { gen = g; channels = c }
}
let ctx = Ctx(gen, deviceChannels)

var cb = AURenderCallbackStruct(
    inputProc: { refCon, _, _, _, frames, ioData -> OSStatus in
        let c = Unmanaged<Ctx>.fromOpaque(refCon).takeUnretainedValue()
        guard let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let raw = buffers[0].mData else { return noErr }
        let out = raw.assumingMemoryBound(to: Float.self)
        let ch = Int(buffers[0].mNumberChannels)
        c.gen.render(out, frames: Int(frames), deviceChannels: ch)
        c.callbacks += 1
        c.framesWritten += Int(frames)
        for i in 0..<(Int(frames) * ch) { c.peak = max(c.peak, abs(out[i])) }
        return noErr
    },
    inputProcRefCon: Unmanaged.passUnretained(ctx).toOpaque())
AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                     &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

guard AudioUnitInitialize(unit) == noErr else { print("AudioUnitInitialize failed"); exit(1) }
guard AudioOutputUnitStart(unit) == noErr else { print("AudioOutputUnitStart failed"); exit(1) }

print("pattern: \(o.pattern)  rate: \(Int(rate)) Hz  channels: \(deviceChannels)")
if o.pattern == "ladder" {
    print("expected per-channel levels (dBFS):")
    for c in 0..<min(deviceChannels, 16) {
        print(String(format: "  ch%-2d  %6.1f dBFS  @ %.0f Hz", c + 1, -2.0 * Double(c + 1), 110.0 * Double(c + 2)))
    }
}
print("running for \(o.seconds) s …")
RunLoop.current.run(until: Date().addingTimeInterval(o.seconds))
AudioOutputUnitStop(unit)
AudioUnitUninitialize(unit)
AudioComponentInstanceDispose(unit)

print("""

  render callbacks : \(ctx.callbacks)
  frames written   : \(ctx.framesWritten)  (\(String(format: "%.2f", Double(ctx.framesWritten) / rate)) s)
  peak sample      : \(String(format: "%.4f", ctx.peak))
""")
if ctx.callbacks == 0 || ctx.peak == 0 {
    print("  FAILED: the device never pulled audio — nothing was written.")
    exit(3)
}
print("  OK: signal was delivered to the device.")
