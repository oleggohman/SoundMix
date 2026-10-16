# SoundMix Help & Documentation

SoundMix is a multichannel audio router, downmixer, and parametric equalizer for macOS. It takes a multichannel audio feed—such as a 7.1.4 Dolby Atmos bed or a 5.1 surround mix from a virtual loopback device—and folds it down to a standard 2.0 stereo output for your headphones or speakers.

This guide covers setup, terminology, downmix options, equalization, and troubleshooting.

---

## 1. Setup & Device Configuration

### Microphone Permission
SoundMix routes audio from an input device to an output device. macOS considers any audio input a "microphone", so SoundMix requires Microphone permission to run. Without it, the application cannot capture the audio it needs to process.

### Virtual Loopback Inputs
SoundMix does not decode proprietary formats (like Dolby Atmos bitstreams) directly from a file or streaming service. Instead, you need a virtual loopback device (like BlackHole or Loopback) to route decoded, uncompressed multichannel audio (PCM) from your player (e.g., Apple Music or a DAW) into SoundMix.

1. Set your player or system output to the virtual loopback device.
2. In SoundMix's **Devices** panel, select the virtual loopback device as the **Input**.
3. Select your physical speakers or headphones as the **Output**.

### Sample Rates & Clocking
SoundMix requires both the input and output devices to run at the same sample rate. If they differ, SoundMix will resample the input to match the output. It handles clock drift between independent devices automatically using a safety buffer.

### Starting and Stopping
Once your devices are selected, click **Start** in the transport bar. The status badge will change to "Rendering", and live audio will begin flowing. Changes to devices require stopping and restarting the engine.

---

## 2. Downmix & Routing

### Layouts
SoundMix expects a specific channel layout on the input device. In the **Devices** panel, select the layout that matches your source material:
- **2.0, 2.1, 3.0, 3.1, 4.0, 5.1, 7.1**: Standard surround layouts.
- **5.1.2, 5.1.4, 7.1.2, 7.1.4, 9.1.6**: Immersive layouts with height channels.

*Note: SoundMix expects decoded PCM audio beds — it is not an Atmos object renderer. Beds can be folded either by an amplitude matrix (for speakers) or by a head-related filter bank (for headphones); see Binaural / HRTF Fold below.*

### Downmix Recipes (Matrix)
In the **Downmix** panel, choose a recipe that dictates how surround and height channels are folded into the left and right speakers.
- **Reference**: Follows ITU/Dolby guidelines for a standard stereo fold-down.
- **Parity**: A slightly wider mix, often used for parity with certain hardware decoders.
- **Direct**: Passes only the Left and Right channels, ignoring the rest.

### Binaural / HRTF Fold (Headphones)
The **Fold** card in the Downmix panel chooses how the bed becomes two channels.

- **Amplitude matrix** scales each channel by a coefficient and sums it. This is the correct fold for loudspeakers, and the only mode that can reproduce the original application.
- **Binaural / HRTF** filters each channel with the response of a head listening to a loudspeaker at that channel's own angle, so the channels arrive from their own directions instead of being panned between two points. **For headphones only** — on speakers, the crosstalk between the two of them undoes the effect and the result sounds wrong.

**The head is synthesised, not measured.** No measured HRTF dataset ships with SoundMix. The bank is generated from first principles at your device's sample rate:

- **Virtual speakers (spherical head)**: inter-aural delay from the Woodworth model, head shadowing from the Brown-Duda sphere, a pinna notch whose frequency climbs with elevation, and a high-frequency roll-off on rear channels to separate front from back.
- **Virtual speakers (wide head)**: the same, with a larger head and a stronger rear cue.
- **Headphone crossfeed**: no head model at all — each ear simply hears a short, rolled-off copy of the opposite side. Cheap, almost colour-free, and it only loosens the hard-panned stereo image rather than placing channels around you.

Because the head is generic rather than yours, a generic HRTF colours timbre, and front/back confusion and an in-head image are normal rather than faults. If the fold sounds wrong rather than merely different, crossfeed is the conservative option.

