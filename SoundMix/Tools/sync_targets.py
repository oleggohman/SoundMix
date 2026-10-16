#!/usr/bin/env python3
"""Sync the reference-target drop folder into the app's bundled targets.

Reads every ``.txt`` curve in the drop folder (default ``../Targets`` next to
the SoundMix repo, overridable with SOUND_TARGETS_DIR), resamples each onto the
standard 481-point 20 Hz - 20 kHz log grid the app's tests require, writes
``Resources/Targets/<slug>.csv``, and regenerates ``manifest.json`` -- the list
the app reads at runtime. Legacy AutoEq targets named in LEGACY_TARGETS below
are kept in the manifest alongside the folder entries.

Provenance is recorded in ``sources.json``: the drop-folder file each CSV was
built from and the sha256 of the emitted CSV.

Run with no arguments from the repo root (build.sh does this on every build).
A missing drop folder is not an error: the existing CSVs are kept so builds
work on machines without the folder.
"""

import hashlib
import json
import math
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DROP_DIR = os.environ.get("SOUND_TARGETS_DIR",
                          os.path.normpath(os.path.join(REPO, "..", "Targets")))
TARGETS_DIR = os.path.join(REPO, "Resources", "Targets")

# Targets that predate the drop folder and are not (yet) available there.
# Entries the drop folder supersedes (jm1-harman, harman-iem-2019) are not
# listed here and are removed by the sync.
LEGACY_TARGETS = [
    {"id": "ief-neutral", "name": "IEF / Crinacle Neutral", "file": "ief-neutral.csv"},
    {"id": "ief-neutral-bass", "name": "IEF / Crinacle Neutral + bass", "file": "ief-neutral-bass.csv"},
]
RETIRED_FILES = ["jm1-harman.csv", "harman-iem-2019.csv"]

# Resample grid: 481 points from 20 Hz to 20 kHz, evenly spaced in log
# frequency. All folder curves land on the same grid so plots and AutoTune see
# identical sampling.
GRID = [20.0 * (1000.0 ** (i / 480)) for i in range(481)]


def slugify(name):
    s = name.lower().replace("β", "beta")
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s or "target"


def load_curve(path):
    points = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            fields = re.split(r"[\s,;]+", line.strip())
            if len(fields) >= 2:
                try:
                    hz, db = float(fields[0]), float(fields[1])
                except ValueError:
                    continue
                if hz > 0 and math.isfinite(hz) and math.isfinite(db):
                    points.append((hz, db))
    points.sort()
    return points


def interp_log(points, hz):
    """Linear in log-frequency, clamped at the ends -- the same interpolation
    the app's FrequencyResponse.magnitudeDB uses."""
    if hz <= points[0][0]:
        return points[0][1]
    if hz >= points[-1][0]:
        return points[-1][1]
    lo, hi = 0, len(points) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if points[mid][0] <= hz:
            lo = mid
        else:
            hi = mid
    a, b = points[lo], points[hi]
    t = math.log10(hz / a[0]) / math.log10(b[0] / a[0])
    return a[1] + (b[1] - a[1]) * t


def write_csv(path, points):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("* Freq(Hz), SPL(dB)\n")
        for hz, db in points:
            fh.write(f"{hz:.6f}, {db:.3f}\n")


def main():
    manifest = []
    sources = []

    txts = []
    if os.path.isdir(DROP_DIR):
        txts = sorted(f for f in os.listdir(DROP_DIR) if f.lower().endswith(".txt"))
    else:
        print(f"Drop folder not found ({DROP_DIR}); keeping existing targets.")

    os.makedirs(TARGETS_DIR, exist_ok=True)

    # Start from the legacy entries that still exist; the folder entries are
    # appended after, so a folder file named like a legacy target wins.
    kept_legacy = []
    for entry in LEGACY_TARGETS:
        path = os.path.join(TARGETS_DIR, entry["file"])
        if os.path.exists(path):
            kept_legacy.append(entry)
        else:
            print(f"warning: legacy target missing: {entry['file']}")

    seen_ids = {}
    for filename in txts:
        name = os.path.splitext(filename)[0]
        tid = slugify(name)
        src = os.path.join(DROP_DIR, filename)
        points = load_curve(src)
        if len(points) < 8:
            print(f"warning: skipping {filename}: fewer than 8 valid points")
            continue
        if points[0][0] > 20 or points[-1][0] < 19000:
            print(f"warning: {filename} spans {points[0][0]:.0f}-{points[-1][0]:.0f} Hz,"
                  " below the bundled comparison range; clamped at the edges")
        curve = [(hz, interp_log(points, hz)) for hz in GRID]
        csv_name = tid + ".csv"
        dst = os.path.join(TARGETS_DIR, csv_name)
        write_csv(dst, curve)
        sha = hashlib.sha256(open(dst, "rb").read()).hexdigest()
        seen_ids[tid] = True
        manifest.append({"id": tid, "name": name, "file": csv_name})
        sources.append({"file": csv_name,
                        "source": os.path.relpath(src, REPO),
                        "revision": None,
                        "sha256": sha,
                        "downloaded": None})
        print(f"synced {filename!r} -> {csv_name} ({len(curve)} points)")

    # Retired targets the drop folder replaced.
    for gone in RETIRED_FILES:
        path = os.path.join(TARGETS_DIR, gone)
        if os.path.exists(path):
            os.remove(path)
            print(f"retired {gone}")

    # Remove folder-derived CSVs whose source disappeared.
    for f in os.listdir(TARGETS_DIR):
        if not f.endswith(".csv"):
            continue
        if any(e["file"] == f for e in kept_legacy) or f in (e["file"] for e in manifest):
            continue
        if f in (e["file"] for e in sources):
            continue
        os.remove(os.path.join(TARGETS_DIR, f))
        print(f"removed stale {f}")

    manifest = kept_legacy + manifest

    with open(os.path.join(TARGETS_DIR, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"manifest.json: {len(manifest)} targets")

    if sources:
        path = os.path.join(TARGETS_DIR, "sources.json")
        existing = {}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as fh:
                try:
                    for e in json.load(fh):
                        existing[e["file"]] = e
                except json.JSONDecodeError:
                    existing = {}
        for e in sources:
            existing[e["file"]] = e
        legacy_files = {e["file"] for e in kept_legacy}
        merged = [e for f, e in existing.items() if f in legacy_files] + sources
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(merged, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        print(f"sources.json: {len(merged)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
