#!/bin/bash
# Mocked volume writes plus read-only inspection of connected audio devices.
set -euo pipefail
cd "$(dirname "$0")"
MODCACHE="${TMPDIR:-/tmp}/soundmix-modcache"
mkdir -p build "$MODCACHE"
swiftc -O -swift-version 5 -module-cache-path "$MODCACHE" \
    Sources/SoundMixEngine/AudioDevice.swift Sources/SoundMixEngine/DeviceVolume.swift \
    Tests/DeviceVolume/main.swift -o build/devicevolumetests
exec ./build/devicevolumetests
