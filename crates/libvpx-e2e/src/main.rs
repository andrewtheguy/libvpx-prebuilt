//! Encode synthetic screen content with the prebuilt libvpx, then decode it back.
//!
//! Run by the pipeline on every target, and the reason it exists is that "the archive links" is
//! a much weaker claim than "the archive encodes a bitstream another part of libvpx can decode".
//! A `cargo test` that only builds proves the symbols resolved; this proves the codec runs, on
//! the CPU the artifact was built for, with the exact configuration the consumers use.
//!
//! What it checks, in order:
//!
//!   1. the linked library reports the version this repository pins;
//!   2. the first frame is a keyframe, and later frames are not;
//!   3. `VPX_EFLAG_FORCE_KF` produces one on demand;
//!   4. a coarser quantizer really is a smaller stream — which is what says the dial reaches
//!      the encoder at all under `--enable-realtime-only` + `VPX_Q`, the one combination this
//!      repository's configure line makes unusual;
//!   5. `vpx_codec_enc_config_set` moves the quantizer mid-stream **without** spending a
//!      keyframe, which is the mechanism a congestion loop needs;
//!   6. one encode yields exactly one packet, which is what `g_lag_in_frames = 0` buys and
//!      what a consumer that assumes it would otherwise discover as latency;
//!   7. the decoder gets the frames back at the right size and close to the right pixels.
//!
//! Nothing here is a benchmark. Timings are printed because they are free and occasionally
//! diagnostic, not because a CI runner's wall clock is a fact about the codec.

use std::ffi::CStr;
use std::os::raw::{c_int, c_uint};

use vpx_sys::*;

/// The picture. Small enough that a CI runner encodes 30 frames instantly, large enough that
/// the encoder has real superblocks to work with rather than one partition.
const W: u32 = 640;
const H: u32 = 480;
/// Frames per pass. Enough that "the first is a keyframe and the rest are not" is a statement
/// about a stream rather than about two frames.
const FRAMES: u32 = 30;
/// The quantizer the fine pass uses, and the one the coarse pass uses. VP9's range is 0..63,
/// coarsest last.
const Q_FINE: u32 = 8;
const Q_COARSE: u32 = 56;

fn main() {
    println!("libvpx-e2e: {} (pinned {})", vpx_sys::version(), vpx_sys::PREBUILT_VERSION);
    assert_eq!(
        vpx_sys::version().trim_start_matches('v'),
        vpx_sys::PREBUILT_VERSION,
        "the linked libvpx is not the version this repository pins — something else won the link"
    );

    let fine = pass(Q_FINE);
    let coarse = pass(Q_COARSE);

    println!();
    println!("| pass   |  q | bytes  | keyframes | packets | µs/frame | decoded MAE |");
    println!("|--------|----|--------|-----------|---------|----------|-------------|");
    for p in [&fine, &coarse] {
        println!(
            "| {:6} | {:2} | {:6} | {:9} | {:7} | {:8} | {:11.2} |",
            p.name, p.q, p.bytes, p.keyframes, p.packets, p.micros_per_frame, p.mae
        );
    }
    println!();

    // (4) The dial reaches the encoder. This is the assertion that matters most, because
    // `--enable-realtime-only` compiles out libvpx's non-realtime rate control and `VPX_Q` is
    // not the mode a realtime build is usually driven in: if the quantizer were being ignored,
    // both passes would come out the same size and everything else here would still pass.
    // A ratio rather than a number, and a modest one: the picture below is *deliberately* very
    // compressible, so even q 8 against q 56 is only about 2.3× on this content. Requiring
    // "clearly smaller" separates a dial that works from one that is ignored without also
    // asserting a compression ratio nothing guarantees.
    assert!(
        coarse.bytes * 3 < fine.bytes * 2,
        "q {Q_COARSE} encoded {} bytes against q {Q_FINE}'s {} — the quantizer is not reaching \
         the encoder",
        coarse.bytes,
        fine.bytes
    );

    // (7) And the fine pass is genuinely a picture of the input, not merely bytes that decode.
    assert!(
        fine.mae < 4.0,
        "the fine pass decoded to a mean absolute error of {:.2} — that is not the picture that \
         went in",
        fine.mae
    );
    assert!(
        coarse.mae > fine.mae,
        "the coarse pass decoded closer to the source ({:.2}) than the fine one ({:.2})",
        coarse.mae,
        fine.mae
    );

    println!("ok: {} frames each way, encoded and decoded, on {}", FRAMES, std::env::consts::ARCH);
}

