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
#   windows-x86_64-msvc  vpx.lib  (x86-64 baseline, AVX2 dispatched at run time; dynamic CRT)
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
# The Windows target is libvpx's own MSVC path rather than a MinGW one: `configure` with a
# `*-vs17` target writes a Visual Studio project, `make dist` generates it, and msbuild does
# the compiling. It runs under an MSYS2 bash (make, perl, nasm) inside a VS developer
# environment (msbuild), which is what GitHub's windows runner has and what
# `ci/windows/provision.ps1` in the consuming project installs on a Windows CI box. A MinGW
# `libvpx.a` would be the easier build and the wrong artifact: its objects reach into
# libgcc and the MinGW CRT, which an MSVC link of a Rust binary does not carry.
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
# The archive's name follows the platform's convention — and, for the MSVC build, rustc's:
# `static=vpx` on that target resolves to `vpx.lib`, never to `libvpx.a`.
lib_name=libvpx.a
# Set for the MSVC target, whose build and collect steps are not make's.
msvs=0
# A path as a native Windows program reads it — `C:/…` under MSYS2, where llvm-nm, llvm-readobj
# and msbuild are native executables and get the archive's path spelled for them rather than
# through MSYS2's argument conversion, which the msbuild call below turns off for its `-p:`
# options. Identity everywhere else.
np() { if [ "$msvs" = 1 ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

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
    # **No CPU floor, deliberately.**
    #
    # Naming one — `-march=x86-64-v3`, a Coffee Lake target, anything — would be a mistake here,
    # and the reason is in libvpx's own build rather than in an opinion about floors. Its AVX2
    # and SSE kernels are hand-written assembly and intrinsics, and `build/make/Makefile` gives
    # each of them its own flag (`%_avx2.c.o: CFLAGS += -mavx2`) no matter what the global
    # CFLAGS say; which one runs is then decided by cpuid at run time, through the function
    # pointers rtcd.pl generates and `x86_simd_caps()` in vpx_ports/x86.h. Runtime detection is
    # not something this configure line asks for — configure `soft_enable`s it for x86 itself,
    # and the resulting vpx_config.h carries CONFIG_RUNTIME_CPU_DETECT 1.
    #
    # So a floor cannot decide whether the kernels are compiled or whether they are called. All
    # it could do is autovectorize the C fallbacks that exist for machines without those
    # kernels — and cost the archive every pre-AVX2 machine in exchange. The verification below
    # asserts the AVX2 kernels are in the archive, which is the property that actually matters.
    floor='x86-64 baseline (runtime CPU detection: sse2..avx2 kernels dispatched at run time)'
    arflags=(ARFLAGS=-crsD)
    ;;
  linux-aarch64)
    configure_args+=(--target=arm64-linux-gcc)
    # Same argument as macos-arm64, and NEON is mandatory in ARMv8-A anyway.
    floor='armv8-a (runtime CPU detection: neon/dotprod/i8mm/sve dispatched at run time)'
    arflags=(ARFLAGS=-crsD)
    ;;
  windows-x86_64-msvc)
    # `vs17` is the newest toolset family libvpx 1.16's configure knows (VS 2022's v143); the
    # VS 2026 build tools open the generated project as their own, which is what msbuild is
    # asked to do below. The same runtime CPU detection as linux-x86_64 — configure
    # `soft_enable`s it for x86 whatever the generator — so the floor is the same too.
    configure_args+=(--target=x86_64-win64-vs17)
    # **No `--enable-static-msvcrt`.** Rust's MSVC targets link the dynamic CRT, and an archive
    # built against the static one fails the final link with the mismatch that costs an
    # afternoon. The generator names the archive after this choice — `vpxmd.lib`, `md` for
    # the dynamic CRT — and the collect step reads that name as evidence before renaming.
    floor='x86-64 baseline (runtime CPU detection: sse2..avx2 kernels dispatched at run time)'
    lib_name=vpx.lib
    msvs=1
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
if [ "$target" = "linux-x86_64" ] || [ "$target" = "windows-x86_64-msvc" ]; then
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
# build from the source tree — so there is no `SOURCE_DATE_EPOCH` dance to do here.
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

jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
mkdir -p "$out/lib"
if [ "$msvs" = 1 ]; then
  # The MSVC path, as vcpkg's libvpx port drives it. `make dist` is where the generator runs:
  # it writes `vpx.vcxproj` (via build/make/gen_msvs_vcxproj.sh) and a dist tree holding the
  # public headers, and compiles nothing. msbuild then does what make does elsewhere.
  echo ">> generating the Visual Studio project"
  make -C "build/$target" dist
  project="$(find "build/$target" -maxdepth 1 -name vpx.vcxproj)"
  [ -n "$project" ] || { echo "make dist wrote no vpx.vcxproj under build/$target" >&2; exit 1; }
  echo ">> building with msbuild"
  command -v msbuild.exe >/dev/null 2>&1 || {
    echo "msbuild.exe is not on PATH — run this from a VS developer environment" >&2
    exit 1
  }
  # The toolset is the *installed* one, not the one the generator wrote. libvpx's `vs17` target
  # stamps `<PlatformToolset>v143</PlatformToolset>` — Visual Studio 2022's — into the project,
  # and msbuild refuses to build it on a machine whose Build Tools are a later release (measured:
  # MSB8020 on VS 2026, whose toolset is v145). Read off msbuild's own VC directory: the one
  # `PlatformToolsets` entry for x64 is what this machine can build with, and on a machine with
  # several the newest is the one the developer environment put on PATH.
  # Walked up from msbuild.exe rather than a fixed number of `..`: it sits in `MSBuild/Current/Bin`
  # or `MSBuild/Current/Bin/amd64` depending on the developer environment's host architecture,
  # and `MSBuild/Microsoft/VC` is the first ancestor's child of that name either way.
  msbuild_vc="$(dirname "$(cygpath -u "$(command -v msbuild.exe)")")"
  while [ "$msbuild_vc" != / ] && [ ! -d "$msbuild_vc/Microsoft/VC" ]; do
    msbuild_vc="$(dirname "$msbuild_vc")"
  done
  msbuild_vc="$msbuild_vc/Microsoft/VC"
  toolset="$(find "$msbuild_vc" -mindepth 5 -maxdepth 5 -type d -path '*/Platforms/x64/PlatformToolsets/v[0-9]*' \
    -printf '%f\n' | sort -V | tail -1)"
  [ -n "$toolset" ] || {
    echo "no x64 platform toolset under $msbuild_vc — is this a VS developer environment?" >&2
    exit 1
  }
  echo "   platform toolset $toolset"
  # **Whole-program optimisation off, and this is the most important option on the line.** The
  # generated project's Release configuration says `<WholeProgramOptimization>true</…>`, which is
  # `/GL`: every member of the resulting archive is then an *anonymous object* — an LTCG blob
  # (magic `00 00 ff ff`) that only the exact MSVC linker that produced it can read. Measured:
  # llvm-nm listed symbols for the 21 nasm-built members and nothing for the 131 compiled ones,
  # so every entry-point check below would have failed, and a consumer on a different MSVC would
  # have failed at link time with LNK1257. It is the same trap FreeRDP's cmake sets with IPO,
  # asserted the same way below: real object code, or no archive.
  #
  # Conversion off for this one call: every argument is an option, none is a path.
  (cd "build/$target" && MSYS2_ARG_CONV_EXCL='*' msbuild.exe vpx.vcxproj -nologo -m:"$jobs" -v:minimal \
    -p:Configuration=Release -p:Platform=x64 -p:PlatformToolset="$toolset" \
    -p:WholeProgramOptimization=false)

  # ---------------------------------------------------------------- collect (MSVC)

  # Exactly one Release archive, and its name is the CRT evidence: `vpxmd.lib` is what the
  # generator writes for the dynamic CRT, `vpxmt.lib` for the static one that must not be here.
  built="$(find "build/$target" -type f -name 'vpx*.lib' -path '*Release*')"
  [ "$(printf '%s\n' "$built" | grep -c .)" -eq 1 ] || {
    echo "expected exactly one Release vpx*.lib under build/$target, found:" >&2
    printf '  %s\n' "$built" >&2
    exit 1
  }
  [ "$(basename "$built")" = "vpxmd.lib" ] || {
    echo "the archive is $(basename "$built"), not vpxmd.lib — this is not a dynamic-CRT build" >&2
    exit 1
  }
  cp "$built" "$out/lib/$lib_name"
  # The dist tree's `include/vpx` is what `make install` produces on the other targets: the
  # whole public header set, decided by libvpx's own build (see the note below).
  installed="$(find "build/$target" -type d -path '*/include/vpx')"
  [ "$(printf '%s\n' "$installed" | grep -c .)" -eq 1 ] || {
    echo "expected exactly one include/vpx under build/$target's dist tree, found:" >&2
    printf '  %s\n' "$installed" >&2
    exit 1
  }
  mkdir -p "$out/include"
  cp -R "$installed" "$out/include/vpx"
else
  echo ">> building"
  make -C "build/$target" -j"$jobs" "${arflags[@]+"${arflags[@]}"}"
  make -C "build/$target" install >/dev/null

  # ---------------------------------------------------------------- collect

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
fi
# libvpx's own licence and Google's patent grant, from the same verified checkout. Both travel
# with the archive rather than being left behind in the source tree: whoever links this
# redistributes libvpx, and BSD-3-Clause requires the notice to go with it.
cp "$src/LICENSE" "$src/PATENTS" "$out/include/"