**Controls**
- **Head radius** sets both the inter-aural delay and the corner frequency of the head shadow. Bigger heads give longer delays and a stronger shadow.
- **Bass crossover** is the frequency below which the fold collapses to the centre. The ear takes no direction from the bottom octaves, and filtering them per-ear only causes comb filtering, so below this point every channel is summed equally to both ears. Set it to 0 to switch the split off. The two halves are Linkwitz-Riley, so they sum back to a flat response.
- **Rear damping** is how much high-frequency energy a channel directly behind you loses. A sphere alone cannot tell front from back; this is the cue that does.
- **Elevation cue** is the depth of the pinna notch that rises with height.

The table below the controls shows, for every mapped channel, the angle it is placed at, its inter-aural delay in microseconds, and the level it reaches each ear at.

**What it costs.** The fold adds its own bulk delay — a fraction of a millisecond, reported in the Monitor panel and in the table — and it is the most expensive stage in the chain, though still a small fraction of one core. The LFE never goes through the bank; it keeps its own filter and gain exactly as in the matrix fold.

**Headroom in binaural mode.** Peak-safe bounds a filter bank by the sum of its absolute taps, which is a much deeper cut than the same bound on a matrix. Power-preserving is the usable setting here, with the limiter catching the rest.

**Not included:** no room simulation or early reflections, no head tracking, and no loading of measured SOFA datasets.

### LFE (Low-Frequency Effects)
The LFE channel (.1) is handled separately from ordinary bass managed by your speakers.
- **LFE to L/R**: You can add the LFE channel to the stereo mix.
- **Low-pass Filter**: You can apply a Butterworth low-pass filter to the LFE channel before mixing to prevent high-frequency bleed. You can configure the cutoff frequency (Hz) and slope (order).
- **Gain**: LFE is typically mixed +10dB higher than the main channels in a theatrical mix. SoundMix allows you to adjust the LFE gain explicitly.

### Headroom & Trim
Combining multiple channels into two increases the overall signal level, which can cause digital clipping. Collapsing a bed is not a copy: several channels are summed into the left output and several into the right, and amplitudes add. If enough of them carry signal at the same time, the sum goes past full scale and the output clips. How far past depends entirely on the matrix and the layout you chose, so it cannot be a fixed number.

The original app answers this with a blunt −9.5 dB preamp, tuned for one matrix. Choose a different fold or a different layout and that constant is either leaving loudness on the table or still clipping. This card computes the trim from the fold you actually selected.

**The two numbers.** Both are computed from the coefficients of the current fold, and shown in the card:

- **Worst-case gain** is the sum of the absolute coefficients feeding the busier output (the L1 norm). It is the hard ceiling: if every mapped channel hit full scale at once, the output would be at most this. It cannot happen with real material, but nothing can exceed it.
- **Uncorrelated gain** is the root-sum-square of the same coefficients (the L2 norm) — the realistic level change for normal, uncorrelated programme material, where channels are not perfectly in phase.

**Automatic trim** chooses how to act on those:

- **Manual only**: no automatic trim. You set the level yourself, exactly as the original app does with its −9.5 dB preamp. Nothing stops you clipping.
- **Peak-safe (L1)**: trims by the worst-case figure, so the output cannot clip even if every mapped channel hits full scale simultaneously. The safest and the quietest.
- **Power-preserving (L2)**: trims by the uncorrelated figure. Keeps perceived loudness close to the source for normal material; brief peaks are caught by the True-Peak Limiter.

**Total applied** is the automatic trim plus your **Additional manual gain**. The breakdown line under it lists the whole picture, because the fold trim is not the only thing costing headroom: the global PEQ preamp and both speaker preamps sit in the same chain, and EQ filters add their own frequency-dependent boosts and cuts on top. Use **−1 dB** / **+1 dB** for small steps; they apply immediately during playback.

If you set up an overload — a fold that adds gain, no automatic trim, and the limiter off — the card warns you with the level it can reach, which is the overload the original app has.