struct Pass {
    name: &'static str,
    q: u32,
    bytes: usize,
    keyframes: usize,
    packets: usize,
    micros_per_frame: u128,
    mae: f64,
}

/// Encode `FRAMES` frames of moving screen content at `q`, decoding every packet as it comes.
fn pass(q: u32) -> Pass {
    let mut enc = Encoder::new(q);
    let mut dec = Decoder::new();

    let mut bytes = 0usize;
    let mut keyframes = 0usize;
    let mut packets = 0usize;
    let mut mae = 0.0f64;
    let mut source = Frame::new();
    let started = std::time::Instant::now();

    for frame in 0..FRAMES {
        source.draw(frame);

        // (3) A keyframe on demand, in the middle of the stream. Asked for once, so the
        // assertions below can tell "the encoder does what it is told" from "the encoder emits
        // keyframes whenever it likes".
        let force = frame == FRAMES / 2;
        // (5) And the quantizer moved on a live encoder, right after that, so the no-keyframe
        // claim is tested against the frames that follow rather than against the one that
        // asked for an IDR.
        if frame == FRAMES / 2 + 1 {
            enc.set_quantizer(q.saturating_add(4).min(63));
        }

        let produced = enc.encode(&source, force);
        assert_eq!(
            produced.len(),
            1,
            "frame {frame} produced {} packets, not one — g_lag_in_frames is not 0",
            produced.len()
        );
        for (data, keyframe) in &produced {
            packets += 1;
            bytes += data.len();
            if *keyframe {
                keyframes += 1;
            }
            assert!(
                (frame == 0 || frame == FRAMES / 2) == *keyframe,
                "frame {frame} keyframe={keyframe}: a keyframe happened where none was asked \
                 for, or an asked-for one did not"
            );
            mae = dec.decode(data, &source);
        }
    }
    let micros_per_frame = started.elapsed().as_micros() / u128::from(FRAMES);

    // (2) Exactly the two that were asked for: the stream's first, and the forced one.
    assert_eq!(
        keyframes, 2,
        "expected 2 keyframes (the first and the forced one), got {keyframes}"
    );

    Pass {
        name: if q <= 32 { "fine" } else { "coarse" },
        q,
        bytes,
        keyframes,
        packets,
        micros_per_frame,
        mae,
    }
}

/// One I420 picture, written straight into planes rather than converted from RGB.
///
/// Deliberately not an RGB→I420 conversion: this repository ships a codec, and whose converter
/// a consumer uses is not its business. Synthetic *screen* content rather than a gradient or
/// noise — flat panels, hard edges, text-like runs and one moving window — because that is what
/// `VP9E_CONTENT_SCREEN` below is tuned for, and because a stream of noise compresses like
/// noise at every quantizer and would make check (4) a coin toss.
struct Frame {
    y: Vec<u8>,
    u: Vec<u8>,
    v: Vec<u8>,
}

impl Frame {
    fn new() -> Self {
        let (w, h) = (W as usize, H as usize);
        Self { y: vec![0; w * h], u: vec![128; w * h / 4], v: vec![128; w * h / 4] }
    }

