#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/{clang-cache,swiftpm-cache,swiftpm-config,swiftpm-security}
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift test --disable-sandbox --cache-path .build/swiftpm-cache \
    --config-path .build/swiftpm-config --security-path .build/swiftpm-security
