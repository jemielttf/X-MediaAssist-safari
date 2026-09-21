# gifski source

`gifski/` is a Git submodule of https://github.com/ImageOptim/gifski.git,
pinned to the unmodified source of version 1.34.0, commit
`1060eab4500a20f27e2fa3ab7e85473d0e921cbd`.
Source: https://github.com/ImageOptim/gifski/tree/1060eab4500a20f27e2fa3ab7e85473d0e921cbd

After cloning, run `git submodule update --init --recursive` from the repository root.
The parent repository records the exact commit, not a moving branch.
After checking out a release tag, run the initialization command again to select
the exact gifski commit recorded by that release. Cargo dependencies are pinned
by gifski/Cargo.lock and resolved with --locked.

The C API static library is built with `--locked --release --lib --no-default-features --features gifsicle`.
The CLI, PNG input and FFmpeg features are not enabled. AVFoundation decodes video.
`Cargo.lock` pins Rust dependencies; the root `rust-toolchain.toml` pins Rust.
Upstream files and license notices are retained without relicensing them.
`Licenses/THIRD_PARTY_NOTICES.txt` includes locked dependencies and their notices.

Run `script/generate_notices.py` after the first successful library build, and whenever updating the lockfile.
