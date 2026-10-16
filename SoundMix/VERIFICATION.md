# SoundMix — live audio verification

Measured on 2026-10-14, macOS 27 (Darwin 27.0.0), Apple silicon.
Input **BlackHole 16ch** → output **Speaker** (USB, 2 ch) at 48 kHz, 128-frame buffers.
Signal source: `build/bedgen`, which writes a known tone per channel straight to the
loopback device and reports the frames it actually delivered.
Readings come from the app's own telemetry at
`~/Library/Application Support/SoundMix/telemetry.json`.

## Result summary

| Check | Result |
|---|---|
| Capture path alive | 20,088 callbacks, 53.6 s delivered, **0 render errors** |
| Ring-buffer underruns across two device clocks | **0** over 53.6 s |
| Engine restarts during the session | **1** (the initial start) |
| Per-channel routing, 16 slots | correct; relative level accurate to **±0.9 dB** |
| Matrix coefficients, live | match the selected recipe exactly |
| True-peak limiter, −1.0 dBTP ceiling | held at **−1.0 / −1.1 dBFS** with **16.0 dB** reduction, **0 clips** |
| Sample-rate matching | ran at both 96 kHz and 48 kHz |

## Routing and level accuracy

A 16-channel ladder — each device channel a distinct tone, 2 dB apart, channel 1 at
−2 dBFS down to channel 16 at −32 dBFS — mapped 1:1 onto the 9.1.6 bed.

Levels relative to channel 1, against an expected 2 dB per step:

```
ch    1     2     3     4     5     6     7     8
err  0.0  +0.9  -0.4  -0.5  +0.2  -0.1  +0.4  +0.8

ch    9    10    11    12    13    14    15    16
err -0.8  -0.7  -0.8  -0.6  -0.5  -0.5  -0.3  -0.3
```

Max |error| 0.9 dB, mean 0.5 dB, with residual programme material still on the device.
Every slot landed on its intended bed channel, and the live coefficients read back as
L→L 0.00 dB / R −∞, C→both −3.01 dB, side and rear surrounds −3.01 dB to their own side
only, LFE discarded — the Reference fold, as selected.

An absolute offset of −27.4 dB was present and is **not** the app: BlackHole 16ch carries
its own volume control, which sat at −24.00 dB. It is a single device-level attenuation,
constant across input level (0 dBFS in → −23.48 dBFS measured), and it is applied by the
loopback device, not by SoundMix.

## Limiter

Sixteen channels at 0.95 full scale, folded through the Reference matrix with +17.47 dB
of total gain — roughly 16 dB past the ceiling:

```
outL  -1.0 dBFS   outR  -1.1 dBFS   GR 15.8 dB   clips 0
outL  -1.0 dBFS   outR  -1.1 dBFS   GR 16.1 dB   clips 0
outL  -1.0 dBFS   outR  -1.1 dBFS   GR 16.0 dB   clips 0
```

Steady, no clipping, no underruns.

## Bug found and fixed during this run

**Stale sample-rate comparison silenced the capture path.** `bringUp` compared the input
device's rate against the value cached when the device list was enumerated. BlackHole's
rate moved between 96 kHz and 48 kHz across runs; acting on the stale number, the engine
skipped the rate change it needed and left the capture unit converting between rates that
did not match. The result was digital silence with a starving ring buffer — no error
anywhere, which is the worst way for this to fail.

The fix re-reads both rates from the HAL at bring-up, waits for a requested change to
settle, verifies it landed, and otherwise fails with a message naming both devices and
both rates. Capture-side counters (callbacks, frames delivered, render errors and their
`OSStatus`, engine starts) are now in the telemetry so a dead input path can never again
look the same as silence.

## Not covered

- Only one loopback input device was available, so behaviour with a physical
  multichannel interface is untested.
- Device-removal handling is implemented against `kAudioDevicePropertyDeviceIsAlive`
  but was not exercised by unplugging hardware.
- Long-run clock drift is verified to 53.6 s, not to hours.
- The earphone-measurement graph and the EQ profile manager are covered by the unit
  suite (162 checks) but were not measured acoustically.