# ---------------------------------------------------------------- verify

if [ "$msvs" = 1 ]; then
  echo ">> verifying the archive holds object code, not LTCG blobs"
  # Every member, not a sample: `/GL` is per translation unit and the asm members never had it,
  # so the first member proves nothing. llvm-readobj prints one `Format:` line per object it
  # can parse and an error per one it cannot; the count has to match the member count and the
  # error stream has to be empty.
  members="$(llvm-ar t "$(np "$out/lib/$lib_name")" | wc -l | tr -d ' ')"
  headers="$(llvm-readobj --file-headers "$(np "$out/lib/$lib_name")" 2>"build/$target/readobj.err" | grep -c '^Format: COFF-x86-64$' || true)"
  if [ -s "build/$target/readobj.err" ] || [ "$headers" != "$members" ]; then
    echo "$lib_name: $headers of $members members are x86-64 COFF objects — the rest are not" >&2
    echo "  object files (an LTCG '/GL' build writes anonymous objects only its own linker reads)." >&2
    head -3 "build/$target/readobj.err" >&2 || true
    exit 1
  fi
  rm -f "build/$target/readobj.err"
  echo "   $members members, all COFF-x86-64"
fi

echo ">> verifying the entry points are in the archive"
# The functions the crates above actually call. An archive that configured itself down to the
# decoder only, or that landed under the right name with the wrong contents, fails here rather
# than at the link step of every consumer.
entry_points='vpx_codec_vp9_cx vpx_codec_vp9_dx vpx_codec_enc_init_ver
              vpx_codec_enc_config_default vpx_codec_enc_config_set vpx_codec_encode
              vpx_codec_get_cx_data vpx_codec_control_ vpx_codec_destroy
              vpx_codec_dec_init_ver vpx_codec_decode vpx_codec_get_frame
              vpx_img_wrap vpx_img_free vpx_codec_version_str vpx_codec_error_detail'

# Which nm. GNU or Apple nm read their own platform's archives; a COFF `.lib` is read by
# llvm-nm, which the LLVM installer puts on PATH on Windows and which prints the same shape
# of listing. Either way the member headers (`name.o:` lines) are dropped so a symbol list is
# only symbols.
case "$target" in
  windows-*)
    command -v llvm-nm >/dev/null 2>&1 || {
      echo "llvm-nm is not on PATH — install LLVM and put its bin directory on PATH" >&2
      exit 1
    }
    nm_tool=llvm-nm
    ;;
  *) nm_tool="nm" ;;
esac
list_symbols() {
  # $1: --defined-only or --undefined-only
  "$nm_tool" "$1" "$(np "$out/lib/$lib_name")" | grep -v ':$'
}

# No `2>/dev/null || true` on this: an nm that cannot read the archive would produce an empty
# symbol list, and an empty symbol list makes every check below report a *missing* entry point.
# That is a measurement failure wearing the costume of a build failure, so it stops here and
# nm's own complaint is left on stderr to say why.
symbols="$(list_symbols --defined-only)" || {
  echo "$nm_tool could not read $out/lib/$lib_name — nothing below was measured" >&2
  exit 1
}
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
# A number recorded in the MANIFEST and asserted against nothing would be decoration. libvpx
# ships hundreds of hand-written kernels, selected at run time, and losing them is the
# difference between real-time 1080p and not. On x86_64 they are also exactly what goes missing
# when the assembler is absent, which is a thing that happens.
echo ">> verifying the SIMD kernels are in the archive"
case "$target" in
  # The same pattern on both: x64 COFF does not prefix C symbols with an underscore, so
  # `vpx_…_avx2` reads the same in a `.lib` as in an ELF `.a`.
  linux-x86_64 | windows-x86_64-msvc)
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
# Again with nm's failure kept loud, and for a sharper reason than above: "no undefined libm
# symbols" is a *legitimate* answer that goes into the MANIFEST as `libm none`, and build.rs
# then emits no `-lm`. An nm that failed silently produces the same empty list, so a masked
# error here does not fail the build — it ships a MANIFEST that says the archive needs nothing.
undefined_raw="$(list_symbols --undefined-only)" || {
  echo "$nm_tool could not read $out/lib/$lib_name — the runtime requirements were not measured" >&2
  exit 1
}
undefined="$(awk '{print $NF}' <<<"$undefined_raw" | sort -u)"

