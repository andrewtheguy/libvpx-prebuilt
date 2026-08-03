#!/usr/bin/env bash
# Build one static libvpx, with the claims about it verified rather than assumed.
#
# Usage:
#   ./build.sh <target>
#
# Targets:
#   macos-arm64      libvpx.a   (Apple silicon, deployment target 11.0)
#   linux-x86_64     libvpx.a   (x86-64 baseline; AVX2 kernels dispatched at run time)
#   linux-aarch64    libvpx.a   (ARMv8-A baseline; NEON kernels dispatched at run time)
#
# Output: dist/<target>/{lib,include}/… plus a MANIFEST naming the version, the commit, the
# checksum, the configure line, the CPU floor and — measured rather than assumed — whether the
# archive needs libm and whether it needs a C++ runtime.
#
# **`configure` + `make install`, not cmake.** libvpx's own build is what knows which of its
# hundreds of source files are compiled for which architecture, which assembly files go to
# which assembler, and which kernels are guarded behind runtime CPU detection. Reproducing
# that in a build script is the thing this repository exists to avoid: building it here once,
# with libvpx's own build system, is exactly what frees every *consumer* from needing an
# assembler, a configure shell or a C toolchain at all.
#
# No Windows target. libvpx's build is `configure` + `make`, MSVC needs its own generator and
# an assembler this script does not set up, and no consumer of this repository targets it.
# Adding one is a real piece of work rather than a line in the case statement below.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
# shellcheck source=libvpx.env
. ./libvpx.env
# shellcheck source=source.sh
. ./source.sh

target="${1:-}"
[ -n "$target" ] || {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'
  exit 1
}

src="$here/build/libvpx-${LIBVPX_VERSION}"
out="$here/dist/$target"

# ---------------------------------------------------------------- source

# Cloned, commit-asserted and checked clean by source.sh, which sync-prebuilt.sh also uses to
# take the headers from — the pin is one implementation, not two.
ensure_source

# ---------------------------------------------------------------- configure

# Common to every target.
#
# `--enable-realtime-only` drops libvpx's two-pass and non-realtime rate control, which is
# sound here and *only* here: every consumer of this archive encodes with `VPX_DL_REALTIME`
# and a pinned quantizer. A project that wanted `--good`/`--best` deadlines would need its own
# build, which LIBVPX_PREBUILT_DIR is for.
#
# `--disable-vp8` because nothing here encodes or decodes VP8, and the verification below
# asserts its absence rather than trusting this line.
#
# The **decoder is kept** even though the consumers only encode. It is what lets
# crates/libvpx-e2e decode what it just encoded — a round trip is the only test that says the
# bitstream is real rather than merely non-empty — and static linking is per-object, so a
# consumer that never calls `vpx_codec_vp9_dx` pulls none of it into its binary.
#
# `--disable-webm-io` and `--disable-libyuv` cut the two optional dependencies libvpx's
# *examples* want. Nothing in the library needs them, and shipping a libyuv folded into this
# archive would collide with a consumer's own.
#
# `--prefix` is *not* in here, and that is deliberate: it is the one argument whose value is
# this machine's absolute path, and the MANIFEST records this list. A build identity that
# differs between two machines that built the same thing is one nobody can compare.
configure_args=(
  --enable-static --disable-shared --enable-pic
  --disable-examples --disable-tools --disable-docs --disable-unit-tests
  --disable-webm-io --disable-libyuv
  --enable-realtime-only
  --disable-vp8 --enable-vp9-encoder --enable-vp9-decoder
)

# Extra flags, per target. Kept separate because they are the one thing here that decides
# *which machines the artifact runs on*, and the MANIFEST records them for that reason.
#
# Note what none of them is: `-march=native`. Nothing may be tuned to the *builder's* CPU,
# because the archive is linked into binaries that run elsewhere.
extra_cflags=()
# GNU `ar`'s deterministic mode, for the targets that have it. See the reproducibility note
# below; empty means "libvpx's own default", which is what macOS gets.
arflags=()
# What `make` is told, so a target can add a variable override on the command line — the only
# place `ARFLAGS` can be set, since libvpx's Makefile assigns it with `=`.
floor='unset'
deployment_target=''

