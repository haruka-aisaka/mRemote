#include "h264_decoder.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <stdlib.h>
#include <string.h>

#define MR_H264_MAX_PARAMETER_SET 512u

struct mr_h264_decoder {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
    uint8_t sps[MR_H264_MAX_PARAMETER_SET];
    size_t sps_length;
    uint8_t pps[MR_H264_MAX_PARAMETER_SET];
    size_t pps_length;
    /* Set by the output callback during a synchronous decode. */
    CVPixelBufferRef picture;
    OSStatus picture_status;
    uint8_t *avcc;
    size_t avcc_capacity;
};

typedef struct mr_h264_nal {
    const uint8_t *bytes;
    size_t length;
} mr_h264_nal;

/* The next NAL unit after `*offset`, past its 3- or 4-byte start code. */
static int mr_h264_next_nal(const uint8_t *data, size_t length, size_t *offset, mr_h264_nal *out)
{
    size_t index = *offset;
    size_t start;
    while (index + 3u <= length &&
           !(data[index] == 0u && data[index + 1u] == 0u && data[index + 2u] == 1u)) {
        ++index;
    }
    if (index + 3u > length) {
        return 0;
    }
    start = index + 3u;
    index = start;
    while (index + 3u <= length &&
           !(data[index] == 0u && data[index + 1u] == 0u &&
             (data[index + 2u] == 1u || (data[index + 2u] == 0u && index + 3u < length && data[index + 3u] == 1u)))) {
        ++index;
    }
    if (index + 3u > length) {
        index = length;
    }
    out->bytes = data + start;
    out->length = index - start;
    /* Trailing zero bytes belong to the next start code. */
    while (out->length > 0u && out->bytes[out->length - 1u] == 0u && index < length) {
        --out->length;
    }
    *offset = index;
    return out->length > 0u;
}

static void mr_h264_output(
    void *refcon,
    void *frame_refcon,
    OSStatus status,
    VTDecodeInfoFlags flags,
    CVImageBufferRef image,
    CMTime timestamp,
    CMTime duration)
{
    mr_h264_decoder *decoder = (mr_h264_decoder *)refcon;
    (void)frame_refcon;
    (void)flags;
    (void)timestamp;
    (void)duration;
    decoder->picture_status = status;
    if (status == noErr && image != NULL) {
        if (decoder->picture != NULL) {
            CVPixelBufferRelease(decoder->picture);
        }
        decoder->picture = CVPixelBufferRetain(image);
    }
}

static void mr_h264_reset_session(mr_h264_decoder *decoder)
{
    if (decoder->session != NULL) {
        VTDecompressionSessionInvalidate(decoder->session);
        CFRelease(decoder->session);
        decoder->session = NULL;
    }
    if (decoder->format != NULL) {
        CFRelease(decoder->format);
        decoder->format = NULL;
    }
}

static int mr_h264_make_session(mr_h264_decoder *decoder)
{
    const uint8_t *sets[2] = { decoder->sps, decoder->pps };
    const size_t sizes[2] = { decoder->sps_length, decoder->pps_length };
    VTDecompressionOutputCallbackRecord callback = { mr_h264_output, decoder };
    CFMutableDictionaryRef attributes;
    int32_t pixel_format = kCVPixelFormatType_32BGRA;
    CFNumberRef number;
    OSStatus status;

    mr_h264_reset_session(decoder);
    status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault, 2, sets, sizes, 4, &decoder->format);
    if (status != noErr) {
        decoder->format = NULL;
        return MR_H264_ERROR_FORMAT;
    }
    attributes = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixel_format);
    CFDictionarySetValue(attributes, kCVPixelBufferPixelFormatTypeKey, number);
    CFRelease(number);
    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault, decoder->format, NULL, attributes, &callback, &decoder->session);
    CFRelease(attributes);
    if (status != noErr) {
        decoder->session = NULL;
        return MR_H264_ERROR_FORMAT;
    }
    return MR_H264_OK;
}

mr_h264_decoder *mr_h264_decoder_new(void)
{
    return (mr_h264_decoder *)calloc(1u, sizeof(mr_h264_decoder));
}

void mr_h264_decoder_free(mr_h264_decoder *decoder)
{
    if (decoder == NULL) {
        return;
    }
    mr_h264_reset_session(decoder);
    if (decoder->picture != NULL) {
        CVPixelBufferRelease(decoder->picture);
    }
    free(decoder->avcc);
    free(decoder);
}

static int mr_h264_remember(uint8_t *store, size_t *stored, const mr_h264_nal *nal)
{
    if (nal->length > MR_H264_MAX_PARAMETER_SET) {
        return 0;
    }
    if (*stored == nal->length && memcmp(store, nal->bytes, nal->length) == 0) {
        return 0;
    }
    memcpy(store, nal->bytes, nal->length);
    *stored = nal->length;
    return 1;
}

