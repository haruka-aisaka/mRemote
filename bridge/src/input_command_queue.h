#ifndef MREMOTE_INPUT_COMMAND_QUEUE_H
#define MREMOTE_INPUT_COMMAND_QUEUE_H

#include "mremote/rdp_bridge.h"

#include <stddef.h>
#include <stdint.h>

#define MR_INPUT_COMMAND_QUEUE_CAPACITY 1024u

typedef uint8_t mr_input_command_kind;
enum {
    MR_INPUT_COMMAND_KEY = 1,
    MR_INPUT_COMMAND_POINTER = 2,
    /* A self-contained down/up pair: it creates no release obligation. */
    MR_INPUT_COMMAND_UNICODE = 3,
    /* ABI 4. A DOWN obliges an UP/CANCEL for its contact; MOVEs coalesce per
     * contact. */
    MR_INPUT_COMMAND_TOUCH = 4,
    /* ABI 4. A DOWN obliges an UP; HOVER and MOVE coalesce. */
    MR_INPUT_COMMAND_PEN = 5,
    /* ABI 6. A client-to-server MACRDPX message. KEY and POINTER downs
     * oblige their ups; pointer moves and continuing scrolls coalesce. */
    MR_INPUT_COMMAND_MACRDPX = 6
};

typedef struct mr_input_command {
    mr_input_command_kind kind;
    union {
        mr_rdp_key_event key;
        mr_rdp_pointer_event pointer;
        mr_rdp_unicode_event unicode;
        mr_rdp_touch_event touch;
        mr_rdp_pen_event pen;
        mrx_message macrdpx;
    } value;
} mr_input_command;

typedef uint8_t mr_input_release_kind;
enum {
    MR_INPUT_RELEASE_KEY = 1,
    MR_INPUT_RELEASE_BUTTON = 2,
    MR_INPUT_RELEASE_TOUCH = 3,
    MR_INPUT_RELEASE_PEN = 4,
    MR_INPUT_RELEASE_MAC_KEY = 5,
    MR_INPUT_RELEASE_MAC_BUTTON = 6
};

typedef struct mr_input_release_reservation {
    mr_input_release_kind kind;
    uint16_t key_code;
    uint8_t extended;
    uint8_t extended1;
    mr_rdp_pointer_button button;
    uint32_t contact_id;
} mr_input_release_reservation;

typedef struct mr_input_command_queue {
    mr_input_command commands[MR_INPUT_COMMAND_QUEUE_CAPACITY];
    mr_input_release_reservation
        reservations[MR_INPUT_COMMAND_QUEUE_CAPACITY];
    size_t head;
    size_t count;
    size_t reservation_count;
    size_t capacity;
} mr_input_command_queue;

typedef uint8_t mr_input_enqueue_result;
enum {
    MR_INPUT_ENQUEUE_QUEUED = 0,
    MR_INPUT_ENQUEUE_COALESCED = 1,
    MR_INPUT_ENQUEUE_DROPPED = 2,
    MR_INPUT_ENQUEUE_TRANSITION_OVERFLOW = 3,
    MR_INPUT_ENQUEUE_INVALID = 4
};

int mr_input_command_queue_init(
    mr_input_command_queue *queue,
    size_t capacity);
void mr_input_command_queue_reset(mr_input_command_queue *queue);
mr_input_enqueue_result mr_input_command_queue_enqueue(
    mr_input_command_queue *queue,
    const mr_input_command *command);
int mr_input_command_queue_dequeue(
    mr_input_command_queue *queue,
    mr_input_command *out_command);
size_t mr_input_command_queue_count(const mr_input_command_queue *queue);
size_t mr_input_command_queue_reserved_count(
    const mr_input_command_queue *queue);

#endif
