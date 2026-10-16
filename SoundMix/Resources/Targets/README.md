# Bundled target curves

The target list is **generated from the drop folder of curve files** (default
`../../Targets` next to the SoundMix repo, override with `SOUND_TARGETS_DIR`).
`Tools/sync_targets.py` runs on every `build.sh`: it reads every `.txt` in the
folder, resamples it onto the standard 481-point 20 Hz–20 kHz log grid, writes
`<slug>.csv` here, and regenerates `manifest.json` — the list the app reads at
runtime. Dropping a new curve file into the folder and rebuilding is all it
takes to add a reference target; removing one removes it from the app.

`sources.json` records provenance: the drop-folder file each CSV was built
from and the SHA-256 of the emitted CSV. Folder curves are resampled, not
copied verbatim.

Currently bundled, from the drop folder:

- JM-1 -10dB Tilt
- PEQdB Diamond β, PEQdB HiFi, PEQdB Ultra, PEQdB Equalized Response,
  PEQdB Diffuse Field
- HiFiEndgame MKIII
- Harman IE 2019
- IEF Preference 2025
- Moondrop VDSF

Kept from the AutoEq repositories (MIT notices alongside, also copied into
the app bundle):

- IEF / Crinacle Neutral and IEF Neutral + bass from iwalton3/AutoEq.

The earlier "JM-1 with Harman filters" and "Harman IEM 2019" entries from
jaakkopasanen/AutoEq were retired in favour of the drop-folder curves.

The app normalizes curves for display using its existing 200 Hz–2 kHz reference.
Comparisons require compatible measurement rigs; selecting a target does not
convert measurements between rigs and does not automatically generate EQ.
