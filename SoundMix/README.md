# SoundMix

A native macOS replacement for **Downmix Renderer 0.0.0**, rebuilt from the reverse-engineering
findings in [`../reverse-engineering/FINDINGS.md`](../reverse-engineering/FINDINGS.md).

Same job — fold an immersive bed down to a stereo pair in real time — with a correct,
configurable downmix matrix, exact headroom maths, and a true-peak limiter instead of a
blunt preamp.

```bash
./build.sh              # builds build/SoundMix.app and build/bedgen
./run-tests.sh          # 316 DSP checks (no audio hardware needed)
./run-offline-tests.sh  # 47 file-render and clock-drift checks
./run-realtime-tests.sh # 6 concurrency and resampling fidelity checks
./run-device-volume-tests.sh # 10 device-volume checks; real devices are read only
```

Swift 6 toolchain and the macOS SDK are the only requirements. No Xcode project, no package
manager, no network access.

---

## Versioning

`VERSION` is the release version (`major.minor.patch`), currently `1.2.0`.
Edit it when releasing a patch, feature, or breaking change. `./build.sh` stamps
that version into the app and increments the build counter in the tracked
`BUILD_NUMBER` file, so a clean clone continues the sequence. For a release or
CI build, choose an explicit number with `BUILD_NUMBER=42 ./build.sh`.

The sidebar and macOS About dialog read the version and build from the app bundle.
Restart the rebuilt app to see the updated values.

## macOS DMG installer

Run `./build-dmg.sh` to rebuild the app and package a compressed installer in
`dist/SoundMix-<version>-build-<number>.dmg`. Use `./build-dmg.sh --skip-build`
to package the existing app without incrementing its build number; the packager
verifies the app's stamped version and build match the `VERSION` and
`BUILD_NUMBER` files, so stale builds cannot ship under a new identity.
Existing DMGs are never overwritten. Set `BUILD_NUMBER=42 ./build-dmg.sh` for an
explicit build.

Open the DMG, drag **SoundMix.app** onto **Applications**, eject the image, and
launch SoundMix from Applications. Quit an older running copy before replacing it.
The image contains the app, an Applications shortcut, and installation instructions.
The packager verifies the app signature and disk-image checksum.

These local builds require macOS 14 or later and target the build machine's
architecture. They are ad-hoc signed; Developer ID signing and Apple notarization
for public distribution are not configured.

## What changed

| | Downmix Renderer 0.0.0 | SoundMix |
|---|---|---|
| **Processes** | 3 (PyInstaller/pywebview shell + C++ renderer + a second renderer as a "keep-alive") | 1 |
| **Internal API** | localhost HTTP + SSE; status and device lists scraped out of stdout with regexes | direct function calls |
| **Bundle size** | ~100 MB (CPython 3.11, WebKit, PortAudio, OpenSSL 1.1) | **1.2 MB** |
| **Audio I/O** | PortAudio | Core Audio AUHAL directly |
| **Device loss** | polling, name-matching heuristics, "quiet windows", a 0/3/7/12 s retry ladder | `kAudioDevicePropertyDeviceIsAlive` notifications |
| **Downmix matrix** | compiled in, every surround and height at unity | data-driven, four recipes, every coefficient visible |
| **Headroom** | manual −9.5 dB preamp default | computed L1/L2 trim, shown in dB before you press Start |
| **Overload protection** | `--clip-output` hard clip, not exposed in the UI | 4× oversampled true-peak limiter with look-ahead |
| **Sample rate** | 48 kHz only (hard refusal) | whatever the output device runs at |
| **Input channels** | hard minimum of 16 | whatever the chosen layout needs (4 for 2.1, 16 for 9.1.6) |
| **Output channels** | exactly 2, plus a hard-coded quirk list (`fosi`, `ds2`, `cs43131`) | any device with ≥ 2 outputs |
| **LFE filter** | fixed 125 Hz, 4th-order Butterworth | mode, cut-off and slope all adjustable |
| **Offline rendering** | none — live device only | internal testing only |
| **Headphone rendering** | none | binaural fold: 16 bed channels convolved with a synthesised head-related bank, 15 convolutions per block |
| **Earphone correction** | PEQ text only | pair a measured response with each EQ profile; plot measured, EQ and corrected together |
| **Tests** | none shipped | **316** automated checks, including real file renders |

## The matrix problem, and the fix

The original gives **every** left-side bed channel a coefficient of exactly `1.0`:

```
FL, BL, BLC, SL, TFL, TSL, TBL  → L   at 1.00000000
FC                              → L,R at 0.70710678
LFE                             → L,R at 2.26464431   (+7.100 dB)
```

Seven unity channels plus centre plus LFE is a worst-case gain of **9.9718 ×, or +19.98 dB**.
The app's only answer is a −9.5 dB preamp default, which does not come close — the test suite
demonstrates the overload directly:

```
ok   the original's −9.5 dB preamp alone still overloads   (peak +4.9 dBFS)
ok   full-scale 9.1.6 bed stays under the −1 dBTP ceiling
```

SoundMix keeps that matrix available as **Original parity (ADC2 direct)** so you can A/B
against the old app, and adds three alternatives:

- **Reference fold (−3 dB)** — the conventional fold: centre and every surround at −3.01 dB,
  heights folded onto the floor layer, LFE discarded.
- **Immersive fold (depth-weighted)** — wides −1.5, sides −3, rears −4.5, front heights −4.5,
  middle −6, rear heights −7.5 dB, with a small opposite-side bleed so the rear field does not
  collapse into one speaker.
- **Lt/Rt (matrix-encoded)** — the classic ±0.866 / ±0.5 encode, so a surround decoder
  downstream can unfold it.

For every one of them the Downmix panel shows the worst-case gain, the uncorrelated gain, the
automatic trim and the total applied gain, in dB, live.

## Carried over unchanged

- The canonical bed order `L,R,C,LFE,Ls,Rs,Lrs,Rrs,Lw,Rw,Ltf,Rtf,Ltm,Rtm,Ltr,Rtr`.
- Layout presets as 1-based input maps over those 16 slots.
- REW / Equalizer APO PEQ text, including the `l` / `r` channel-suffix convention.
- Global PEQ applied to both channels **before** the swap, speaker EQ applied **after** it,
  with the left/right file sections flipping when the swap is on.
- The dry-path delay that keeps the bass in phase with the filtered LFE — here it is derived
  from the filter's own DC group delay (159.7 samples / 3.33 ms for 125 Hz 4th-order at 48 kHz).

One deliberate correction: the original's **7.1.4** preset routes its four height channels to
`Ltf, Rtf, Ltm, Rtm` — front and middle. SoundMix routes them to `Ltf, Rtf, Ltr, Rtr`,
front and rear, which is what 7.1.4 means. It made no audible difference in the original only
because every height shared the same coefficient.

## Offline rendering

The **File** panel has been removed as of 2026-10-14. Offline file rendering is no longer supported through the main UI. The internal `OfflineRenderer` class remains in the codebase for automated testing purposes.

## Earphone correction

Each EQ profile can carry the measured response of the headphone it was written for —
an AutoEQ, oratory1990, squig.link or REW export, parsed from `frequency level` lines in
CSV, tab, semicolon or whitespace form. The Response plot then shows three curves on one
set of axes: the **measured** earphone, the **EQ** being applied, and the **result** you
will actually hear, plus how far that result still deviates across the band.

The measurement is stored inside the profile, so it saves, exports and imports with it.
Upload it from either the profile detail or the Response card.

## Graphical PEQ editing

In **Output EQ → Response**, click **Expand & edit PEQ** for a native full-screen
editor. Use the green window control to return to a resizable window.

- Choose **Global**, **Speaker L**, or **Speaker R**, and switch EQ profile from the
  picker beside it without leaving the editor. A draft with unapplied edits asks
  whether to apply or discard before the switch; the measured response and target
  follow it.
- Drag a numbered band for gain (vertically) and frequency (horizontally). Hold
  **Shift** to lock the drag to whichever axis it has travelled furthest along.
  A dragged frequency lands on a 1 Hz step below 1 kHz and a 10 Hz step above,
  clamped to 20 Hz … half Nyquist as the frequency field is. Bands keep their list
  order, so dragging one past another never renumbers either.
- Select a band to adjust Q, filter type, or enabled state. Each row in the band
  list carries its own mute and delete control, and the **Delete** key removes the
  selected band once the list has focus. Add bands and adjust the stage preamp
  with the controls beside the plot.
- **Audition live** (on by default) sends the draft to the running processor as you
  edit, so the plot and the sound agree while you tune. Nothing is written to the
  EQ text, the profile or the library until **Apply**. Edits ramp over a few
  hundred milliseconds instead of stepping, so a large drag does not click — the
  sound lags the plot slightly after a fast flick. Bypass still means bypass:
  nothing is auditioned while the EQ is switched out.
- The orange dashed reference shows the EQ when the editor opened, or at the last
  Apply. The horizontal dashed line marks 0 dB. The lower plot previews the combined
  result against the measured response and target, when loaded.
- **Reset** discards unapplied edits across all three stages.
- **Apply** updates the current EQ and running audio while keeping the editor open.
  **Apply & close** also closes it. **Cancel**, or closing the window by any other
  means, discards edits since the last Apply and returns the audio to the EQ that
  was running before the editor opened.