    fn draw(&mut self, frame: u32) {
        let (w, h) = (W as usize, H as usize);
        // A dark desktop.
        self.y.fill(24);
        // A light panel with a hard edge, two thirds of the way across.
        for row in 0..h {
            let at = row * w;
            self.y[at + w * 2 / 3..at + w].fill(200);
        }
        // Text-like runs: short dark bars on the panel, unchanging, so most of the picture is
        // something the encoder should stop spending bits on after the first frame.
        for line in 0..20 {
            let row = 24 + line * 20;
            if row >= h {
                break;
            }
            for glyph in 0..14 {
                let x = w * 2 / 3 + 8 + glyph * 12;
                if x + 7 >= w {
                    break;
                }
                for dy in 0..9 {
                    let at = (row + dy) * w + x;
                    self.y[at..at + 7].fill(32);
                }
            }
        }
        // And one window being dragged across the dark side, which is the only thing that moves.
        let x0 = 8 + (frame as usize * 9) % (w / 2);
        let y0 = 40 + (frame as usize * 5) % (h / 2);
        for dy in 0..120 {
            let row = y0 + dy;
            if row >= h {
                break;
            }
            let at = row * w + x0;
            let width = 160.min(w - x0);
            self.y[at..at + width].fill(if dy < 24 { 96 } else { 144 });
        }
    }
}

/// The encoder, configured exactly as a consumer streaming a desktop should be.
struct Encoder {
    ctx: vpx_codec_ctx_t,
    cfg: vpx_codec_enc_cfg_t,
    img: vpx_image_t,
    pts: i64,
}

impl Encoder {
    fn new(q: u32) -> Self {
        // SAFETY: every call below is checked, and `ctx`/`cfg`/`img` are zeroed before libvpx
        // is given a pointer to them — `vpx_codec_enc_config_default` and `vpx_codec_enc_init_ver`
        // both write through the pointer rather than reading it, and a partially initialised
        // `cfg` is what would be read if the default call failed and was ignored.
        unsafe {
            let iface = vpx_codec_vp9_cx();
            assert!(
                !iface.is_null(),
                "vpx_codec_vp9_cx() is null — this libvpx has no VP9 encoder"
            );

            let mut cfg: vpx_codec_enc_cfg_t = std::mem::zeroed();
            check(vpx_codec_enc_config_default(iface, &mut cfg, 0), "enc_config_default");

            cfg.g_w = W;
            cfg.g_h = H;
            // Milliseconds, so a pts is a wall-clock timestamp rather than a frame index.
            cfg.g_timebase.num = 1;
            cfg.g_timebase.den = 1000;
            // **0, not libvpx's default of 25.** The default holds 25 frames inside the encoder
            // before emitting anything, which for a desktop is most of a second of latency and
            // makes the one-packet-per-encode assertion above false. RustDesk works around the
            // default by flushing after every frame; setting it to zero is the same thing
            // without the second code path.
            cfg.g_lag_in_frames = 0;
            cfg.g_pass = vpx_enc_pass_VPX_RC_ONE_PASS;
            // No error resilience: the transports this is built for are reliable, and it costs
            // compression to protect against loss that cannot happen.
            cfg.g_error_resilient = 0;
            cfg.g_threads = 1;
            // No periodic keyframe. Every keyframe here is one somebody asked for.
            cfg.kf_mode = vpx_kf_mode_VPX_KF_DISABLED;
            // Constant quality, and the quantizer pinned top and bottom so the rate control has
            // nothing left to choose. `VPX_Q` plus `cq_level` decides it; min == max is what
            // makes that a guarantee rather than a preference.
            cfg.rc_end_usage = vpx_rc_mode_VPX_Q;
            cfg.rc_min_quantizer = q;
            cfg.rc_max_quantizer = q;
            // Zero, explicitly, because a dropped frame is not an option for a consumer whose
            // caller has already recorded those pixels as delivered. It is also libvpx's
            // default, and a default is a thing that can change.
            cfg.rc_dropframe_thresh = 0;
            // Likewise: an encoder that resized itself would change the picture size mid-stream,
            // and every consumer here has a fixed rectangle for the stream's whole life.
            cfg.rc_resize_allowed = 0;

            let mut ctx: vpx_codec_ctx_t = std::mem::zeroed();
            check(
                vpx_codec_enc_init_ver(&mut ctx, iface, &cfg, 0, VPX_ENCODER_ABI_VERSION as c_int),
                "enc_init_ver",
            );

            // In `VPX_Q` mode this is the value that actually decides the quantizer. It is a
            // *control*, not a config field, which is easy to get wrong from the outside.
            control(&mut ctx, vp8e_enc_control_id_VP8E_SET_CQ_LEVEL, q as c_int, "SET_CQ_LEVEL");
            // What the encoder is looking at: flat colour, hard edges and text.
            control(
                &mut ctx,
                vp8e_enc_control_id_VP9E_SET_TUNE_CONTENT,
                vp9e_tune_content_VP9E_CONTENT_SCREEN as c_int,
                "SET_TUNE_CONTENT",
            );
            // Speed. 5–8 is libvpx's own advice for live encoding; 7 is where RustDesk sits and
            // is the starting point a consumer should measure from rather than inherit.
            control(&mut ctx, vp8e_enc_control_id_VP8E_SET_CPUUSED, 7, "SET_CPUUSED");
            // Off: adaptive quantization would move the quantizer off the dial that was just
            // pinned.
            control(&mut ctx, vp8e_enc_control_id_VP9E_SET_AQ_MODE, 0, "SET_AQ_MODE");

            // An image that *wraps* a buffer rather than owning one. A non-null pointer that is
            // never dereferenced is libvpx's own idiom for "compute the layout, allocate
            // nothing" — ffmpeg's libvpxenc.c passes a literal `1` — and it is why
            // `vpx_img_free` must never be called on this image. The planes are replaced with
            // real ones on every encode below.
            let mut img: vpx_image_t = std::mem::zeroed();
            let wrapped = vpx_img_wrap(
                &mut img,
                vpx_img_fmt_VPX_IMG_FMT_I420,
                W,
                H,
                1,
                std::ptr::dangling_mut::<u8>(),
            );
            assert!(!wrapped.is_null(), "vpx_img_wrap failed");

            Self { ctx, cfg, img, pts: 0 }
        }
    }

