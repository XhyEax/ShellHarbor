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
# tsnet necessarily brings the Go runtime and userspace networking stack, but
# release bundles do not need DWARF, the Go symbol table, or a build ID. Keeping
# feature code intact avoids changing Headscale/Tailscale compatibility while
# removing roughly one third of the helper's on-disk size.
"$GO_BINARY" build \
    -trimpath \
    -ldflags="-s -w -buildid=" \
    -o "$OUTPUT_PATH" \
    .