case "$target" in
  macos-arm64)
    # An explicit toolchain rather than the auto-detected one, and this is not cosmetic:
    # configure names the target after the *builder's* Darwin version (`arm64-darwin25-gcc` on
    # this machine), so the build identity would move with the runner image.
    configure_args+=(--target=arm64-darwin20-gcc)
    # And the deployment target has to be passed by hand. libvpx's `*-darwin2[0-5]-*` case
    # adds `-arch arm64` and *no* `-mmacosx-version-min` at all, so clang defaults to the
    # host's own version — a measured `minos 26.0` on this machine, which is an archive that
    # warns or refuses when linked into a binary targeting anything older. Lower than any
    # consumer targets: there is no cost to building older, and the verification below reads
    # the answer back off the archive rather than trusting this line.
    deployment_target=11.0
    extra_cflags+=("-mmacosx-version-min=$deployment_target")
    # No floor to choose, and no `-mcpu=apple-m1` either — see the note in the linux-x86_64
    # arm below. libvpx dispatches its NEON, dotprod, i8mm and SVE kernels through runtime CPU
    # detection, so the flag could only change the *scalar* fallbacks that mostly do not run.
    floor='armv8-a (runtime CPU detection: neon/dotprod/i8mm/sve dispatched at run time)'
    ;;
  linux-x86_64)
    configure_args+=(--target=x86_64-linux-gcc)
    # **No CPU floor, deliberately — this is where this repository departs from its siblings.**
    #
    # libopus-prebuilt and fdk-aac-prebuilt both name a Coffee Lake floor and compile for it.
    # Transplanting that here would be a mistake: libvpx ships hand-written AVX2/SSE kernels
    # and picks between them *at run time* with `--enable-runtime-cpu-detect`, so
    # `-march=x86-64-v3` cannot decide whether they are called. All it could do is autovectorize
    # the C fallbacks that exist for machines without those kernels — and cost the archive every
    # pre-AVX2 machine in exchange. The verification below asserts the AVX2 kernels are in the
    # archive, which is the property that actually matters.
    floor='x86-64 baseline (runtime CPU detection: sse2..avx2 kernels dispatched at run time)'
    arflags=(ARFLAGS=-crsD)
    ;;
  linux-aarch64)
    configure_args+=(--target=arm64-linux-gcc)
    # Same argument as macos-arm64, and NEON is mandatory in ARMv8-A anyway.
    floor='armv8-a (runtime CPU detection: neon/dotprod/i8mm/sve dispatched at run time)'
    arflags=(ARFLAGS=-crsD)
    ;;
  *)
    echo "unknown target: $target" >&2
    exit 1
    ;;
esac

# x86_64 needs an assembler, and libvpx **falls back to C without one** rather than failing:
# configure prints a note, the build succeeds, and the archive silently loses every SSE and
# AVX2 kernel. That is exactly the failure this repository exists to make loud, so it is
# checked here and asserted again on the finished archive.
if [ "$target" = "linux-x86_64" ]; then
  if command -v nasm >/dev/null 2>&1; then
    configure_args+=(--as=nasm)
  elif command -v yasm >/dev/null 2>&1; then
    configure_args+=(--as=yasm)
  else
    echo "neither nasm nor yasm is installed, and libvpx needs one for x86_64 SIMD." >&2
    echo "  apt-get install nasm   (or yasm)" >&2
    exit 1
  fi
fi

