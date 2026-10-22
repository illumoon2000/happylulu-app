#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/runner-artwork
swiftc -parse-as-library -swift-version 6 \
  -module-cache-path "$PWD/.build/runner-artwork-modulecache" \
  Sources/CPURunnerIntegration/RunnerAnimal.swift \
  Sources/CPURunnerIntegration/RunnerArtwork.swift scripts/check-runner-artwork.swift \
  -framework AppKit -o .build/runner-artwork/check
.build/runner-artwork/check "${1:-$PWD/.build/runner-artwork}"