**Apply** also saves the profile: what you hear and what the library holds are
one step. When no profile is selected, one is created from the name in the
**Profile name** field. Every control named Apply — the editor's, the Output EQ
cards' **Apply & save**, the transport bar's, and ⌘S — persists the profile the
same way.
Bypass is preserved. Speaker editing follows physical L/R routing, including swapped
outputs. Edits preserve other channels, disabled filters, preamps and numeric
precision. Edited documents are rewritten in supported APO syntax; their comments
and formatting are not retained. Resolve parser warnings in the text editor first.
If the EQ changes in the main window while the editor is open, editing is suspended
until you reload the draft from it — the editor offers that in place of the warning.

## Binaural / HRTF fold

The **Fold** card chooses how the bed becomes two channels: the amplitude matrix, which is
right for speakers, or a head-related filter bank, which is right for headphones. In
binaural mode every bed channel is convolved with the response of a head listening to a
loudspeaker at that channel's own angle, so the channels arrive from their own directions
instead of being panned between two points.

No measured dataset ships with the application — nothing to license, nothing to download,
and nothing that only works at one sample rate. The bank is synthesised for the running
device rate from Woodworth inter-aural delay and the Brown-Duda spherical head shadow, with
a pinna notch that climbs with elevation and a high-frequency roll-off on rear channels to
separate front from back. A dataset-free crossfeed bank is there as the conservative option,
and a measured SOFA set could be loaded into the same engine later without touching the
renderer.

Three things make it cheap and honest:

- **Half the convolutions.** The bank is an exact mirror pair by pair, so each pair folds
  through the sum and difference of its two channels rather than four separate filters:
  fifteen convolutions per block instead of twenty-nine, through `vDSP_convD`, with every
  buffer allocated on the control thread.
- **The same level discipline.** The headroom figures are the matrix's own L1 and L2 norms
  taken over whole impulse responses — the sum of absolute taps bounds the peak, the root of
  the summed tap energy gives the level for uncorrelated material — so peak-safe and
  power-preserving mean exactly what they do in matrix mode. A signal built specifically to
  reach the peak bound lands at full scale and not a sample above it.
- **Bass stays where the ear can use it.** Below the crossover the fold collapses to the
  centre through a Linkwitz-Riley split, because direction is not carried down there and
  per-ear filtering of the bottom octaves only combs. The two halves sum back flat to within
  0.35 dB, and the LFE never enters the bank at all.

It renders about 30× faster than real time at 48 kHz with all sixteen channels fed, 15× at
96 kHz and 7× at 192 kHz — the bank lengthens with the rate, so the cost grows faster than
linearly — and adds a third of a millisecond of bulk delay, which is reported in the Monitor
panel and included in the latency accounting.

## Layout

```
Sources/
  SoundMixCore/      pure DSP — no Core Audio, no AppKit, fully testable
    BedLayout.swift         channels, groups, layout presets
    Biquad.swift            biquads, RBJ designers, Butterworth cascades, group delay
    APOParser.swift         REW / Equalizer APO text → filters
    SoundMixMatrix.swift     matrix, recipes, headroom analysis
    BinauralProfile.swift   binaural profiles, LFE settings shared by both folds
    HRIRBank.swift          speaker geometry and the synthesised filter bank
    BinauralFold.swift      the render-side convolution engine
    TruePeakLimiter.swift   4× oversampled look-ahead limiter
    Metering.swift          meters and the UI snapshot
    SoundMixProcessor.swift  the real-time chain
  SoundMixCore/
    FrequencyResponse.swift measured curves, parsing, interpolation
    EQProfileLibrary.swift  the profile library and its portable format
  SoundMixEngine/    Core Audio
    AudioDevice.swift       HAL enumeration + change notifications
    RingBuffer.swift        lock-free SPSC bridge between the two device clocks
    SoundMixEngine.swift    two AUHAL units, bring-up, device-loss handling
    OfflineRenderer.swift   file in, stereo file out, same chain
  SoundMixApp/       SwiftUI, SoundMix design system
Tests/main.swift    316 checks
```

## Interface

Built on the SoundMix design system: dark-blue (`#0e1e4d`) sidebar, pale-blue (`#eef2fb`)
content area, blue (`#2fa8f7`) primary actions, Landour for body and headings, Wix Madefor for
navigation and buttons. Every component is custom-built on SwiftUI primitives — no third-party
UI library — and every colour comes from a named token in `Sources/SoundMixApp/Theme.swift`.

## Known limits

- Binaural mode is synthesised, not measured: there is no SOFA import, no room simulation or
  early reflections, and no head tracking. A generic head colours timbre, and front/back
  confusion is a property of generic HRTFs rather than a defect here.
- Input and output must run at the same sample rate. SoundMix asks Core Audio to match
  the input to the output and reports clearly when the device refuses, instead of performing arbitrary sample-rate conversion. A continuously adjusted
  windowed-sinc bridge compensates for small differences between independent device clocks.
