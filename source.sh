# shellcheck shell=bash
# Fetch, verify and check out the pinned libvpx source. Sourced, not run — by build.sh, which
# compiles it, and by sync-prebuilt.sh, which takes the headers out of it.
#
# One copy of this rather than two, because it is where the repository's central promise lives:
# the commit is asserted *before* anything is compiled, so a tree that is not the pinned one
# never reaches a compiler, a header directory, or an artifact other projects link. Two
# implementations of that rule is one too many.

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Leaves the checkout at build/libvpx-$LIBVPX_VERSION and echoes nothing; callers use that path
# directly. Idempotent: an existing checkout at the pinned commit is reused. One sitting at any
# other commit is *not* moved onto the pin — it fails with the commit mismatch below and has to
# be deleted — and a tree someone poked at by hand is reported rather than built.
ensure_source() {
  local src="build/libvpx-${LIBVPX_VERSION}"

  mkdir -p build
  if [ ! -d "$src/.git" ]; then
    echo ">> cloning libvpx v${LIBVPX_VERSION}"
    rm -rf "$src"
    # `--depth 1 --branch` fetches one commit and its tree rather than twenty years of
    # history, which is 30 MB instead of 500. The tag is only how the commit is *found*; the
    # assertion below is what decides whether it was the right one, so a tag moved upstream
    # fails here rather than shipping.
    git clone --quiet --depth 1 --branch "v${LIBVPX_VERSION}" "$LIBVPX_REPO" "$src"
  fi

  echo ">> verifying the checkout is ${LIBVPX_COMMIT}"
  local actual
  actual="$(git -C "$src" rev-parse HEAD)"
  [ "$actual" = "$LIBVPX_COMMIT" ] || {
    echo "commit mismatch in $src" >&2
    echo "  expected $LIBVPX_COMMIT" >&2
    echo "  actual   $actual" >&2
    echo "  (delete $src to re-clone, or fix LIBVPX_COMMIT in libvpx.env)" >&2
    return 1
  }

  # A dirty tree is refused rather than cleaned. Cleaning would silently discard work someone
  # is in the middle of; refusing says what is wrong and leaves it to them. The commit
  # assertion above says nothing about uncommitted edits, so without this the pin is
  # checkable and the *build* still is not.
  if [ -n "$(git -C "$src" status --porcelain)" ]; then
    echo "$src has local modifications — the pinned commit is not what would be built" >&2
    git -C "$src" status --short >&2
    return 1
  fi
}
