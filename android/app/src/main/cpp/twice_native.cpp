#include <cstdint>

#if defined(__GNUC__)
#define TWICE_EXPORT __attribute__((visibility("default")))
#else
#define TWICE_EXPORT
#endif

extern "C" TWICE_EXPORT
int32_t twice_native_add(int32_t a, int32_t b) {
    return a + b;
}

extern "C" TWICE_EXPORT
int32_t twice_native_version() {
    return 1;
}
