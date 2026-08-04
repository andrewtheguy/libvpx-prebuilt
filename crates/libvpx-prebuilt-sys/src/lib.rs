//! Raw FFI for libvpx's VP9 encoder and decoder, linked from a prebuilt static archive.
//!
//! This crate builds no C. Compare RustDesk's `scrap`, which needs vcpkg to have installed
//! libvpx *and* bindgen with libclang present before it will compile at all; here `build.rs`
//! finds an archive that was already built — by `./build.sh` locally, or by this repository's
//! release pipeline — verifies it against its own MANIFEST, and emits the link flags. A
//! consumer needs no assembler, no configure shell, no cmake and no LLVM.
//!
//! Everything public comes from [`bindings`], which is bindgen's output over the eleven headers
//! committed in `include/vpx/` and re-exported at the crate root, so `vpx_sys::vpx_codec_vp9_cx`
//! reads the way the C does.
//!
//! # Which library is linked
//!
//! [`version`] returns what the archive itself reports. libvpx compiles its own version string
//! in, so there is nothing to transcribe by hand and nothing to keep in step: asking the
//! library is how a consumer checks it is talking to the libvpx this crate was generated
//! against rather than to a system one that won the link.
//!
//! # What is in the archive, and what is not
//!
//! VP9 encoder and decoder. **No VP8** — `build.sh` configures it out and then asserts
//! `vpx_codec_vp8_cx` is absent — and no two-pass or non-realtime rate control, because
//! `--enable-realtime-only` drops it. A project that wants either needs its own build, which
//! `LIBVPX_PREBUILT_DIR` is for.
//!
//! # Safety
//!
//! Nothing here is safe. `vpx_codec_ctx_t` is initialised by an out-parameter and must be
//! destroyed exactly once, `vpx_codec_get_cx_data` returns a pointer into the encoder that the
//! next `vpx_codec_encode` invalidates, `vpx_img_wrap` borrows a caller's buffer without
//! owning it, and `vpx_codec_control_` is variadic and unchecked — passing the wrong argument
//! type for a control id is undefined behaviour that compiles.
//!
//! One consequence worth stating because it is easy to get wrong: an image built by
//! `vpx_img_wrap` over your own buffer must **not** be passed to `vpx_img_free`, which would
//! free memory the wrapper never allocated.

// bindgen's own header already carries the allow attributes these names need.
mod bindings;

pub use bindings::*;

/// What the linked libvpx says it is, e.g. `v1.16.0`.
///
/// Reads `vpx_codec_version_str()`, which libvpx compiles in from its own source tree. The
/// version this crate's bindings were generated against is
/// [`PREBUILT_VERSION`] — comparing the two is how a consumer notices it is linked against
/// something other than the archive this repository publishes.
pub fn version() -> &'static str {
    // SAFETY: `vpx_codec_version_str` takes no arguments, cannot fail, and returns a pointer to
    // a static string constant compiled into the library — so the lifetime is genuinely
    // 'static and there is nothing to free.
    let ptr = unsafe { vpx_codec_version_str() };
    assert!(!ptr.is_null(), "vpx_codec_version_str returned null");
    // SAFETY: as above — a NUL-terminated string constant in the archive's read-only data.
    unsafe { std::ffi::CStr::from_ptr(ptr) }.to_str().expect("libvpx's version string is ASCII")
}

/// The libvpx version this crate's bindings and archives are built from, from `libvpx.env`.
pub const PREBUILT_VERSION: &str = env!("LIBVPX_PREBUILT_VERSION");
