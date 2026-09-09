#import <stdint.h>

#define VCAM_LIVE_NV12_MAGIC 0x56434E56u

typedef struct {
    uint32_t magic;
    uint32_t width;
    uint32_t height;
    uint32_t yStride;
    uint32_t uvStride;
    uint64_t generation;
} VCamLiveNV12Header;
