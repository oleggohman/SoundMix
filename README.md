# SoundMix

SoundMix is a native macOS app that mixes multichannel audio—up to a 9.1.6
layout—into stereo for speakers or headphones. It combines configurable downmixing,
headroom control, a true-peak limiter, and a parametric equalizer (PEQ) with
headphone measurements and reference target curves.

SoundMix processes **already-decoded PCM audio**. It does not decode Dolby Atmos
or other proprietary bitstreams. Your player must send multichannel PCM through
a virtual audio device such as BlackHole:

```text
Player → BlackHole → SoundMix → Headphones or speakers
         multichannel PCM      stereo output
```

It is a native, single-process rebuild of
[peqdb/macos (Downmix Renderer)](https://github.com/peqdb/macos), with a graphical
interface, device volume controls, and an interactive EQ editor.

## Requirements

- **macOS 14 or later.** Local builds target the build machine's architecture;
  they are not universal binaries.
- **A virtual loopback device**, such as
  [BlackHole 16ch](https://existential.audio/blackhole/), to route audio from your
  player into SoundMix.
- **An output device with at least two channels**, such as headphones, a DAC,
  or an audio interface.
- **Microphone permission.** macOS requires this for audio input, including
  virtual devices. SoundMix requests permission when you first press **Start**.

Input and output must use the same sample rate. SoundMix asks the input device
to match the output and reports an error if the device refuses.

## Get started

### Install or build

Download a DMG from [GitHub Releases](https://github.com/oleggohman/SoundAPP/releases),
open it, and drag **SoundMix.app** to **Applications**. Quit any running copy
before replacing it. Local packages are ad-hoc signed, not Apple-notarized.

To build from source, you need a Swift 6 toolchain, the macOS SDK, and Python 3
for preparing the bundled target curves. From the repository root:

```bash
cd SoundMix
./build.sh
open build/SoundMix.app
```

The build uses the installed toolchain and macOS utilities; it does not download
dependencies or require an Xcode project. Each build updates the tracked
`SoundMix/BUILD_NUMBER` file.

### Set up audio

1. Install BlackHole 16ch and configure its channel layout in **Audio MIDI Setup**
   to match your source. For a 9.1.6 bed, use channels 1–16 in the order shown below.
2. Route your player's decoded audio to BlackHole.
3. In SoundMix's **Devices** panel, choose BlackHole as the input, your headphones
   or speakers as the output, and the layout that matches the source.
4. In **Downmix**, choose a matrix recipe for speakers or a binaural fold for
   headphones. Review the headroom and limiter settings.
5. Press **Start** and allow microphone access when prompted. Use **Monitor** to
   check activity and **Log** to investigate errors.

The canonical 16-channel input order is:

```text
L, R, C, LFE, Ls, Rs, Lrs, Rrs, Lw, Rw, Ltf, Rtf, Ltm, Rtm, Ltr, Rtr
```

These are front left/right, centre, LFE, side left/right, rear left/right, wide
left/right, then top front, top middle, and top rear left/right pairs. Selecting
a layout does not turn a stereo source into multichannel audio.

## Features

### Downmix and playback

- **Four matrix recipes:** Original parity for comparison with Downmix Renderer,
  Reference fold for a conventional −3 dB fold, Immersive fold with depth-weighted
  surround levels, and Lt/Rt for a downstream surround decoder.
- **Headroom controls:** inspect worst-case gain, uncorrelated gain, automatic
  trim, and total applied gain before starting playback.
- **True-peak limiter:** 4× oversampling and look-ahead help control output peaks.
- **Binaural headphone rendering:** a synthesized head-related filter bank gives
  bed channels directional cues. It requires no downloaded HRTF dataset and does
  not include head tracking or measured SOFA imports.
- **Core Audio device controls:** device-loss notifications and separate input
  and output volume sliders where supported. These sliders change the device's
  system volume, including for other applications.

### EQ Studio

- **Interactive PEQ editor:** edit Global, Speaker L, and Speaker R EQ by dragging
  bands or entering values. Audition changes during playback; **Apply** saves them
  to the profile. Import and export REW / Equalizer APO PEQ text.
- **PEQdB measurement picker:** search headphone and earphone measurements by
  brand, model, and variant. Matching L/R measurements can populate both ears.
  Accessing the online database requires a network connection.
- **AutoTune:** generate peaking filters to bring a measurement closer to a chosen
  target, then refine the resulting bands manually.
- **Bundled targets:** preview reference curves such as Harman IE 2019, IEF
  Preference, PEQdB Diamond, and Moondrop VDSF without a network connection.
- **Response comparison:** import measurements from AutoEQ, oratory1990,
  squig.link, or REW and view measured, EQ, and predicted corrected curves together.
- **Portable profiles:** save, export, and import EQ settings with their
  measurements and targets.

Use measurements and targets from compatible measurement systems. A target curve
does not convert a measurement between rigs.

## Screenshots

| Devices | Downmix |
|---|---|
| ![Devices panel](Screenshots/Devices.png) | ![Downmix panel](Screenshots/Downmix.png) |

| Output EQ | PEQ editor |
|---|---|
| ![Output EQ](Screenshots/OutputEQ.png) | ![PEQ editor](Screenshots/PEQ_Editor.png) |

![Monitor panel](Screenshots/Monitor.png)

## Development and packaging

Run these commands from `SoundMix/`:

```bash
./run-tests.sh                # DSP checks
./run-offline-tests.sh        # File-render and clock-drift checks
./run-realtime-tests.sh       # Concurrency and resampling checks
./run-device-volume-tests.sh  # Mocked volume writes; real-device reads only
```

The automated checks do not replace listening tests on your intended devices.
Offline file rendering is used for testing; it is not available in the app UI.

To build and package a local installer:

```bash
./build-dmg.sh
```

The installer is written to
`SoundMix/dist/SoundMix-<version>-build-<number>.dmg` (relative to the repository
root). To package an app you have already built, use `./build-dmg.sh --skip-build`.
The script checks its version and build number and refuses to overwrite an
existing DMG.

Packaging is local by default. Setting `UPLOAD_RELEASE=1` also invokes `gh release
create` to publish the DMG; it requires an authenticated GitHub CLI. The script
does not create a local annotated Git tag. Ensure the release tag identifies the
source commit used for the app before publishing.

## Project layout and further reading

| Path | Contents |
|---|---|
| [`SoundMix/README.md`](SoundMix/README.md) | Detailed EQ usage, DSP architecture, versioning, and comparison with Downmix Renderer. |
| [`SoundMix/Sources/`](SoundMix/Sources/) | DSP core, Core Audio engine, and SwiftUI interface. |
| [`SoundMix/Resources/SoundMix.help/`](SoundMix/Resources/SoundMix.help/) | Bundled user guide. |
| [`Targets/`](Targets/) | Source target curves, synchronized into the app resources during builds. |
| [`SoundMix/VERIFICATION.md`](SoundMix/VERIFICATION.md) | Recorded live-audio measurements and their test conditions. |
| [`SECURITY.md`](SECURITY.md) | Security policy and reporting guidance. |

## Thanks

- [peqdb/macos](https://github.com/peqdb/macos) — the original Downmix Renderer.
- [PEQdB](https://peqdb.com) — the headphone and earphone measurement database.

## License

[ISC](LICENSE)