# The greps below are the one place where "found nothing" is an answer rather than a fault, so
# they accept exit 1 and nothing else: exit 2 is grep saying it could not do the search, which
# is indistinguishable from a match-free archive if it is thrown away.
#
# libm. libvpx's VP9 rate control uses pow, log and exp, so this is expected to be `required`
# — and it is what makes the difference between a Linux consumer linking `-lm` and a page of
# undefined symbols. On macOS libm is part of libSystem and no flag is needed, which is why
# build.rs reads this *and* the target.
status=0
libm_matches="$(grep -E '^_?(pow|exp|log|logf|log2|sqrt|floor|ceil|fabs|atan2?|sin|cos|round|fmod)$' \
  <<<"$undefined")" || status=$?
[ "$status" -le 1 ] || {
  echo "grep failed ($status) while measuring libm — the requirement is unknown, not absent" >&2
  exit 1
}
libm_symbols="$(tr '\n' ' ' <<<"$libm_matches" | sed 's/ *$//')"
case "$target" in
  windows-*)
    # The same three functions are undefined here too, and they are in the MSVC CRT that every
    # Rust binary on the target already links: there is no `m.lib`, and build.rs emits no
    # `-lm` for this target whatever this line says. `none` is the answer build.rs parses; the
    # measurement is kept beside it in the log.
    libm='none'
    echo "   libm: none — ${libm_symbols:-nothing} undefined, and in the CRT"
    ;;
  *)
    if [ -z "$libm_symbols" ]; then
      libm='none'
      echo "   libm: none"
    else
      libm="required: $libm_symbols"
      echo "   libm: $libm_symbols"
    fi
    ;;
esac

# The C++ runtime. libvpx is C, and its one C++ file (`vp9/ratectrl_rtc.cc`) goes into a
# *separate* `libvpxrc.a` that `make install` does not install — so the answer should be
# `none`, which is a property worth keeping rather than assuming.
# MSVC mangles differently: `??2@YA…` is operator new, `?…@std@@` anything in namespace std,
# and the exception machinery is `__CxxFrameHandler`/`_CxxThrowException`.
case "$target" in
  windows-*) cxx_pattern='^(\?\?[23]@YA|\?.*@std@@|__CxxFrameHandler|_CxxThrowException)' ;;
  *) cxx_pattern='^_?(_Zn[wa]|_Zd[la]|_ZN?St|__cxa_|__gxx_personality|_Unwind_)' ;;
esac
status=0
cxx_undefined="$(grep -E "$cxx_pattern" <<<"$undefined")" || status=$?
[ "$status" -le 1 ] || {
  echo "grep failed ($status) while measuring the C++ runtime — unknown, not absent" >&2
  exit 1
}
if [ -z "$cxx_undefined" ]; then
  cxx_runtime='none'
  echo "   cxx_runtime: none — the archive needs no libstdc++/libc++"
else
  cxx_runtime="required: $(printf '%s' "$cxx_undefined" | tr '\n' ' ' | sed 's/ $//')"
  echo "   cxx_runtime: $cxx_runtime"
fi

# The CRT, read back off the archive rather than trusted from the flag. Every MSVC object
# records the CRT it was compiled against as a `/DEFAULTLIB` directive, and `llvm-readobj`
# prints them: `MSVCRT` is the dynamic one Rust links, `LIBCMT` the static one that would fail
# the consumer's link. The archive name above already said `md`; this is the object saying it.
crt='n/a'
if [ "$msvs" = 1 ]; then
  echo ">> verifying the CRT the objects name"
  command -v llvm-readobj >/dev/null 2>&1 || {
    echo "llvm-readobj is not on PATH — install LLVM to measure the CRT directives" >&2
    exit 1
  }
  directives="$(llvm-readobj --coff-directives "$(np "$out/lib/$lib_name")" | grep -io 'DEFAULTLIB:"[A-Za-z0-9_]*"' | sort -u)"
  grep -qi 'DEFAULTLIB:"MSVCRT"' <<<"$directives" || {
    echo "no /DEFAULTLIB:MSVCRT directive in $lib_name — the objects do not name the dynamic CRT" >&2
    printf '  %s\n' "$directives" >&2
    exit 1
  }
  if grep -qi 'DEFAULTLIB:"LIBCMT' <<<"$directives"; then
    echo "a /DEFAULTLIB:LIBCMT directive is in $lib_name — some object was built against the static CRT" >&2
    printf '  %s\n' "$directives" >&2
    exit 1
  fi
  crt='dynamic (MSVCRT)'
  echo "   $crt, and no LIBCMT"
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
  echo "crt $crt"
  echo "simd_evidence $simd_evidence"
  echo "configure_args ${configure_args[*]}"
} > "$out/MANIFEST"

echo ">> wrote $out"
cat "$out/MANIFEST"
