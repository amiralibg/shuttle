#!/bin/bash
set -euo pipefail

SPIKE_NAME="${1:-}"
if [ -z "$SPIKE_NAME" ]; then
    echo "Usage: ./spikes/build.sh <s1|s2|s3|s4>"
    exit 1
fi

SRC_FILE="spikes/${SPIKE_NAME}*.swift"
RESOLVED_SRC=$(ls $SRC_FILE 2>/dev/null | head -n 1 || true)

if [ -z "$RESOLVED_SRC" ]; then
    echo "No spike source found matching: $SPIKE_NAME"
    exit 1
fi

BIN_OUT="spikes/bin/${SPIKE_NAME}"
mkdir -p spikes/bin

echo "Compiling $RESOLVED_SRC -> $BIN_OUT"
swiftc -O "$RESOLVED_SRC" -o "$BIN_OUT"
echo "Build complete. Run with: ./$BIN_OUT"