if [ ${#extra_cflags[@]} -gt 0 ]; then
  configure_args+=("--extra-cflags=${extra_cflags[*]}")
fi

# Reproducibility, and what it does and does not cover.
#
# libvpx compiles no `__DATE__` or `__TIME__` — the version string is generated by its own
# build from the source tree — so unlike fdk-aac there is no `SOURCE_DATE_EPOCH` dance to do.
# What is left is the archive *container*: `ar` stamps each member with an mtime and a uid, so
# two builds of identical objects differ. GNU ar's `D` flag zeroes those fields; Apple's ar
# has no equivalent, so `macos-arm64` is not byte-reproducible and the CI job that asserts
# reproducibility builds linux-x86_64 only. Stated rather than papered over.
#
# The `.tar.gz` around the archive is not reproducible either — gzip stamps an mtime — which
# is why `sha256(library)` in the MANIFEST is the checksum worth comparing between releases,
# and the tarball's is only good for catching a bad download.

rm -rf "$out" "build/$target"
mkdir -p "build/$target"

echo ">> configuring libvpx ${LIBVPX_VERSION} for $target"
(cd "build/$target" && "$src/configure" --prefix="$out/prefix" "${configure_args[@]}")

echo ">> building"
make -C "build/$target" -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" "${arflags[@]+"${arflags[@]}"}"
make -C "build/$target" install >/dev/null

# ---------------------------------------------------------------- collect

lib_name=libvpx.a
mkdir -p "$out/lib"
cp "$out/prefix/lib/$lib_name" "$out/lib/$lib_name"
# The whole installed header directory, not a hand-picked list. libvpx's public surface *is*
# `include/vpx/`, its own build decides what belongs there, and that set moves between
# releases — 1.16 installs `vpx_ext_ratectrl.h` and `vpx_tpl.h`, which a list written against
# an older tag would silently drop. Copying the directory and diffing it as a directory later
# also catches an *extra* file, which matters because the bindings are generated from whatever
# is sitting in it.
cp -R "$out/prefix/include" "$out/include"
# `vpx.pc` names the build machine's prefix, which is actively misleading sitting inside a
# relocatable tarball — nothing consuming this points pkg-config at it.
rm -rf "$out/include/../lib/pkgconfig" "$out/prefix"
# libvpx's own licence and Google's patent grant, from the same verified checkout. This
# licence is the whole reason this repository exists — a BSD-3-Clause codec with a patent
# grant is what a browser can carry and H.264 cannot — so shipping it is not optional.
cp "$src/LICENSE" "$src/PATENTS" "$out/include/"

# ---------------------------------------------------------------- verify

echo ">> verifying the entry points are in the archive"
# The functions the crates above actually call. An archive that configured itself down to the
# decoder only, or that landed under the right name with the wrong contents, fails here rather
# than at the link step of every consumer.
entry_points='vpx_codec_vp9_cx vpx_codec_vp9_dx vpx_codec_enc_init_ver
              vpx_codec_enc_config_default vpx_codec_enc_config_set vpx_codec_encode
              vpx_codec_get_cx_data vpx_codec_control_ vpx_codec_destroy
              vpx_codec_dec_init_ver vpx_codec_decode vpx_codec_get_frame
              vpx_img_wrap vpx_img_free vpx_codec_version_str vpx_codec_error_detail'

symbols="$(nm --defined-only "$out/lib/$lib_name" 2>/dev/null || true)"
for symbol in $entry_points; do
  # A here-string rather than `printf … | grep -q`: under `set -o pipefail`, grep -q exits on
  # the first match, the writer takes SIGPIPE, and the pipeline reports 141 — so a *found*
  # symbol reads as a missing one.
  #
  # `[ _]` because Mach-O prefixes every C symbol with an underscore and ELF does not.
  grep -qE "[ _]${symbol}$" <<<"$symbols" || {
    echo "$symbol is not defined in $lib_name — this is not a complete libvpx" >&2
    exit 1
  }
done
echo "   $(printf '%s\n' "$entry_points" | wc -w | tr -d ' ') entry points defined"

# And that `--disable-vp8` took. A configure flag that was ignored, or a stale build directory
# reused, shows up here as a codec nobody asked for sitting in the archive.
if grep -qE "[ _]vpx_codec_vp8_cx$" <<<"$symbols"; then
  echo "vpx_codec_vp8_cx is defined — --disable-vp8 did not take" >&2
  exit 1
fi
echo "   no VP8, as configured"

# The architecture kernels, as a **gate** rather than as evidence.
#
# fdk-aac-prebuilt records an instruction count here and asserts nothing, because fdk-aac
# ships no SIMD to lose. libvpx does: hundreds of hand-written kernels, selected at run time,
# and losing them is the difference between real-time 1080p and not. On x86_64 they are also
# exactly what goes missing when the assembler is absent, which is a thing that happens.
echo ">> verifying the SIMD kernels are in the archive"
case "$target" in
  linux-x86_64)
    kernel_pattern='_avx2$'
    kernel_name='AVX2'
    ;;
  macos-arm64 | linux-aarch64)
    kernel_pattern='_neon$'
    kernel_name='NEON'
    ;;
