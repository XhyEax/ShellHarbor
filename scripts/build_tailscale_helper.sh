#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_SOURCE="$PROJECT_ROOT/Tools/TailscaleProxyHelper"
OUTPUT_PATH="$PROJECT_ROOT/.build/tailscale-proxy-helper"

if command -v go >/dev/null 2>&1; then
    GO_BINARY="$(command -v go)"
elif [[ -x "$PROJECT_ROOT/.build/go-toolchain/go/bin/go" ]]; then
    GO_BINARY="$PROJECT_ROOT/.build/go-toolchain/go/bin/go"
else
    echo "Go 1.26.5+ is required to build the Tailscale helper." >&2
    exit 1
fi

cd "$HELPER_SOURCE"
"$GO_BINARY" build -trimpath -o "$OUTPUT_PATH" .
