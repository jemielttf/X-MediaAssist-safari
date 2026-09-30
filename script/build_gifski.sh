#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
if [[ ! -f Vendor/gifski/Cargo.toml ]]; then
    echo 'gifski source is missing. Run: git submodule update --init --recursive' >&2
    exit 1
fi
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CARGO_TARGET_DIR="$ROOT_DIR/build/gifski"
command -v cargo >/dev/null || { echo 'Rust is required: install rustup before building.' >&2; exit 1; }
LIBRARIES=()
for arch in ${ARCHS:-$(uname -m)}; do
    case "$arch" in arm64) target=aarch64-apple-darwin ;; x86_64) target=x86_64-apple-darwin ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
    cargo build --manifest-path "$ROOT_DIR/Vendor/gifski/Cargo.toml" --locked --release --lib --no-default-features --features gifsicle --target "$target"
    LIBRARIES+=("$CARGO_TARGET_DIR/$target/release/libgifski.a")
done
mkdir -p "$ROOT_DIR/build/gifski-universal"
xcrun lipo -create "${LIBRARIES[@]}" -output "$ROOT_DIR/build/gifski-universal/libgifski.a"
