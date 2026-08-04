#!/usr/bin/env bash
# Connect the shell half of this repo to the Rust half.
#
# Usage:
#   ./sync-prebuilt.sh              copy dist/* into the crate's prebuilt/ cache
#   ./sync-prebuilt.sh --headers    refresh the committed headers and the generated bindings
#   ./sync-prebuilt.sh --check      verify the committed headers and bindings
#   ./sync-prebuilt.sh --fetch      download the latest release's archives into prebuilt/
#
# Neither `prebuilt/` nor `dist/` is committed — see .gitignore. Two things *are*:
#
#   include/vpx/       libvpx's public headers, byte-identical to the pinned commit's. Text,
#                      small, and reviewable — the opposite of a committed `.a`.
#   src/bindings.rs    generated *from* those headers by gen-bindings.sh.
#
# Which is a chain: libvpx.env pins a commit, the commit gates the checkout, the checkout is
# where the headers come from, and the headers are where the bindings come from. It holds only
# if every link is checked, so `--check` checks all of them and CI runs it.
#
# There is nothing here to pin a release with. build.rs fetches from the repository's latest
# release, so publishing one is the whole of releasing — no follow-up commit restating what
# GitHub already serves.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=libvpx.env
. ./libvpx.env
# shellcheck source=source.sh
. ./source.sh

crate=crates/libvpx-prebuilt-sys
prebuilt="$crate/prebuilt"

# Every target build.sh knows how to make.
targets=(macos-arm64 linux-x86_64 linux-aarch64)

# The headers `make install` installs for this configuration, at the paths they live at in the
# source tree. Named here rather than globbed, because `vpx/` also holds `internal/` and the
# `.mk` and `exports` files that describe the build rather than the interface.
#
# The three `vp8*.h` are in the list and are **not** left over from VP8. libvpx declares the
# VP9 codec interfaces and every `VP9E_*` control in `vp8cx.h` and `vp8dx.h` — `vp8.h` is the
# common header both include — so a build with `--disable-vp8` still installs and still needs
# them. Dropping them would take `VP9E_SET_TUNE_CONTENT` out of the bindings.
#
# Membership is not taken on trust: `--check` also diffs this against the `include/vpx` inside
# any built artifact in dist/, so a header a future libvpx starts installing shows up as a
# difference rather than as a missing declaration.
headers=(
  vp8.h
  vp8cx.h
  vp8dx.h
  vpx_codec.h
  vpx_decoder.h
  vpx_encoder.h
  vpx_ext_ratectrl.h
  vpx_frame_buffer.h
  vpx_image.h
  vpx_integer.h
  vpx_tpl.h
)