static void mr_h264_copy_rects(
    CVPixelBufferRef picture,
    uint8_t *destination,
    uint32_t destination_stride,
    uint32_t destination_width,
    uint32_t destination_height,
    const mr_h264_rect *rects,
    size_t rect_count)
{
    const size_t width = CVPixelBufferGetWidth(picture);
    const size_t height = CVPixelBufferGetHeight(picture);
    const size_t source_stride = CVPixelBufferGetBytesPerRow(picture);
    const uint8_t *source;
    size_t index;
    CVPixelBufferLockBaseAddress(picture, kCVPixelBufferLock_ReadOnly);
    source = (const uint8_t *)CVPixelBufferGetBaseAddress(picture);
    for (index = 0u; source != NULL && index < rect_count; ++index) {
        size_t left = rects[index].left;
        size_t top = rects[index].top;
        size_t right = rects[index].right;
        size_t bottom = rects[index].bottom;
        size_t row;
        if (right > width) right = width;
        if (right > destination_width) right = destination_width;
        if (bottom > height) bottom = height;
        if (bottom > destination_height) bottom = destination_height;
        if (left >= right || top >= bottom) {
            continue;
        }
        for (row = top; row < bottom; ++row) {
            memcpy(destination + row * destination_stride + left * 4u,
                   source + row * source_stride + left * 4u,
                   (right - left) * 4u);
        }
    }
    CVPixelBufferUnlockBaseAddress(picture, kCVPixelBufferLock_ReadOnly);
}

int mr_h264_decoder_decode(
    mr_h264_decoder *decoder,
    const uint8_t *data,
    size_t length,
    uint8_t *destination,
    uint32_t destination_stride,
    uint32_t destination_width,
    uint32_t destination_height,
    const mr_h264_rect *rects,
    size_t rect_count)
{
    size_t offset = 0u;
    size_t avcc_length = 0u;
    int parameters_changed = 0;
    mr_h264_nal nal;
    CMBlockBufferRef block = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status;
    VTDecodeInfoFlags info = 0;

    if (decoder == NULL || data == NULL || length == 0u || destination == NULL ||
        destination_stride < destination_width * 4u || (rects == NULL && rect_count != 0u)) {
        return MR_H264_ERROR_ARGUMENT;
    }
    /* Parameter sets first; everything else is the picture, re-framed with
     * four-byte lengths as VideoToolbox wants it. */
    if (decoder->avcc_capacity < length + 64u) {
        uint8_t *grown = (uint8_t *)realloc(decoder->avcc, length + 64u);
        if (grown == NULL) {
            return MR_H264_ERROR_MEMORY;
        }
        decoder->avcc = grown;
        decoder->avcc_capacity = length + 64u;
    }
    while (mr_h264_next_nal(data, length, &offset, &nal)) {
        const uint8_t type = nal.bytes[0] & 0x1Fu;
        if (type == 7u) {
            parameters_changed |= mr_h264_remember(decoder->sps, &decoder->sps_length, &nal);
        } else if (type == 8u) {
            parameters_changed |= mr_h264_remember(decoder->pps, &decoder->pps_length, &nal);
        } else if (type != 9u) {
            if (avcc_length + 4u + nal.length > decoder->avcc_capacity) {
                return MR_H264_ERROR_MEMORY;
            }
            decoder->avcc[avcc_length++] = (uint8_t)(nal.length >> 24);
            decoder->avcc[avcc_length++] = (uint8_t)(nal.length >> 16);
            decoder->avcc[avcc_length++] = (uint8_t)(nal.length >> 8);
            decoder->avcc[avcc_length++] = (uint8_t)nal.length;
            memcpy(decoder->avcc + avcc_length, nal.bytes, nal.length);
            avcc_length += nal.length;
        }
    }
    if (decoder->sps_length == 0u || decoder->pps_length == 0u) {
        return MR_H264_ERROR_FORMAT;
    }
    if (parameters_changed || decoder->session == NULL) {
        const int made = mr_h264_make_session(decoder);
        if (made != MR_H264_OK) {
            return made;
        }
    }
    if (avcc_length == 0u) {
        return MR_H264_OK;
    }

    status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault, NULL, avcc_length, kCFAllocatorDefault, NULL, 0, avcc_length, 0, &block);
    if (status == noErr) {
        status = CMBlockBufferReplaceDataBytes(decoder->avcc, block, 0, avcc_length);
    }
    if (status == noErr) {
        const size_t sizes[1] = { avcc_length };
        status = CMSampleBufferCreateReady(
            kCFAllocatorDefault, block, decoder->format, 1, 0, NULL, 1, sizes, &sample);
    }
    if (block != NULL) {
        CFRelease(block);
    }
    if (status != noErr || sample == NULL) {
        return MR_H264_ERROR_MEMORY;
    }
    /* A frame that produces no picture must not leave the last one to be
     * copied again. */
    if (decoder->picture != NULL) {
        CVPixelBufferRelease(decoder->picture);
        decoder->picture = NULL;
    }
    decoder->picture_status = noErr;
    status = VTDecompressionSessionDecodeFrame(decoder->session, sample, 0, NULL, &info);
    if (status == kVTInvalidSessionErr) {
        /* The system takes decoders away from a backgrounded app; the next
         * key frame starts a fresh one. */
        mr_h264_reset_session(decoder);
    } else if (status == noErr) {
        (void)VTDecompressionSessionWaitForAsynchronousFrames(decoder->session);
    }
    CFRelease(sample);
    if (status != noErr || decoder->picture_status != noErr || decoder->picture == NULL) {
        return MR_H264_ERROR_DECODE;
    }
    mr_h264_copy_rects(
        decoder->picture, destination, destination_stride,
        destination_width, destination_height, rects, rect_count);
    return MR_H264_OK;
}