- Ad-hoc signed. Gatekeeper will ask on first launch unless you sign it with your own identity.
- **Microphone permission is mandatory.** macOS classes every Core Audio input as a microphone,
  including a virtual loopback like BlackHole, so the first Start shows the system prompt. If it
  is refused the Devices panel says so and offers a button straight to the right Settings pane.
  Approving it cannot be scripted, so the capture path has not been run end to end here.

## Verified so far

- **316/316 DSP checks pass** (`./run-tests.sh`), covering matrix parity with the shipped
  binary, headroom maths, Butterworth design and group delay, REW/APO parsing, the EQ
  profile library and its import/export, earphone-measurement parsing, limiter ceilings,
  and end-to-end routing, swap and muting through the processor.
- **The live audio path is measured, not assumed** — see
  [VERIFICATION.md](VERIFICATION.md). Routing accurate to ±0.9 dB across all 16 slots,
  0 ring-buffer underruns over 53.6 s across two independent device clocks, and the
  true-peak limiter holding a −1.0 dBTP ceiling at −1.0 dBFS with 16 dB of reduction and
  no clipping.
- Core Audio enumeration, sample-rate matching at both 48 and 96 kHz, and hot
  reconfiguration while streaming all work.

## Reliability fixes (2026-10-14)

- File exports reject the source itself, symbolic links, and hard links. Completed
  renders replace the destination atomically; failed or cancelled renders preserve it. (Note: File exports are now restricted to automated testing).
- Read and write failures propagate. Tail frames are written in bounded blocks and
  included in peak, clipping, and limiter statistics.
- Limiter interpolation uses separate left/right histories, linked gain, and a
  look-ahead hold before release. All three fractional phases, including the
  half-sample phase, are tested.
- EQ profile writes are atomic and errors reach the UI without marking drafts saved.
- DSP configurations are prepared on the control thread. Audio callbacks use
  nonblocking handoffs and snapshot publication; filter history survives live edits.
- The clock bridge prefills the safety buffer and adjusts consumption to occupancy.
  Simulated ±200 ppm drift runs for five minutes per direction without dropped blocks.
- The footer identifies the shared stereo limiter as Ready, reducing, Off, or Stopped.
  Headroom shows the matrix/manual/EQ preamp breakdown, with live 1 dB gain steps.

The new checks run without audio hardware. The updated build still needs listening
validation on the intended input/output devices; previous live measurements below
or in VERIFICATION.md do not validate this new clock bridge.

## Device volume

Devices exposes separate macOS input/output volume sliders for the selected devices.
They work while playback is stopped or running and affect other applications using
that device. Values refresh while the page is open, including external changes.
A writable master control is preferred; otherwise writable channel controls are
linked while preserving their relative balance. Unsupported/read-only controls
are disabled with an explanation. No device volume is changed on startup.

Hardware setters are covered by mocked tests; actual connected-device capability
and volume reads were verified without changing the user's volume.

## Device settings the engine changes and restores

Starting a session can move the input device's sample rate to match the output
and set both devices' buffer frame sizes, because the two AUHAL units need one
shared rate. These are system-global settings other apps hear too, so stopping
the session (or the engine failing, or a device vanishing) puts each one back
the way it was found. Refusals are logged, never fatal. No device volume is
ever changed by the engine.

## Robustness

A capture device delivering NaN or infinities is muted at ingestion, so no
non-finite sample can reach the EQ chain, the limiter or the meters; the limiter
additionally mutes any non-finite frame and the RMS meter cannot latch NaN.
Capture diagnostics are read atomically across threads. The control-side
reconfiguration APIs (`applyNow`, `prepare`, `reset`) swap whole render states
under a lock rather than mutating live state, so an ill-timed call cannot race
the audio thread.

## Offline target previews

In the enlarged PEQ editor, the **Target** menu below **Draft result** offers the
profile target, no target, and the reference targets generated from the drop
folder of curve files (JM-1 -10dB Tilt, PEQdB Diamond β, HiFiEndgame MKIII,
Harman IE 2019, and the rest listed in `Resources/Targets/manifest.json`),
plus IEF / Crinacle Neutral and IEF Neutral with bass from AutoEq. Selection
affects this preview only; it does not change filters, audio, or the saved
profile target. The result plot always shows the normalized response; there is
no error-versus-target view.

Target CSVs ship in `Resources/Targets` and are copied into the app and DMG, so no
connection is required. `Tools/sync_targets.py` runs on every build and
regenerates the list from the drop folder: add or remove a curve file there and
rebuild, and the target menus follow. Provenance is recorded in
`Resources/Targets/sources.json`.
Use measurements and targets from compatible measurement systems; these reference
curves do not convert between rigs.

The editor's Bands panel now uses a wider card, larger rows, separate frequency
and gain readouts, generous mute/delete buttons, and a taller scrollable list.
