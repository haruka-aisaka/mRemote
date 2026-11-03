#ifndef MREMOTE_H264_DECODER_H
#define MREMOTE_H264_DECODER_H

#include <stddef.h>
#include <stdint.h>

/* An H.264 (AVC420) decoder for one graphics surface, on VideoToolbox.
 *
 * It takes Annex B access units as RDPGFX carries them and writes the
 * decoded picture's region rectangles into a 32-bit BGRX surface. It knows
 * nothing of FreeRDP, so it can be tested on the host. Not thread-safe: one
 * decoder belongs to one surface on the session worker. */

typedef struct mr_h264_decoder mr_h264_decoder;

/* left/top inclusive, right/bottom exclusive, as RDPGFX's RECTANGLE_16. */
typedef struct mr_h264_rect {
    uint16_t left;
    uint16_t top;
    uint16_t right;
    uint16_t bottom;
} mr_h264_rect;

enum {
    MR_H264_OK = 0,
    MR_H264_ERROR_ARGUMENT = -1,
    /* No SPS/PPS has been seen yet, or VideoToolbox refused them. */
    MR_H264_ERROR_FORMAT = -2,
    /* VideoToolbox could not decode the picture. The decoder starts over:
     * nothing more is decoded until the next key frame. */
    MR_H264_ERROR_DECODE = -3,
    MR_H264_ERROR_MEMORY = -4,
    /* The decoder is new or has just started over, and this picture is not
     * a key frame: it refers to pictures the decoder does not have, so it is
     * not decoded. Whoever feeds the decoder should ask for a key frame. */
    MR_H264_ERROR_NEEDS_KEY_FRAME = -5
};

mr_h264_decoder *mr_h264_decoder_new(void);
void mr_h264_decoder_free(mr_h264_decoder *decoder);

/* VideoToolbox's status for the last picture that failed with
 * MR_H264_ERROR_DECODE, for the log. 0 if it gave no picture without saying
 * why, or if nothing has failed. */
int32_t mr_h264_decoder_last_status(const mr_h264_decoder *decoder);

int mr_h264_decoder_decode(
    mr_h264_decoder *decoder,
    const uint8_t *data,
    size_t length,
    uint8_t *destination,
    uint32_t destination_stride,
    uint32_t destination_width,
    uint32_t destination_height,
    const mr_h264_rect *rects,
    size_t rect_count);

#endif
