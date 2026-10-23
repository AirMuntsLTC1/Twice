#include <jni.h>
#include <android/log.h>
#include <cstring>
#include <cstdint>
#include <algorithm>
#include <vector>
#include <string>

#define LOG_TAG "TwiceNative"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// Basic arithmetic (kept for existing Dart FFI lookup)
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jint JNICALL
twice_native_add(JNIEnv *, jobject, jint a, jint b) {
    return a + b;
}

// ---------------------------------------------------------------------------
// Fast image downscale helper (nearest-neighbour) for offline cache thumbnails.
// Called from Dart via FFI when generating small avatars / list thumbnails.
// RGBA8888 in → RGBA8888 out. Returns 0 on success, -1 on bad args.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jint JNICALL
twice_native_resize_rgba(
    JNIEnv *env,
    jobject,
    jbyteArray src,
    jint srcW,
    jint srcH,
    jbyteArray dst,
    jint dstW,
    jint dstH
) {
    if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0) return -1;
    const jsize srcLen = env->GetArrayLength(src);
    const jsize dstLen = env->GetArrayLength(dst);
    if (srcLen < srcW * srcH * 4) return -1;
    if (dstLen < dstW * dstH * 4) return -1;

    jbyte *s = env->GetByteArrayElements(src, nullptr);
    jbyte *d = env->GetByteArrayElements(dst, nullptr);
    if (!s || !d) {
        if (s) env->ReleaseByteArrayElements(src, s, JNI_ABORT);
        if (d) env->ReleaseByteArrayElements(dst, d, JNI_ABORT);
        return -1;
    }

    for (int y = 0; y < dstH; ++y) {
        const int sy = (y * srcH) / dstH;
        for (int x = 0; x < dstW; ++x) {
            const int sx = (x * srcW) / dstW;
            const int si = (sy * srcW + sx) * 4;
            const int di = (y * dstW + x) * 4;
            d[di]     = s[si];
            d[di + 1] = s[si + 1];
            d[di + 2] = s[si + 2];
            d[di + 3] = s[si + 3];
        }
    }

    env->ReleaseByteArrayElements(src, s, JNI_ABORT);
    env->ReleaseByteArrayElements(dst, d, 0);
    return 0;
}

// ---------------------------------------------------------------------------
// CRC32 (fast integrity check for offline media cache files)
// ---------------------------------------------------------------------------
static uint32_t crc_table[256];
static bool crc_ready = false;

static void init_crc() {
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int k = 0; k < 8; ++k)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crc_table[i] = c;
    }
    crc_ready = true;
}

extern "C" JNIEXPORT jlong JNICALL
twice_native_crc32(JNIEnv *env, jobject, jbyteArray data) {
    if (!crc_ready) init_crc();
    const jsize len = env->GetArrayLength(data);
    jbyte *buf = env->GetByteArrayElements(data, nullptr);
    if (!buf) return 0;
    uint32_t crc = 0xFFFFFFFFu;
    for (jsize i = 0; i < len; ++i) {
        crc = crc_table[(crc ^ static_cast<uint8_t>(buf[i])) & 0xFF] ^ (crc >> 8);
    }
    env->ReleaseByteArrayElements(data, buf, JNI_ABORT);
    return static_cast<jlong>(crc ^ 0xFFFFFFFFu);
}

// ---------------------------------------------------------------------------
// Simple frame-drop soft limiter: returns recommended skip count for a
// given target FPS vs measured frame time (microseconds). Used by video
// feed to avoid jank when many players are attached.
// ---------------------------------------------------------------------------
extern "C" JNIEXPORT jint JNICALL
twice_native_frame_skip(JNIEnv *, jobject, jlong frameUs, jint targetFps) {
    if (targetFps <= 0) return 0;
    const jlong budget = 1000000L / targetFps;
    if (frameUs <= budget) return 0;
    const jint skip = static_cast<jint>((frameUs / budget) - 1);
    return skip > 4 ? 4 : skip;
}


