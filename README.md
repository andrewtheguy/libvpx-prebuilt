# libvpx-prebuilt

Static **libvpx 1.16.0** (VP9 encoder and decoder), built once so that nothing which *links* it
needs a build system at all.

```toml
vpx-sys = { package = "libvpx-prebuilt-sys", git = "https://github.com/andrewtheguy/libvpx-prebuilt", tag = "v1.16.0-…" }
```

No assembler, no `configure`, no cmake, no pkg-config, no libclang, and no `LIBVPX_*`
environment variables — not in a Dockerfile, not in a packaging script, not in CI. `build.rs`
downloads the archive for its target from this repository's latest release, checks it, and emits
the link flags.

That is the whole point. The alternatives all move work onto every consumer:

| approach | what a consumer must have |
|---|---|
| a system libvpx via `pkg-config` (`vpx-sys`) | libvpx installed, matching, and pkg-config — and a runtime dependency in the finished binary |
| vcpkg + `bindgen` at build time (RustDesk's `scrap`) | vcpkg, a C toolchain, an assembler, and LLVM |
| **this** | curl and tar |

## Layout

```
libvpx.env                       the pin: version, commit, upstream, release repo
source.sh                        clone + assert the commit (sourced by the two scripts below)
build.sh <target>                configure, make, verify, write dist/<target>/MANIFEST
sync-prebuilt.sh                 dist/ -> the crate's cache; --headers; --check; --fetch
check-static.sh <binary>         assert a finished binary carries libvpx and links none
crates/libvpx-prebuilt-sys/      the FFI crate: committed headers, committed bindings, build.rs
crates/libvpx-e2e/               a consumer that encodes and decodes, run on every target in CI
```

Targets: `macos-arm64`, `linux-x86_64`, `linux-aarch64`. **No Windows** — libvpx's build is
`configure` + `make`, MSVC needs its own generator and an assembler this pipeline does not set
up, and no consumer of this repository targets it. Adding one is real work rather than a line in
a case statement.

## The chain

Every link is checked, and CI checks all of them:

```
libvpx.env pins a commit
  -> source.sh asserts `git rev-parse HEAD` and refuses a dirty tree
    -> build.sh compiles that tree and writes sha256(library) into a MANIFEST
      -> the release publishes the archive plus SHA256SUMS
        -> build.rs verifies the download against SHA256SUMS
          -> and the extracted .a against the MANIFEST beside it, on every path
```

Separately, and this is the part a reviewer can read:

```
include/vpx/  is byte-identical to the pinned commit's headers   (sync-prebuilt.sh --check)
              and to what `make install` produced in a real build (the same, with dist/ present)
src/bindings.rs is what bindgen 0.72.1 makes of those headers     (gen-bindings.sh --check)
```

A commit SHA rather than a tarball checksum, unlike this repository's `libopus-prebuilt` and
`fdk-aac-prebuilt` siblings: libvpx publishes no tarballs, and GitHub's generated tag archives
carry no byte-stability guarantee. A commit covers the whole tree and git verifies it.

## What is in the archive

VP9 encoder **and** decoder, `--enable-realtime-only`, no VP8. The decoder is kept even though
the consumer this was built for only encodes: it is what lets `libvpx-e2e` decode what it just
encoded, and static linking is per-object, so a binary that never calls `vpx_codec_vp9_dx` pulls
none of it in.

The build then asserts what it configured, rather than trusting it:

- the sixteen entry points the crates actually call are defined;
- `vpx_codec_vp8_cx` is **not** — which is how `--disable-vp8` is known to have taken;
- at least fifty architecture kernels (`*_avx2` / `*_neon`) are present. This is a **gate**, not
  evidence: on x86_64 those kernels are exactly what silently disappears when no assembler is
  installed, because libvpx falls back to C and succeeds;
- `libm` and the C++ runtime requirements are *measured* from the undefined symbols, and
  `build.rs` emits `-lm` on Linux because of what was measured rather than because of a guess;
- on macOS the deployment target is read back off the finished archive (`minos 11.0`). libvpx's
  `*-darwin2[0-5]-*` targets add no `-mmacosx-version-min` at all, so without this the archive
  inherits the *builder's* OS version — measured as `minos 26.0` on the machine this was written
  on, which is an archive that cannot be linked into anything older.

## No CPU floor, deliberately

The other two prebuilt repositories name an x86-64-v3 / Coffee Lake floor and compile for it.
This one names none, and that is a measurement rather than an oversight: libvpx dispatches its
SSE2..AVX2 and NEON kernels through runtime CPU detection, so `-march=x86-64-v3` cannot decide
whether they are called. It could only autovectorise the C fallbacks that exist *for the machines
the floor would have excluded*. So the archive runs on any x86-64 and uses AVX2 where the CPU has
it, and what CI asserts instead is that the kernels are in there.

## Local loop

```sh
./build.sh macos-arm64          # -> dist/macos-arm64/{lib,include,MANIFEST}
./sync-prebuilt.sh              # -> crates/libvpx-prebuilt-sys/prebuilt/, what cargo will link
cargo run --release -p libvpx-e2e
./check-static.sh target/release/libvpx-e2e
```

`./sync-prebuilt.sh --fetch` pulls the latest release's archives instead, for working offline
afterwards or for a target this machine cannot build. `LIBVPX_PREBUILT_DIR=/prefix` overrides
everything with an archive you built yourself — it is the escape hatch for an unsupported target,
for VP8, or for a non-realtime build, and `build.rs` warns that nothing about it was checked.

## Bootstrapping

The download-based paths cannot pass before the first release exists, so the order for a fresh
fork is: run **Build libvpx** by hand (`workflow_dispatch`, `targets: all`), then **Release libvpx
archives**. CI is green from that point on.

## Which library got linked

```sh
cargo build -vv 2>&1 | grep 'libvpx '
```

`build.rs` emits the provenance, the version, the checksum result, the CPU floor and the SIMD
count as `cargo:info` lines — not warnings, because this is the normal case and a warning on
every build teaches people to ignore warnings. At runtime `vpx_sys::version()` returns what the
archive itself reports, and `vpx_sys::PREBUILT_VERSION` is what this repository pinned; the e2e
binary asserts they agree, which is how a system library winning the link would be caught.

## Licensing

libvpx is **BSD-3-Clause** with Google's separate **PATENTS** grant — both shipped in every
archive and at the repository root. That combination is the entire reason to prefer VP9 over
H.264 in software that has to run in a browser: it is a codec a stock Chromium build carries, and
H.264 is not.
