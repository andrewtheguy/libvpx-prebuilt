# CLAUDE.md

## Before `cargo` anything

Every crate here links the archive, so cargo cannot build until one exists:

```sh
./build.sh <target>     # the target this machine is (see build.sh's usage for the list)
./sync-prebuilt.sh      # dist/ -> crates/libvpx-prebuilt-sys/prebuilt/
```

`./sync-prebuilt.sh --fetch` is the alternative once a release exists. Neither `clippy` nor
`test` works without one of the two, which is why CI runs clippy inside the build job rather
than beside it.

## This machine builds one target

`./build.sh` does not cross-compile — libvpx's own `configure` targets the machine it runs on.
So a Mac builds `macos-arm64` and nothing else here, and the other two targets are exercised by
`workflow_dispatch` on **Build libvpx**. Do not add a cross-compilation path without measuring
what it produces; the point of the MANIFEST is that every claim in it was checked on the artifact.

## Bootstrapping order

The download paths cannot pass before a release exists. On a fresh fork: run **Build libvpx**
(`workflow_dispatch`, `targets: all`) by hand, then **Release libvpx archives**. CI is green from
there on.

## What not to "fix"

- **No CPU floor on x86_64.** It is absent on purpose — libvpx dispatches its SIMD at run time,
  so a `-march` floor costs compatibility and buys almost nothing. The README says why at length.
  Its siblings (`libopus-prebuilt`, `fdk-aac-prebuilt`) do name floors, for codecs where the flag
  decides whether the kernels are reachable.
- **`vpx_img_wrap` with a non-null dummy pointer** is libvpx's own idiom for "compute the layout,
  allocate nothing". Such an image must never be passed to `vpx_img_free`.
- **`--enable-realtime-only`** is deliberate and it is a real restriction: no two-pass, no
  `--good`/`--best` deadlines. A consumer that needs those wants `LIBVPX_PREBUILT_DIR`.
- **The commit pin, not a tarball checksum.** libvpx publishes no tarballs and GitHub's generated
  ones are not byte-stable. Do not "simplify" `source.sh` into a `curl` of a tag archive.