// ---------------------------------------------------------------------------
// Additional low-cost native helpers from the notification/core upgrade.
// Plain C exports are safe for Dart FFI and do not change existing symbols.
// ---------------------------------------------------------------------------
extern "C" __attribute__((visibility("default"))) uint64_t
 twice_native_fnv1a64(const uint8_t *data, int64_t length) {
    if (data == nullptr || length < 0) return 0;
    uint64_t hash = UINT64_C(14695981039346656037);
    for (int64_t i = 0; i < length; ++i) {
        hash ^= static_cast<uint64_t>(data[i]);
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

extern "C" __attribute__((visibility("default"))) int32_t
 twice_native_clamp64(int64_t value, int32_t minimum, int32_t maximum) {
    if (minimum > maximum) return minimum;
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return static_cast<int32_t>(value);
}

// Returns a stable priority: message > reply/comment > like > follow > post.
// Type codes: 1 message, 2 reply, 3 comment, 4 like, 5 follow, 6 new post.
extern "C" __attribute__((visibility("default"))) int32_t
 twice_native_notification_priority(int32_t typeCode, int32_t unread, int32_t ageMinutes) {
    int32_t base = 10;
    switch (typeCode) {
        case 1: base = 100; break;
        case 2: base = 80; break;
        case 3: base = 70; break;
        case 4: base = 55; break;
        case 5: base = 45; break;
        case 6: base = 35; break;
        default: base = 10; break;
    }
    if (unread != 0) base += 8;
    if (ageMinutes > 0) base -= std::min(ageMinutes / 30, 20);
    return std::max(0, std::min(base, 127));
}

// Average RGB of RGBA8888 bytes packed as 0xRRGGBB; returns -1 on bad input.
extern "C" __attribute__((visibility("default"))) int64_t
 twice_native_avg_color_rgba(const uint8_t *rgba, int64_t pixelCount) {
    if (rgba == nullptr || pixelCount <= 0) return -1;
    uint64_t r = 0, g = 0, b = 0;
    for (int64_t i = 0; i < pixelCount; ++i) {
        const int64_t j = i * 4;
        r += rgba[j]; g += rgba[j + 1]; b += rgba[j + 2];
    }
    const uint64_t rr = r / static_cast<uint64_t>(pixelCount);
    const uint64_t gg = g / static_cast<uint64_t>(pixelCount);
    const uint64_t bb = b / static_cast<uint64_t>(pixelCount);
    return static_cast<int64_t>((rr << 16) | (gg << 8) | bb);
}

// Bilinear RGBA resize using caller-owned buffers. Dimensions are bounded to
// prevent overflow and unreasonable allocations; returns 0 on success.
extern "C" __attribute__((visibility("default"))) int32_t
 twice_native_resize_rgba_bilinear(const uint8_t *src, int32_t srcW, int32_t srcH,
                                   uint8_t *dst, int32_t dstW, int32_t dstH) {
    if (!src || !dst || srcW < 2 || srcH < 2 || dstW < 1 || dstH < 1) return -1;
    constexpr int32_t kMaxDimension = 8192;
    if (srcW > kMaxDimension || srcH > kMaxDimension ||
        dstW > kMaxDimension || dstH > kMaxDimension) return -1;
    const int64_t srcBytes = static_cast<int64_t>(srcW) * srcH * 4;
    const int64_t dstBytes = static_cast<int64_t>(dstW) * dstH * 4;
    if (srcBytes <= 0 || dstBytes <= 0) return -1;
    const float xr = static_cast<float>(srcW - 1) / static_cast<float>(std::max(1, dstW - 1));
    const float yr = static_cast<float>(srcH - 1) / static_cast<float>(std::max(1, dstH - 1));
    for (int32_t y = 0; y < dstH; ++y) {
        const float fy0 = y * yr; const int32_t y0 = std::min(static_cast<int32_t>(fy0), srcH - 1);
        const int32_t y1 = std::min(y0 + 1, srcH - 1); const float fy = fy0 - y0;
        for (int32_t x = 0; x < dstW; ++x) {
            const float fx0 = x * xr; const int32_t x0 = std::min(static_cast<int32_t>(fx0), srcW - 1);
            const int32_t x1 = std::min(x0 + 1, srcW - 1); const float fx = fx0 - x0;
            for (int c = 0; c < 4; ++c) {
                const float a = src[(static_cast<int64_t>(y0) * srcW + x0) * 4 + c];
                const float b = src[(static_cast<int64_t>(y0) * srcW + x1) * 4 + c];
                const float d = src[(static_cast<int64_t>(y1) * srcW + x0) * 4 + c];
                const float e = src[(static_cast<int64_t>(y1) * srcW + x1) * 4 + c];
                const float top = a + (b - a) * fx; const float bottom = d + (e - d) * fx;
                const int64_t out = (static_cast<int64_t>(y) * dstW + x) * 4 + c;
                dst[out] = static_cast<uint8_t>(std::max(0.0f, std::min(255.0f, top + (bottom - top) * fy)));
            }
        }
    }
    return 0;
}


// ---------------------------------------------------------------------------
// Media helpers (added). Pure C, allocation-free, no I/O, no globals.
// These are additive; they do not change any existing exported symbol
// or the ABI version returned by twice_native_abi_version().
// ---------------------------------------------------------------------------

// Parse EXIF orientation (1..8) from the leading bytes of a JPEG/HEIC
// file. Returns 1 (normal) if the tag is missing or the input is not a
// valid EXIF/TIFF structure. Never allocates, never reads past len.
extern "C" __attribute__((visibility("default"))) int32_t
twice_native_exif_orientation(const uint8_t *buf, int64_t len) {
    if (buf == nullptr || len < 14) return 1;
    // JPEG: FF D8 ... FF E1 (APP1) ... 'Exif\0\0' ... TIFF header.
    if (!(buf[0] == 0xFF && buf[1] == 0xD8)) return 1;
    int64_t i = 2;
    // Bounded scan for APP1.
    while (i + 4 <= len) {
        if (buf[i] != 0xFF) return 1;
        const uint8_t marker = buf[i + 1];
        if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) {
            i += 2;
            continue;
        }
        if (marker == 0xD9 || marker == 0xDA) return 1;
        if (i + 4 > len) return 1;
        const int32_t seg_len =
            (static_cast<int32_t>(buf[i + 2]) << 8) | buf[i + 3];
        if (seg_len < 2 || i + 2 + seg_len > len) return 1;
        if (marker == 0xE1 && seg_len >= 8) {
            const int64_t base = i + 4;
            if (buf[base] == 'E' && buf[base + 1] == 'x' &&
                buf[base + 2] == 'i' && buf[base + 3] == 'f' &&
                buf[base + 4] == 0 && buf[base + 5] == 0) {
                const int64_t tiff = base + 6;
                if (tiff + 8 > len) return 1;
                const bool little =
                    buf[tiff] == 'I' && buf[tiff + 1] == 'I';
                const bool big =
                    buf[tiff] == 'M' && buf[tiff + 1] == 'M';
                if (!little && !big) return 1;
                auto rd16 = [&](int64_t off) -> uint16_t {
                    if (little) {
                        return static_cast<uint16_t>(
                            buf[off] | (buf[off + 1] << 8));
                    }
                    return static_cast<uint16_t>(
                        (buf[off] << 8) | buf[off + 1]);
                };
                auto rd32 = [&](int64_t off) -> uint32_t {
                    if (little) {
                        return static_cast<uint32_t>(
                            buf[off] | (buf[off + 1] << 8) |
                            (buf[off + 2] << 16) |
                            (static_cast<uint32_t>(buf[off + 3]) << 24));
                    }
                    return static_cast<uint32_t>(
                        (static_cast<uint32_t>(buf[off]) << 24) |
                        (buf[off + 1] << 16) | (buf[off + 2] << 8) |
                        buf[off + 3]);
                };
                const uint16_t magic = rd16(tiff + 2);
                if (magic != 0x002A) return 1;
                const uint32_t ifd0_off = rd32(tiff + 4);
                if (ifd0_off < 8 || tiff + ifd0_off + 2 > len) return 1;
                const uint16_t count = rd16(tiff + ifd0_off);
                int64_t p = tiff + ifd0_off + 2;
                for (uint16_t k = 0; k < count; k++) {
                    if (p + 12 > len) return 1;
                    const uint16_t tag = rd16(p);
                    if (tag == 0x0112) {
                        const uint16_t val = rd16(p + 8);
                        if (val >= 1 && val <= 8) return val;
                        return 1;
                    }
                    p += 12;
                }
                return 1;
            }
        }
        i += 2 + seg_len;
    }
    return 1;
}

// ---------------------------------------------------------------------------
// TWICE notification / feed utility core (ABI v2).
// Pure deterministic helpers: no allocations, locks, I/O, or global state.
// These are safe for small hot-path scoring and payload validation.
// ---------------------------------------------------------------------------
extern "C" __attribute__((visibility("default")))
int32_t twice_native_abi_version() { return 2; }

extern "C" __attribute__((visibility("default")))
int32_t twice_native_notification_type_code(const char *type) {
    if (type == nullptr) return 0;
    if (std::strcmp(type, "message") == 0) return 1;
    if (std::strcmp(type, "like") == 0) return 2;
    if (std::strcmp(type, "comment") == 0) return 3;
    if (std::strcmp(type, "reply") == 0) return 4;
    if (std::strcmp(type, "follow") == 0) return 5;
    if (std::strcmp(type, "follow_request") == 0) return 6;
    if (std::strcmp(type, "follow_accept") == 0) return 7;
    if (std::strcmp(type, "story_reaction") == 0) return 8;
    if (std::strcmp(type, "story_reply") == 0) return 9;
    if (std::strcmp(type, "save") == 0) return 10;
    return 0;
}

// Bounded priority used for ordering work queues, not as a security decision.
extern "C" __attribute__((visibility("default")))
int32_t twice_native_notification_priority_v2(
    int32_t type_code, int32_t is_foreground, int32_t age_seconds) {
    int32_t score = 10;
    if (type_code == 1) score = 100;          // direct message
    else if (type_code == 3 || type_code == 4) score = 70;
    else if (type_code == 2) score = 55;
    else if (type_code == 5 || type_code == 6 || type_code == 7) score = 45;
    else if (type_code >= 8 && type_code <= 10) score = 35;
    if (is_foreground != 0) score -= 5;
    if (age_seconds > 0) {
        const int32_t decay = std::min<int32_t>(30, age_seconds / 120);
        score -= decay;
    }
    return std::max<int32_t>(0, std::min<int32_t>(100, score));
}

// Validate the target combination before Dart attempts navigation.
// Message targets need a conversation; social targets need a post or story.
extern "C" __attribute__((visibility("default")))
int32_t twice_native_notification_target_valid(
    int32_t type_code, int32_t has_conversation,
    int32_t has_post, int32_t has_story) {
    if (type_code == 1) return has_conversation != 0 ? 1 : 0;
    if (type_code == 2 || type_code == 3 || type_code == 4 || type_code == 10)
        return has_post != 0 ? 1 : 0;
    if (type_code == 8 || type_code == 9)
        return (has_story != 0 || has_post != 0) ? 1 : 0;
    return 1;
}