**Headroom in binaural mode.** Peak-safe bounds a filter bank by the sum of its absolute taps, which is a far deeper cut than the same bound on a matrix, so it costs far too much level to be useful here. Power-preserving is the setting to use, with the limiter catching what is left.

---

## 3. Output EQ & Correction

The **Output EQ** panel provides parametric equalization (PEQ) to correct the frequency response of your headphones or speakers.

### Equalizer APO / REW Compatibility
SoundMix natively understands the plain-text filter format exported by Room EQ Wizard (REW) and used by Equalizer APO. You can paste filters directly into the editor or import `.txt` files.

### Global vs. Speaker Correction
- **Global PEQ**: Applied to both the Left and Right channels equally. Useful for general headphone correction.
- **Speaker Correction**: Applied independently to the Left and Right physical speakers. This correction follows the physical speaker even if you use the "Swap L/R" toggle.

### Profiles & Measurements
- **Profiles**: You can save your EQ settings as named profiles in the library for quick switching.
- **Measurements**: You can load a frequency response measurement file (e.g., from AutoEQ or squig.link) to visualize the uncorrected response alongside your applied EQ curve and target curve. SoundMix supports standard 2-column or 3-column CSV/TXT measurement files.

---

### The Graphical PEQ Editor
**Output EQ → Response → Expand & edit PEQ** opens a full-screen plot of the selected profile's filters, where bands are edited by dragging rather than by typing.

- Drag a numbered band to move it: vertically for gain, horizontally for frequency. Hold **Shift** to lock the drag to whichever axis you have moved furthest along. Bands keep their numbering, so dragging one past another never renumbers either.
- Each row in the band list has its own mute and delete control, and the **Delete** key removes the selected band once the list has focus. Nothing is destroyed for good: **Reset** restores deleted bands along with every other unapplied edit.
- **Audition live**, on by default, sends the draft to the running processor as you edit, so you can tune by ear. Nothing is written to the EQ text or the profile library until **Apply**, and **Cancel** — or closing the window any other way — puts the audio back to the EQ you started with. Edits ramp over a few hundred milliseconds rather than stepping, so a large drag does not click; after a fast flick the sound therefore lags the plot a little.
- The profile picker in the header loads another profile without leaving the editor. A draft with unapplied edits asks whether to apply or discard first, and the measured response and target curve follow the switch.
- While EQ bypass is on nothing is auditioned — bypass still means bypass.

## 4. Monitoring & Protection

### The True-Peak Limiter
In the **Monitor** panel, you can configure the True-Peak Limiter. It sits at the very end of the signal chain to protect your output from clipping.
- **Ceiling**: The absolute maximum output level (e.g., -1.0 dBTP).
- **Release**: How quickly the limiter recovers after reducing gain.
- *Note: A limiter does not make quiet audio louder; it only pushes down loud peaks that exceed the ceiling.*

### Meters
The transport bar displays the final Left and Right output levels. The **Monitor** panel provides a detailed view of every input channel's activity before downmixing.

### The Log
The **Log** panel displays a running history of engine events, layout changes, buffer underruns, and errors. If audio stops unexpectedly, check the log for clues.

---

## 5. Troubleshooting

- **No Audio**: Ensure Microphone permission is granted in System Settings. Verify your loopback device is active and selected.
- **Low Volume**: A full 9.1.6 downmix requires significant automatic trim (-15dB or more) to guarantee no clipping. If the source material is quiet, use the Manual Gain slider to boost the level, but ensure the Limiter is enabled.
- **Distortion / Pumping**: If the audio sounds distorted or "pumps" unnaturally, you have added too much Manual Gain or EQ Preamp, and the Limiter is working too hard. Check the Limiter status in the transport bar; if it shows constant gain reduction (e.g., -6.0 dB), reduce your manual gain.
- **Missing Channels**: Ensure the Layout selected in the Devices panel matches the channel count and order of your source material.
- **Audio Dropouts / Glitches**: This indicates a buffer underrun, often caused by heavy CPU load or misaligned device clocks. Try increasing the `Safety buffer` size in the Devices panel.
