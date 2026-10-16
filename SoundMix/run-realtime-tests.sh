#!/bin/bash
# Concurrent DSP handoff and device-clock simulation; no audio hardware required.
set -euo pipefail
cd "$(dirname "$0")"
MODCACHE="${TMPDIR:-/tmp}/soundmix-modcache"
mkdir -p build "$MODCACHE"
FLAGS=(-O)
if [[ "${SANITIZE_THREAD:-0}" == 1 ]]; then FLAGS=(-g -sanitize=thread); fi
swiftc "${FLAGS[@]}" -swift-version 5 -module-cache-path "$MODCACHE" \
    Sources/SoundMixCore/*.swift Sources/SoundMixEngine/RingBuffer.swift \
    Tests/Realtime/main.swift -o build/realtimetests
exec ./build/realtimetests