case "${1:-}" in
  --headers | --check)
    # Both modes need the pinned tree, and getting it goes through the same commit assertion
    # build.sh uses — headers that were never verified would make the generated bindings
    # unverified too, and those are what every FFI call in the crate above is shaped by.
    ensure_source
    src="build/libvpx-${LIBVPX_VERSION}"

    if [ "$1" = "--headers" ]; then
      rm -rf "$crate/include/vpx"
      mkdir -p "$crate/include/vpx"
      for header in "${headers[@]}"; do
        cp "$src/vpx/$header" "$crate/include/vpx/"
      done
      # libvpx's licence and Google's patent grant, from the same verified checkout, in both
      # places they belong: beside the headers they cover, and at the repository root where
      # anyone looks first. The patent grant is half the reason this codec is worth shipping.
      cp "$src/LICENSE" LICENSE
      cp "$src/PATENTS" PATENTS
      echo ">> $crate/include/vpx is now libvpx $LIBVPX_VERSION's ${#headers[@]} public headers"
      (cd "$crate" && ./gen-bindings.sh)
      exit 0
    fi

    echo ">> comparing the committed headers against libvpx $LIBVPX_VERSION"
    # Staged into a directory of nothing but those headers, then compared as directories: that
    # way one `diff -r` covers changed, missing *and* extra files. A header that should not be
    # there matters as much as one that was edited, because bindings.rs is generated from
    # whatever is sitting in that directory.
    staged="$(mktemp -d)"
    trap 'rm -rf "$staged"' EXIT
    for header in "${headers[@]}"; do
      cp "$src/vpx/$header" "$staged/"
    done
    if diff -r "$staged" "$crate/include/vpx" >/dev/null 2>&1; then
      echo "   ${#headers[@]} headers, byte-identical"
    else
      echo "the committed headers are not libvpx $LIBVPX_VERSION's — run --headers" >&2
      diff -r "$staged" "$crate/include/vpx" | head -30 >&2
      exit 1
    fi

    # And the membership check: what libvpx's own `make install` put in an artifact, against
    # what is committed here. This is what catches the list above going stale — a header a new
    # libvpx starts exporting is a declaration the bindings would otherwise silently lack.
    checked=0
    for installed in dist/*/include/vpx; do
      [ -d "$installed" ] || continue
      if ! diff -r "$installed" "$crate/include/vpx" >/dev/null 2>&1; then
        echo "$installed does not match the committed headers — the list in this script is stale" >&2
        diff -r "$installed" "$crate/include/vpx" | head -30 >&2
        exit 1
      fi
      checked=$((checked + 1))
    done
    if [ "$checked" -gt 0 ]; then
      echo "   and identical to what make install produced in $checked built target(s)"
    else
      echo "   note: nothing in dist/, so the installed-set check did not run"
    fi

    diff -q "$src/LICENSE" LICENSE >/dev/null || {
      echo "LICENSE is not the pinned checkout's — run --headers" >&2
      exit 1
    }
    diff -q "$src/PATENTS" PATENTS >/dev/null || {
      echo "PATENTS is not the pinned checkout's — run --headers" >&2
      exit 1
    }
    echo "   LICENSE and PATENTS match"

    (cd "$crate" && ./gen-bindings.sh --check)
    ;;

  --fetch)
    # For working offline afterwards, or for testing a target this machine cannot build. Takes
    # whatever the latest release holds, which is the same thing build.rs would fetch —
    # including the SHA256SUMS check, because a download verified in one half of this
    # repository and not the other is a difference someone would eventually trip over.
    base="https://github.com/$PREBUILT_REPO/releases/latest/download"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    echo ">> SHA256SUMS"
    curl -sSL --fail --max-time 300 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS"

    for target in "${targets[@]}"; do
      asset="libvpx-${LIBVPX_VERSION}-${target}.tar.gz"
      echo ">> $asset"
      curl -sSL --fail --max-time 300 -o "$tmp/$asset" "$base/$asset"

      # `./` tolerated on the name for the same reason build.rs tolerates it: how the release
      # job spelled its glob should not be able to break this.
      expected="$(awk -v a="$asset" '$2 == a || $2 == "./" a { print $1 }' "$tmp/SHA256SUMS")"
      [ -n "$expected" ] || { echo "SHA256SUMS does not list $asset" >&2; exit 1; }
      actual="$(sha256_of "$tmp/$asset")"
      [ "$actual" = "$expected" ] || {
        echo "checksum mismatch for $asset" >&2
        echo "  SHA256SUMS says $expected" >&2
        echo "  the download is $actual" >&2
        exit 1
      }

      rm -rf "${prebuilt:?}/${target:?}"
      mkdir -p "$prebuilt/$target"
      tar xzf "$tmp/$asset" -C "$prebuilt/$target"
    done
    ;;

  "")
    # The local loop: whatever ./build.sh has produced becomes what cargo links, with no
    # release and no network in the picture at all.
    [ -d dist ] || { echo "nothing in dist/ — run ./build.sh <target> first" >&2; exit 1; }
    found=0
    for dir in dist/*/; do
      target="$(basename "$dir")"
      [ -f "$dir/MANIFEST" ] || continue
      rm -rf "${prebuilt:?}/${target:?}"
      mkdir -p "$prebuilt"
      cp -R "$dir" "$prebuilt/$target"
      echo ">> $target ($(sed -n 's/^cpu_floor //p' "$dir/MANIFEST"))"
      found=$((found + 1))
    done
    [ "$found" -gt 0 ] || { echo "no built targets in dist/" >&2; exit 1; }
    echo ">> $found target(s) in $prebuilt — cargo will use these before any release"
    ;;

  *)
    sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 1
    ;;
esac
