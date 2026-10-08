#include "h264_decoder.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Encodes a few frames with VideoToolbox, turns them into Annex B access
 * units as RDPGFX carries them, and checks the decoder gives the picture
 * back where the region rectangles say. */

#define WIDTH 128u
#define HEIGHT 96u
#define FRAMES 4

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
            return 0; \
        } \
    } while (0)

typedef struct encoded {
    uint8_t *bytes[FRAMES];
    size_t length[FRAMES];
    int count;
} encoded;

static void append(uint8_t **buffer, size_t *length, const uint8_t *bytes, size_t count)
{
    static const uint8_t start[4] = { 0, 0, 0, 1 };
    *buffer = (uint8_t *)realloc(*buffer, *length + 4u + count);
    memcpy(*buffer + *length, start, 4u);
    memcpy(*buffer + *length + 4u, bytes, count);
    *length += 4u + count;
}

static void on_encoded(
    void *refcon, void *frame_refcon, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample)
{
    encoded *out = (encoded *)refcon;
    uint8_t *frame = NULL;
    size_t frame_length = 0u;
    CMFormatDescriptionRef format;
    size_t sets = 0u;
    size_t index;
    CMBlockBufferRef block;
    size_t total = 0u;
    char *data = NULL;
    (void)frame_refcon;
    (void)flags;
    if (status != noErr || sample == NULL || out->count >= FRAMES) {
        return;
    }
    format = CMSampleBufferGetFormatDescription(sample);
    (void)CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL, &sets, NULL);
    for (index = 0u; index < sets; ++index) {
        const uint8_t *set = NULL;
        size_t set_length = 0u;
        (void)CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, index, &set, &set_length, NULL, NULL);
        append(&frame, &frame_length, set, set_length);
    }
    block = CMSampleBufferGetDataBuffer(sample);
    (void)CMBlockBufferGetDataPointer(block, 0, NULL, &total, &data);
    index = 0u;
    while (index + 4u <= total) {
        const uint32_t nal = ((uint32_t)(uint8_t)data[index] << 24) | ((uint32_t)(uint8_t)data[index + 1] << 16) |
            ((uint32_t)(uint8_t)data[index + 2] << 8) | (uint8_t)data[index + 3];
        append(&frame, &frame_length, (const uint8_t *)data + index + 4u, nal);
        index += 4u + nal;
    }
    out->bytes[out->count] = frame;
    out->length[out->count] = frame_length;
    ++out->count;
}

static int encode(encoded *out)
{
    VTCompressionSessionRef session = NULL;
    int frame;
    memset(out, 0, sizeof(*out));
    CHECK(VTCompressionSessionCreate(
              kCFAllocatorDefault, WIDTH, HEIGHT, kCMVideoCodecType_H264, NULL, NULL, NULL,
              on_encoded, out, &session) == noErr);
    (void)VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    (void)VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    (void)VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    for (frame = 0; frame < FRAMES; ++frame) {
        CVPixelBufferRef pixels = NULL;
        uint8_t *base;
        size_t stride;
        size_t x;
        size_t y;
        CHECK(CVPixelBufferCreate(kCFAllocatorDefault, WIDTH, HEIGHT, kCVPixelFormatType_32BGRA, NULL, &pixels) == kCVReturnSuccess);
        CVPixelBufferLockBaseAddress(pixels, 0);
        base = (uint8_t *)CVPixelBufferGetBaseAddress(pixels);
        stride = CVPixelBufferGetBytesPerRow(pixels);
        /* Left half dark, right half bright; it moves a little each frame. */
        for (y = 0; y < HEIGHT; ++y) {
            for (x = 0; x < WIDTH; ++x) {
                const uint8_t value = x < WIDTH / 2u + (size_t)frame ? 30u : 220u;
                uint8_t *pixel = base + y * stride + x * 4u;
                pixel[0] = value;
                pixel[1] = value;
                pixel[2] = value;
                pixel[3] = 255u;
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, 0);
        CHECK(VTCompressionSessionEncodeFrame(
                  session, pixels, CMTimeMake(frame, 30), kCMTimeInvalid, NULL, NULL, NULL) == noErr);
        CVPixelBufferRelease(pixels);
    }
    CHECK(VTCompressionSessionCompleteFrames(session, kCMTimeInvalid) == noErr);
    VTCompressionSessionInvalidate(session);
    CFRelease(session);
    CHECK(out->count == FRAMES);
    return 1;
}

static int test_round_trip(void)
{
    encoded stream;
    mr_h264_decoder *decoder;
    uint8_t *surface;
    const uint32_t stride = (WIDTH + 16u) * 4u;
    const mr_h264_rect whole = { 0u, 0u, WIDTH, HEIGHT };
    const mr_h264_rect right_half = { WIDTH / 2u + 8u, 0u, WIDTH, HEIGHT };
    int frame;

    CHECK(encode(&stream));
    decoder = mr_h264_decoder_new();
    CHECK(decoder != NULL);
    surface = (uint8_t *)calloc(stride * HEIGHT, 1u);
    CHECK(surface != NULL);

    /* A picture before any parameter set is refused. */
    CHECK(mr_h264_decoder_decode(decoder, stream.bytes[1] + stream.length[1] - 8u, 8u,
                                 surface, stride, WIDTH, HEIGHT, &whole, 1u) != MR_H264_OK);

    for (frame = 0; frame < FRAMES; ++frame) {
        CHECK(mr_h264_decoder_decode(decoder, stream.bytes[frame], stream.length[frame],
                                     surface, stride, WIDTH, HEIGHT, &whole, 1u) == MR_H264_OK);
    }
    /* Lossy: dark stays dark and bright stays bright. */
    CHECK(surface[(HEIGHT / 2u) * stride + 4u * 4u] < 80u);
    CHECK(surface[(HEIGHT / 2u) * stride + (WIDTH - 4u) * 4u] > 170u);

    /* Only the rectangles are written. */
    memset(surface, 0x55, stride * HEIGHT);
    CHECK(mr_h264_decoder_decode(decoder, stream.bytes[FRAMES - 1], stream.length[FRAMES - 1],
                                 surface, stride, WIDTH, HEIGHT, &right_half, 1u) == MR_H264_OK);
    CHECK(surface[(HEIGHT / 2u) * stride + 4u * 4u] == 0x55u);
    CHECK(surface[(HEIGHT / 2u) * stride + (WIDTH - 4u) * 4u] > 170u);
    /* Never past the surface's own width, even if a rectangle says so. */
    CHECK(surface[(HEIGHT / 2u) * stride + (WIDTH + 2u) * 4u] == 0x55u);

    CHECK(mr_h264_decoder_decode(decoder, NULL, 0u, surface, stride, WIDTH, HEIGHT, &whole, 1u) ==
          MR_H264_ERROR_ARGUMENT);
    mr_h264_decoder_free(decoder);
    free(surface);
    for (frame = 0; frame < FRAMES; ++frame) {
        free(stream.bytes[frame]);
    }
    return 1;
}

int main(void)
{
    if (!test_round_trip()) {
        return 1;
    }
    printf("h264 decoder tests passed\n");
    return 0;
}
