#!/usr/bin/env bash
# Assert that a binary carries libvpx inside it rather than expecting to find one.
#
#   ./check-static.sh target/release/libvpx-e2e
#
# Three questions, and they fail in different directions:
#
#   positive — is libvpx actually *in* there? libvpx compiles its own version string in, so
#             finding `v1.16.0` in the file's bytes says yes, and says *which* — a stronger
#             answer than grepping for a symbol or a module name, neither of which tells one
#             build of a library from another.
#   negative — is there a *dynamic* dependency on libvpx as well or instead? This is the one
#             that passes every test on the build machine and then fails on a slim runtime image
#             or a machine without Homebrew, which is precisely the failure this repository
#             exists to remove.
#   the C++ runtime — build.sh measures whether the archive needs one and records the answer in
#             the MANIFEST. libvpx is C, and its one C++ file goes into a separate library that
#             `make install` does not install, so the answer is `none` — a property worth
#             keeping. When the MANIFEST says so, this requires the finished binary to have no
#             libstdc++/libc++ dependency either.
#
# Run in CI on every target. A binary that links a system libvpx by accident behaves identically
# to a correct one until it is copied somewhere else.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bin="${1:?usage: ./check-static.sh <binary>}"
[ -f "$bin" ] || { echo "no such file: $bin" >&2; exit 1; }

# shellcheck source=libvpx.env
. "$here/libvpx.env"

fail=0

echo ">> $bin"

# `grep -a`: treat the executable as text, which is portable in a way `nm` and `strings` are not.
if grep -aq "v${LIBVPX_VERSION}" "$bin"; then
  echo "   ok    libvpx v${LIBVPX_VERSION}'s version string is compiled in"
else
  echo "   FAIL  no 'v${LIBVPX_VERSION}' string in the binary — is libvpx really linked, and is" >&2
  echo "         it the pinned version?" >&2
  fail=1
fi

case "$(uname -s)" in
  Darwin) deps="$(otool -L "$bin" | tail -n +2 || true)" ;;
  MINGW* | MSYS* | CYGWIN*)
    # Windows, under an MSYS bash. `dumpbin /dependents` needs an MSVC environment this
    # script does not set up, so the PE import table is read the crude way: a DLL a binary
    # imports has its name stored, in ASCII, in the file. Enough to catch an accidental
    # `vpx.dll` import — the mistake being looked for — and to see the C++ runtime's
    # `msvcp140.dll` below.
    deps="$(grep -aoiE '[a-z0-9_.-]+\.dll' "$bin" | sort -u || true)"
    ;;
  *)      deps="$(ldd "$bin" 2>/dev/null || true)" ;;
esac

if vpx_deps="$(printf '%s\n' "$deps" | grep -iE 'libvpx|(^|[^a-z])vpx(md|mt)?\.dll')" && [ -n "$vpx_deps" ]; then
  echo "   FAIL  dynamic dependency on libvpx:" >&2
  printf '           %s\n' "$vpx_deps" >&2
  fail=1
else
  echo "   ok    no dynamic libvpx dependency"
fi

# What did build.sh measure for this target? Looked up rather than assumed, and skipped rather
# than guessed when there is no MANIFEST to read — a check that invents its own expectation is
# worse than one that says it did not run. **This** machine's target, by name: a tree copied to
# a build box carries whatever other targets' caches were in it, and taking the last MANIFEST
# found reported another target's measurement (libde265-prebuilt's arm64 run read x86_64's).
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host_target=macos-arm64 ;;
  Linux-x86_64) host_target=linux-x86_64 ;;
  Linux-aarch64 | Linux-arm64) host_target=linux-aarch64 ;;
  MINGW*-x86_64 | MSYS*-x86_64 | CYGWIN*-x86_64) host_target=windows-x86_64-msvc ;;
  *) host_target=unknown ;;
esac
manifest=""
for candidate in "$here/dist/$host_target/MANIFEST" \
                 "$here/crates/libvpx-prebuilt-sys/prebuilt/$host_target/MANIFEST"; do
  if [ -f "$candidate" ]; then
    manifest="$candidate"
    break
  fi
done

if [ -n "$manifest" ]; then
  cxx_runtime="$(sed -n 's/^cxx_runtime //p' "$manifest")"
  echo "   note  $(basename "$(dirname "$manifest")") MANIFEST says cxx_runtime: ${cxx_runtime:-<absent>}"
  if [ "$cxx_runtime" = "none" ]; then
    # `msvcp140.dll` is MSVC's C++ standard library; `vcruntime140.dll` beside it is the C
    # runtime every /MD binary imports and is not evidence of C++.
    if cxx_deps="$(printf '%s\n' "$deps" | grep -iE 'libstdc\+\+|libc\+\+|msvcp[0-9]+')" && [ -n "$cxx_deps" ]; then
      echo "   FAIL  the archive needs no C++ runtime, but the binary links one:" >&2
      printf '           %s\n' "$cxx_deps" >&2
      echo "         Nothing in this repository should emit -lstdc++/-lc++; check whether" >&2
      echo "         libvpxrc.a (libvpx's one C++ file) got into the artifact." >&2
      fail=1
    else
      echo "   ok    no C++ runtime dependency, as the measurement predicted"
    fi
  fi
else
  echo "   note  no MANIFEST found — skipping the C++ runtime check"
fi

exit "$fail"
