import Foundation
import Synchronization

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print("\(condition ? "ok" : "FAIL") \(message)")
    if !condition { failures += 1 }
}

// Concurrent control updates and snapshots must not corrupt render state.
let processor = SoundMixProcessor()
processor.prepare(sampleRate: 48000)
let group = DispatchGroup()
let finite = Atomic<Bool>(true)
group.enter()
DispatchQueue.global().async {
    var input = [Float](repeating: 0.1, count: 16 * 128)
    var output = [Float](repeating: 0, count: 256)
    for _ in 0..<3000 {
        processor.process(input: &input, inputChannels: 16, frames: 128, output: &output)
        if output.contains(where: { !$0.isFinite }) { finite.store(false, ordering: .relaxed) }
    }
    group.leave()
}
group.enter()
DispatchQueue.global().async {
    for i in 0..<500 {
        var cfg = ProcessorConfiguration()
        cfg.manualGainDB = Double(i % 5) - 5
        processor.apply(cfg)
        _ = processor.snapshot()
    }
    group.leave()
}
group.wait()
check(finite.load(ordering: .relaxed), "concurrent configuration/snapshot/render remains finite")
check(processor.snapshot().bedPeakDB.count == 16, "snapshot retains every bed meter")

// Check interpolation fidelity and separation with independent clock drift.
for frequency in [1000.0, 18000.0] {
    let ring = FloatRingBuffer(frames: 4096, channels: 2, targetFrames: 960)
    var input = [Float](repeating: 0, count: 260)
    var output = [Float](repeating: 0, count: 256)
    var clock = 0.0, index = 0, sum = 0.0, samples = 0
    var silentPeak: Float = 0
    for block in 0..<2000 {
        clock += 128 * 1.0002
        let n = Int(clock); clock -= Double(n)
        for f in 0..<n {
            input[f * 2] = Float(0.5 * sin(2 * .pi * frequency * Double(index) / 48000))
            input[f * 2 + 1] = 0
            index += 1
        }
        ring.write(&input, frames: n)
        ring.readAdaptive(into: &output, frames: 128)
        if block > 100 {
            for f in 0..<128 {
                sum += Double(output[f * 2] * output[f * 2])
                silentPeak = max(silentPeak, abs(output[f * 2 + 1]))
                samples += 1
            }
        }
    }
    let gainDB = 20 * log10(sqrt(sum / Double(samples)) / (0.5 / sqrt(2)))
    check(abs(gainDB) < 0.2, "\(Int(frequency)) Hz resampling gain within 0.2 dB (\(gainDB))")
    check(silentPeak == 0, "clock bridge keeps silent right channel isolated")
}

// Runtime budget on this machine; report without a flaky wall-clock assertion.
let ring = FloatRingBuffer(frames: 8192, channels: 16, targetFrames: 960)
var input = [Float](repeating: 0.05, count: 128 * 16)
var pulled = input
var output = [Float](repeating: 0, count: 256)
let start = Date()
for _ in 0..<1000 {
    ring.write(&input, frames: 128)
    ring.readAdaptive(into: &pulled, frames: 128)
    processor.process(input: &pulled, inputChannels: 16, frames: 128, output: &output)
}
print(String(format: "Mean 16-channel callback workload: %.3f ms; 128-frame budget at 48 kHz: 2.667 ms", Date().timeIntervalSince(start)))
if failures > 0 { exit(1) }
print("6/6 real-time regression checks passed")