    /// Move the quantizer on the live encoder. No keyframe: that is the whole point.
    fn set_quantizer(&mut self, q: u32) {
        self.cfg.rc_min_quantizer = q;
        self.cfg.rc_max_quantizer = q;
        // SAFETY: `cfg` is the same struct libvpx validated at init, mutated in two fields, and
        // `ctx` is live.
        unsafe {
            check(vpx_codec_enc_config_set(&mut self.ctx, &self.cfg), "enc_config_set");
            control(
                &mut self.ctx,
                vp8e_enc_control_id_VP8E_SET_CQ_LEVEL,
                q as c_int,
                "SET_CQ_LEVEL",
            );
        }
    }

    /// Encode one frame, returning every packet it produced and whether each is a keyframe.
    fn encode(&mut self, frame: &Frame, force_keyframe: bool) -> Vec<(Vec<u8>, bool)> {
        let flags = if force_keyframe { VPX_EFLAG_FORCE_KF as i64 } else { 0 };
        // SAFETY: the planes outlive the call — `frame` is borrowed for it — and the strides are
        // the ones `vpx_img_wrap` computed for this exact width and height. Casting away const
        // is required by the C API, which does not modify the input image.
        unsafe {
            self.img.planes[0] = frame.y.as_ptr() as *mut u8;
            self.img.planes[1] = frame.u.as_ptr() as *mut u8;
            self.img.planes[2] = frame.v.as_ptr() as *mut u8;
            self.img.stride[0] = W as c_int;
            self.img.stride[1] = (W / 2) as c_int;
            self.img.stride[2] = (W / 2) as c_int;

            check(
                vpx_codec_encode(
                    &mut self.ctx,
                    &self.img,
                    self.pts,
                    1,
                    flags,
                    // `c_ulong` here rather than a fixed width: the deadline argument is a
                    // `long`, which bindgen resolves to 32 bits on some targets and 64 on
                    // others.
                    VPX_DL_REALTIME as std::os::raw::c_ulong,
                ),
                "encode",
            );
            self.pts += 33;

            let mut out = Vec::new();
            let mut iter: vpx_codec_iter_t = std::ptr::null();
            loop {
                let pkt = vpx_codec_get_cx_data(&mut self.ctx, &mut iter);
                if pkt.is_null() {
                    break;
                }
                if (*pkt).kind != vpx_codec_cx_pkt_kind_VPX_CODEC_CX_FRAME_PKT {
                    continue;
                }
                let f = &(*pkt).data.frame;
                let data = std::slice::from_raw_parts(f.buf as *const u8, f.sz).to_vec();
                out.push((data, f.flags & VPX_FRAME_IS_KEY != 0));
            }
            out
        }
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        // SAFETY: destroyed exactly once, and `img` is a wrapper that owns nothing — freeing it
        // would free `Frame`'s planes.
        unsafe {
            vpx_codec_destroy(&mut self.ctx);
        }
    }
}

