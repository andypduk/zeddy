#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRATE_DIR="${ROOT_DIR}/crates/zed-zeddy"
ZED_EXTENSIONS_DIR="${HOME}/Library/Application Support/Zed/extensions/installed"
TARGET_EXT_DIR="${ZED_EXTENSIONS_DIR}/zeddy"

echo "=== Building Rust Wasm Zed Extension ==="
(cd "${CRATE_DIR}" && cargo build --release --target wasm32-wasip1)

echo "=== Packaging Extension ==="
mkdir -p "${TARGET_EXT_DIR}"
cp "${CRATE_DIR}/extension.toml" "${TARGET_EXT_DIR}/extension.toml"
cp "${CRATE_DIR}/target/wasm32-wasip1/release/zed_zeddy.wasm" "${TARGET_EXT_DIR}/extension.wasm"

echo "✓ Zeddy Rust extension installed into Zed at:"
echo "  ${TARGET_EXT_DIR}"
echo ""
echo "Extension structure:"
ls -lh "${TARGET_EXT_DIR}"
