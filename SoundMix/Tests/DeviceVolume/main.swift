import Foundation
import CoreAudio

var checks = 0, failures = 0
func check(_ ok: Bool, _ message: String) {
    checks += 1
    print("\(ok ? "ok" : "FAIL") \(message)")
    if !ok { failures += 1 }
}
final class FakeDevice {
    var values: [UInt32: Float] = [:]
    var writable: Set<UInt32> = []
    var failure: UInt32?
    var scopes: [AudioObjectPropertyScope] = []
    var writes = 0
    var backend: DeviceVolume.Backend {
        .init(read: { _, _, channel in self.values[channel] },
              writable: { _, _, channel in self.writable.contains(channel) },
              write: { _, scope, channel, value in
                  self.scopes.append(scope); self.writes += 1
                  if channel == self.failure { return -50 }
                  self.values[channel] = value
                  return noErr
              })
    }
}
let f = FakeDevice()
var state = DeviceVolume.read(device: 1, isInput: true, channels: 2, backend: f.backend)
check(state.value == nil && !state.writable, "unsupported controls are disabled")
f.values = [0: 0.6]
state = DeviceVolume.read(device: 1, isInput: true, channels: 2, backend: f.backend)
check(state.value != nil && !state.writable, "read-only master remains visible and disabled")
f.writable = [0]
try DeviceVolume.set(0.3, device: 1, isInput: true, channels: 2, backend: f.backend)
check(f.values[0] == Float(0.3) && f.scopes.last == kAudioObjectPropertyScopeInput, "input slider targets input scope")
try DeviceVolume.set(0.7, device: 1, isInput: false, channels: 2, backend: f.backend)
check(f.values[0] == Float(0.7) && f.scopes.last == kAudioObjectPropertyScopeOutput, "output slider targets output scope")
f.values = [0: 0.4, 1: 0.8, 2: 0.2]; f.writable = [0, 1, 2]
try DeviceVolume.set(0.9, device: 1, isInput: false, channels: 2, backend: f.backend)
check(f.values[0] == Float(0.9) && f.values[1] == Float(0.8), "master preferred over channel controls")
f.values = [1: 0.8, 2: 0.4]; f.writable = [1, 2]
try DeviceVolume.set(0.5, device: 1, isInput: false, channels: 2, backend: f.backend)
check(f.values[1] == 0.5 && f.values[2] == 0.25, "channel fallback preserves balance")
f.values = [1: 0.8, 2: 0.4]; f.failure = 2
 do {
    try DeviceVolume.set(0.5, device: 1, isInput: false, channels: 2, backend: f.backend)
    check(false, "HAL write failures propagate")
} catch { check(true, "HAL write failures propagate") }
check(f.values[1] == Float(0.8) && f.values[2] == Float(0.4), "partial write restores changed channels")
f.failure = nil
try DeviceVolume.set(2, device: 1, isInput: false, channels: 2, backend: f.backend)
check(f.values[1] == 1 && f.values[2] == 0.5, "volume clamped to device scalar range")
let before = f.writes
 do {
    try DeviceVolume.set(.nan, device: 1, isInput: false, channels: 2, backend: f.backend)
    check(false, "nonfinite volume rejected")
} catch { check(f.writes == before, "nonfinite volume rejected without HAL write") }

// Read-only inspection: never adjust the user's actual volume during tests.
for device in AudioDeviceDirectory.enumerate() {
    if device.hasInput {
        let v = DeviceVolume.read(device: device.id, isInput: true, channels: device.inputChannels)
        print("Device input: \(device.name), writable=\(v.writable), volume=\(v.value.map { String(format: "%.0f%%", $0 * 100) } ?? "unsupported")")
    }
    if device.hasOutput {
        let v = DeviceVolume.read(device: device.id, isInput: false, channels: device.outputChannels)
        print("Device output: \(device.name), writable=\(v.writable), volume=\(v.value.map { String(format: "%.0f%%", $0 * 100) } ?? "unsupported")")
    }
}
print("\(checks - failures)/\(checks) device-volume checks passed")
if failures > 0 { exit(1) }