/// The decoder half, so the pipeline's claim is a round trip rather than a byte count.
struct Decoder {
    ctx: vpx_codec_ctx_t,
}

impl Decoder {
    fn new() -> Self {
        // SAFETY: as in `Encoder::new` — zeroed before libvpx writes through the pointer, and
        // the return value is checked.
        unsafe {
            let iface = vpx_codec_vp9_dx();
            assert!(
                !iface.is_null(),
                "vpx_codec_vp9_dx() is null — this libvpx has no VP9 decoder"
            );
            let cfg = vpx_codec_dec_cfg_t { threads: 1, w: 0, h: 0 };
            let mut ctx: vpx_codec_ctx_t = std::mem::zeroed();
            check(
                vpx_codec_dec_init_ver(&mut ctx, iface, &cfg, 0, VPX_DECODER_ABI_VERSION as c_int),
                "dec_init_ver",
            );
            Self { ctx }
        }
    }

    /// Decode one packet and return the mean absolute error of its luma against `source`.
    fn decode(&mut self, data: &[u8], source: &Frame) -> f64 {
        // SAFETY: `data` outlives the call, and the frame libvpx hands back points into the
        // decoder and is only read before the next call.
        unsafe {
            check(
                vpx_codec_decode(
                    &mut self.ctx,
                    data.as_ptr(),
                    data.len() as c_uint,
                    std::ptr::null_mut(),
                    0,
                ),
                "decode",
            );
            let mut iter: vpx_codec_iter_t = std::ptr::null();
            let img = vpx_codec_get_frame(&mut self.ctx, &mut iter);
            assert!(!img.is_null(), "a packet decoded to no frame at all");
            let img = &*img;
            assert_eq!((img.d_w, img.d_h), (W, H), "the decoder disagrees about the picture size");

            let stride = img.stride[0] as usize;
            let plane = img.planes[0];
            let mut total = 0u64;
            for row in 0..H as usize {
                let decoded = std::slice::from_raw_parts(plane.add(row * stride), W as usize);
                let original = &source.y[row * W as usize..(row + 1) * W as usize];
                for (a, b) in decoded.iter().zip(original) {
                    total += u64::from(a.abs_diff(*b));
                }
            }
            total as f64 / f64::from(W * H)
        }
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // SAFETY: destroyed exactly once.
        unsafe {
            vpx_codec_destroy(&mut self.ctx);
        }
    }
}

/// Turn a libvpx return code into a panic that names both the call and libvpx's own explanation.
///
/// # Safety
///
/// Nothing to uphold for the `VPX_CODEC_OK` path. On failure this does not read a context, so it
/// is safe to call with any code.
fn check(err: vpx_codec_err_t, what: &str) {
    if err != vpx_codec_err_t_VPX_CODEC_OK {
        // SAFETY: `vpx_codec_err_to_string` takes a code, not a context, and returns a static
        // string constant.
        let detail = unsafe { CStr::from_ptr(vpx_codec_err_to_string(err)) };
        panic!("libvpx {what} failed: {} ({err})", detail.to_string_lossy());
    }
}

/// One `vpx_codec_control_` call with an `int` argument, checked.
///
/// # Safety
///
/// `ctx` must be a live, initialised encoder context, and `id` must be a control whose argument
/// really is an `int` — the call is variadic, so passing the wrong type compiles and corrupts
/// the stack.
unsafe fn control(ctx: *mut vpx_codec_ctx_t, id: vp8e_enc_control_id, value: c_int, what: &str) {
    check(vpx_codec_control_(ctx, id as c_int, value), what);
}