esac
kernels="$(grep -cE "$kernel_pattern" <<<"$symbols" || true)"
# These archives define hundreds. The threshold separates "the assembler ran" from "it did
# not" with no risk of landing in between.
if [ "${kernels:-0}" -lt 50 ]; then
  echo "only ${kernels:-0} $kernel_name kernels in $lib_name — the SIMD build did not happen" >&2
  exit 1
fi
simd_evidence="$kernels $kernel_name kernels"
echo "   $simd_evidence"

# Which runtime libraries this archive needs — measured, not assumed, because build.rs reads
# both answers out of the MANIFEST and emits link flags from them.
echo ">> measuring the runtime requirements"
undefined="$(nm --undefined-only "$out/lib/$lib_name" 2>/dev/null | awk '{print $NF}' | sort -u || true)"

# libm. libvpx's VP9 rate control uses pow, log and exp, so this is expected to be `required`
# — and it is what makes the difference between a Linux consumer linking `-lm` and a page of
# undefined symbols. On macOS libm is part of libSystem and no flag is needed, which is why
# build.rs reads this *and* the target.
libm_symbols="$(grep -E '^_?(pow|exp|log|logf|log2|sqrt|floor|ceil|fabs|atan2?|sin|cos|round|fmod)$' \
  <<<"$undefined" | tr '\n' ' ' | sed 's/ $//' || true)"
if [ -z "$libm_symbols" ]; then
  libm='none'
  echo "   libm: none"
else
  libm="required: $libm_symbols"
  echo "   libm: $libm_symbols"
fi

# The C++ runtime. libvpx is C, and its one C++ file (`vp9/ratectrl_rtc.cc`) goes into a
# *separate* `libvpxrc.a` that `make install` does not install — so the answer should be
# `none`, which is a property worth keeping rather than assuming.
cxx_undefined="$(grep -E '^_?(_Zn[wa]|_Zd[la]|_ZN?St|__cxa_|__gxx_personality|_Unwind_)' \
  <<<"$undefined" | sort -u || true)"
if [ -z "$cxx_undefined" ]; then
  cxx_runtime='none'
  echo "   cxx_runtime: none — the archive needs no libstdc++/libc++"
else
  cxx_runtime="required: $(printf '%s' "$cxx_undefined" | tr '\n' ' ' | sed 's/ $//')"
  echo "   cxx_runtime: $cxx_runtime"
fi

# The deployment target, read back off the archive rather than trusted from the flag. A
# `-mmacosx-version-min` that configure dropped on the floor produces a *working* archive
# wearing a MANIFEST that lies about which machines it links into.
if [ -n "$deployment_target" ]; then
  echo ">> verifying the deployment target"
  minos="$(otool -l "$out/lib/$lib_name" 2>/dev/null | awk '/minos/ {print $2}' | sort -u)"
  [ "$minos" = "$deployment_target" ] || {
    echo "the archive claims minos '$minos', not $deployment_target" >&2
    echo "  (more than one value means some objects missed the flag)" >&2
    exit 1
  }
  echo "   minos $minos on every member"
  floor="$floor, macOS $deployment_target"
fi

echo ">> checksumming the archive"
# The library's own hash, not the tarball's. A .tar.gz is not reproducible — gzip stamps an
# mtime into its header — so the wrapper's checksum can only ever say "these are the bytes
# that were published". This one says something stronger and more useful: *this is the same
# library*, comparable across runs, machines and releases.
lib_sha="$(sha256_of "$out/lib/$lib_name")"
echo "   $lib_sha"

{
  echo "libvpx $LIBVPX_VERSION"
  echo "target $target"
  echo "commit(source) $LIBVPX_COMMIT"
  echo "sha256(library) $lib_sha"
  echo "library lib/$lib_name"
  echo "cpu_floor $floor"
  echo "libm $libm"
  echo "cxx_runtime $cxx_runtime"
  echo "simd_evidence $simd_evidence"
  echo "configure_args ${configure_args[*]}"
} > "$out/MANIFEST"

echo ">> wrote $out"
cat "$out/MANIFEST"
