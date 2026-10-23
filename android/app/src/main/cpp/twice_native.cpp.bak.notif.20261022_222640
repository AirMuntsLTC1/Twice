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
