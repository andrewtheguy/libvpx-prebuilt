// What bindgen reads. The encoder and decoder interfaces, plus the two codec-specific headers
// where libvpx actually declares VP9: `vp8cx.h` holds `vpx_codec_vp9_cx()` and every `VP9E_*`
// control id, and `vp8dx.h` holds `vpx_codec_vp9_dx()`. The names are historical; the contents
// are not optional.
#include <vpx/vpx_codec.h>
#include <vpx/vpx_encoder.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_image.h>
#include <vpx/vp8cx.h>
#include <vpx/vp8dx.h>
