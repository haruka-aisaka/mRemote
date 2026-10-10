#include "input_command_queue.h"

#include <limits.h>
#include <string.h>

static size_t mr_input_queue_index(
    const mr_input_command_queue *queue,
    size_t logical_index)
{
    return (queue->head + logical_index) % queue->capacity;
}

static size_t mr_input_queue_used(const mr_input_command_queue *queue)
{
    return queue->count + queue->reservation_count;
}

static size_t mr_input_queue_free(const mr_input_command_queue *queue)
{
    const size_t used = mr_input_queue_used(queue);
    return used < queue->capacity ? queue->capacity - used : 0u;
}

static void mr_input_queue_append(
    mr_input_command_queue *queue,
    const mr_input_command *command)
{
    const size_t tail = mr_input_queue_index(queue, queue->count);
    queue->commands[tail] = *command;
    ++queue->count;
}

static int32_t mr_input_saturating_add(int32_t left, int32_t right)
{
    const int64_t sum = (int64_t)left + (int64_t)right;
    if (sum > MR_RDP_MAX_WHEEL_DELTA) {
        return MR_RDP_MAX_WHEEL_DELTA;
    }
    if (sum < -MR_RDP_MAX_WHEEL_DELTA) {
        return -MR_RDP_MAX_WHEEL_DELTA;
    }
    return (int32_t)sum;
}

static void mr_input_accumulate_wheel(
    mr_input_command *destination,
    const mr_input_command *source)
{
    destination->value.pointer.x = source->value.pointer.x;
    destination->value.pointer.y = source->value.pointer.y;
    destination->value.pointer.wheel_x = mr_input_saturating_add(
        destination->value.pointer.wheel_x,
        source->value.pointer.wheel_x);
    destination->value.pointer.wheel_y = mr_input_saturating_add(
        destination->value.pointer.wheel_y,
        source->value.pointer.wheel_y);
}

/* A Mac key or button transition. Modifier keys are flags-changed events
 * that the server tracks by state, so they owe nothing - but they are still
 * ordinary keys to the queue, which keeps them in order. */
static int mr_input_macrdpx_transition(
    const mr_input_command *command,
    mrx_key_action key_action,
    mrx_pointer_action pointer_action,
    mr_input_release_reservation *out_reservation)
{
    const mrx_message *message = &command->value.macrdpx;
    if (command->kind != MR_INPUT_COMMAND_MACRDPX) {
        return 0;
    }
    if (message->type == MRX_MSG_KEY && message->u.key.action == key_action &&
        (message->u.key.flags & MRX_KEY_FLAG_REPEAT) == 0u) {
        out_reservation->kind = MR_INPUT_RELEASE_MAC_KEY;
        out_reservation->key_code = message->u.key.keycode;
        return 1;
    }
    if (message->type == MRX_MSG_POINTER && message->u.pointer.action == pointer_action) {
        out_reservation->kind = MR_INPUT_RELEASE_MAC_BUTTON;
        out_reservation->button = message->u.pointer.button;
        return 1;
    }
    return 0;
}

static int mr_input_command_is_down(
    const mr_input_command *command,
    mr_input_release_reservation *out_reservation)
{
    memset(out_reservation, 0, sizeof(*out_reservation));
    if (command->kind == MR_INPUT_COMMAND_KEY) {
        if (command->value.key.action != MR_RDP_KEY_DOWN) {
            return 0;
        }
        out_reservation->kind = MR_INPUT_RELEASE_KEY;
        out_reservation->key_code = command->value.key.code;
        out_reservation->extended = command->value.key.extended;
        out_reservation->extended1 = command->value.key.extended1;
        return 1;
    }
    if (command->kind == MR_INPUT_COMMAND_POINTER &&
        command->value.pointer.kind == MR_RDP_POINTER_BUTTON &&
        command->value.pointer.action == MR_RDP_KEY_DOWN) {
        out_reservation->kind = MR_INPUT_RELEASE_BUTTON;
        out_reservation->button = command->value.pointer.button;
        return 1;
    }
    if (command->kind == MR_INPUT_COMMAND_TOUCH &&
        command->value.touch.action == MR_RDP_TOUCH_DOWN) {
        out_reservation->kind = MR_INPUT_RELEASE_TOUCH;
        out_reservation->contact_id = command->value.touch.contact_id;
        return 1;
    }
    if (command->kind == MR_INPUT_COMMAND_PEN &&
        command->value.pen.action == MR_RDP_PEN_DOWN) {
        out_reservation->kind = MR_INPUT_RELEASE_PEN;
        return 1;
    }
    return mr_input_macrdpx_transition(command, MRX_KEY_DOWN, MRX_POINTER_DOWN, out_reservation);
}

static int mr_input_command_is_up(
    const mr_input_command *command,
    mr_input_release_reservation *out_reservation)
{
    memset(out_reservation, 0, sizeof(*out_reservation));
    if (command->kind == MR_INPUT_COMMAND_KEY) {
        if (command->value.key.action != MR_RDP_KEY_UP) {
            return 0;
        }
        out_reservation->kind = MR_INPUT_RELEASE_KEY;
        out_reservation->key_code = command->value.key.code;
        out_reservation->extended = command->value.key.extended;
        out_reservation->extended1 = command->value.key.extended1;
        return 1;
    }
    if (command->kind == MR_INPUT_COMMAND_POINTER &&
        command->value.pointer.kind == MR_RDP_POINTER_BUTTON &&
        command->value.pointer.action == MR_RDP_KEY_UP) {
        out_reservation->kind = MR_INPUT_RELEASE_BUTTON;
        out_reservation->button = command->value.pointer.button;
        return 1;
    }
    if (command->kind == MR_INPUT_COMMAND_TOUCH &&
        (command->value.touch.action == MR_RDP_TOUCH_UP ||
         command->value.touch.action == MR_RDP_TOUCH_CANCEL)) {
        out_reservation->kind = MR_INPUT_RELEASE_TOUCH;
        out_reservation->contact_id = command->value.touch.contact_id;
        return 1;
    }
    if (command->kind == MR_INPUT_COMMAND_PEN &&
        command->value.pen.action == MR_RDP_PEN_UP) {
        out_reservation->kind = MR_INPUT_RELEASE_PEN;
        return 1;
    }
    return mr_input_macrdpx_transition(command, MRX_KEY_UP, MRX_POINTER_UP, out_reservation);
}

static int mr_input_release_equal(
    const mr_input_release_reservation *left,
    const mr_input_release_reservation *right)
{
    if (left->kind != right->kind) {
        return 0;
    }
    if (left->kind == MR_INPUT_RELEASE_KEY || left->kind == MR_INPUT_RELEASE_MAC_KEY) {
        return left->key_code == right->key_code &&
            left->extended == right->extended &&
            left->extended1 == right->extended1;
    }
    if (left->kind == MR_INPUT_RELEASE_TOUCH) {
        return left->contact_id == right->contact_id;
    }
    if (left->kind == MR_INPUT_RELEASE_PEN) {
        return 1;
    }
    return left->button == right->button;
}

static size_t mr_input_find_reservation(
    const mr_input_command_queue *queue,
    const mr_input_release_reservation *reservation)
{
    size_t index;
    for (index = 0u; index < queue->reservation_count; ++index) {
        if (mr_input_release_equal(&queue->reservations[index], reservation)) {
            return index;
        }
    }
    return SIZE_MAX;
}

static void mr_input_remove_reservation(
    mr_input_command_queue *queue,
    size_t reservation_index)
{
    size_t index;
    for (index = reservation_index;
         index + 1u < queue->reservation_count;
         ++index) {
        queue->reservations[index] = queue->reservations[index + 1u];
    }
    --queue->reservation_count;
}

/* A gesture's continuing scroll events, of one kind, sum into one. */
static int mr_input_scroll_mergeable(const mrx_scroll *tail, const mrx_scroll *next)
{
    const uint8_t continuing = MRX_PHASE_CHANGED;
    return tail->unit == next->unit && tail->flags == next->flags &&
        tail->modifier_flags == next->modifier_flags &&
        tail->phase == next->phase && tail->momentum_phase == next->momentum_phase &&
        ((tail->phase == continuing && tail->momentum_phase == MRX_PHASE_NONE) ||
         (tail->phase == MRX_PHASE_NONE &&
          (tail->momentum_phase == continuing || tail->momentum_phase == MRX_PHASE_NONE)));
}

/* Two CHANGED events of one gesture: their deltas add up (magnify,
 * rotate), or the later progress stands (Dock swipes). Beginnings and ends
 * are kept, so the server still sees the gesture's shape. */
static int mr_input_gesture_mergeable(const mrx_gesture *tail, const mrx_gesture *next)
{
    return tail->kind == next->kind && tail->kind != MRX_GESTURE_SMART_ZOOM &&
        tail->phase == MRX_PHASE_CHANGED && next->phase == MRX_PHASE_CHANGED;
}

static mr_input_enqueue_result mr_input_enqueue_macrdpx(
    mr_input_command_queue *queue,
    const mr_input_command *command)
{
    const mrx_message *message = &command->value.macrdpx;
    if (queue->count > 0u) {
        mr_input_command *tail = &queue->commands[
            mr_input_queue_index(queue, queue->count - 1u)];
        const mrx_message *previous = &tail->value.macrdpx;
        if (tail->kind == MR_INPUT_COMMAND_MACRDPX && previous->type == message->type) {
            if (message->type == MRX_MSG_POINTER &&
                message->u.pointer.action == MRX_POINTER_MOVE &&
                previous->u.pointer.action == MRX_POINTER_MOVE) {
                *tail = *command;
                return MR_INPUT_ENQUEUE_COALESCED;
            }
            if (message->type == MRX_MSG_GESTURE &&
                mr_input_gesture_mergeable(&previous->u.gesture, &message->u.gesture)) {
                mrx_gesture *merged = &tail->value.macrdpx.u.gesture;
                if (message->u.gesture.kind == MRX_GESTURE_MAGNIFY ||
                    message->u.gesture.kind == MRX_GESTURE_ROTATE) {
                    merged->value += message->u.gesture.value;
                } else {
                    /* A Dock swipe's progress is a total: the newer one. */
                    merged->value = message->u.gesture.value;
                }
                merged->modifier_flags = message->u.gesture.modifier_flags;
                return MR_INPUT_ENQUEUE_COALESCED;
            }
            if (message->type == MRX_MSG_SCROLL &&
                mr_input_scroll_mergeable(&previous->u.scroll, &message->u.scroll)) {
                tail->value.macrdpx.u.scroll.delta_x += message->u.scroll.delta_x;
                tail->value.macrdpx.u.scroll.delta_y += message->u.scroll.delta_y;
                return MR_INPUT_ENQUEUE_COALESCED;
            }
        }
    }
    if (mr_input_queue_free(queue) == 0u) {
        return MR_INPUT_ENQUEUE_DROPPED;
    }
    mr_input_queue_append(queue, command);
    return MR_INPUT_ENQUEUE_QUEUED;
}

int mr_input_command_queue_init(
    mr_input_command_queue *queue,
    size_t capacity)
{
    if (queue == NULL || capacity == 0u ||
        capacity > MR_INPUT_COMMAND_QUEUE_CAPACITY) {
        return 0;
    }
    memset(queue, 0, sizeof(*queue));
    queue->capacity = capacity;
    return 1;
}

void mr_input_command_queue_reset(mr_input_command_queue *queue)
{
    if (queue == NULL) {
        return;
    }
    queue->head = 0u;
    queue->count = 0u;
    queue->reservation_count = 0u;
}

mr_input_enqueue_result mr_input_command_queue_enqueue(
    mr_input_command_queue *queue,
    const mr_input_command *command)
{
    mr_input_release_reservation reservation;
    size_t index;
    if (queue == NULL || command == NULL || queue->capacity == 0u ||
        queue->capacity > MR_INPUT_COMMAND_QUEUE_CAPACITY) {
        return MR_INPUT_ENQUEUE_INVALID;
    }

    if (mr_input_command_is_down(command, &reservation)) {
        index = mr_input_find_reservation(queue, &reservation);
        if (index != SIZE_MAX) {
            /* Key repeat or a duplicate pointer down does not create another
             * future release obligation. It may be dropped under pressure
             * without risking a stuck remote transition. */
            if (mr_input_queue_free(queue) == 0u) {
                return MR_INPUT_ENQUEUE_DROPPED;
            }
            mr_input_queue_append(queue, command);
            return MR_INPUT_ENQUEUE_QUEUED;
        }
        if (mr_input_queue_free(queue) < 2u) {
            return MR_INPUT_ENQUEUE_TRANSITION_OVERFLOW;
        }
        mr_input_queue_append(queue, command);
        queue->reservations[queue->reservation_count] = reservation;
        ++queue->reservation_count;
        return MR_INPUT_ENQUEUE_QUEUED;
    }

    if (mr_input_command_is_up(command, &reservation)) {
        index = mr_input_find_reservation(queue, &reservation);
        if (index != SIZE_MAX) {
            mr_input_remove_reservation(queue, index);
            mr_input_queue_append(queue, command);
            return MR_INPUT_ENQUEUE_QUEUED;
        }
        if (mr_input_queue_free(queue) == 0u) {
            return MR_INPUT_ENQUEUE_TRANSITION_OVERFLOW;
        }
        mr_input_queue_append(queue, command);
        return MR_INPUT_ENQUEUE_QUEUED;
    }

    if (command->kind == MR_INPUT_COMMAND_UNICODE) {
        /* Typed text keeps its order but owes the server nothing afterwards,
         * so under pressure it is dropped rather than failing the session. */
        if (mr_input_queue_free(queue) == 0u) {
            return MR_INPUT_ENQUEUE_DROPPED;
        }
        mr_input_queue_append(queue, command);
        return MR_INPUT_ENQUEUE_QUEUED;
    }
    if (command->kind == MR_INPUT_COMMAND_TOUCH || command->kind == MR_INPUT_COMMAND_PEN) {
        /* A move for the same contact - or the pen's hover or move - replaces
         * the one right before it; nothing else is ever reordered. */
        if (queue->count > 0u) {
            mr_input_command *tail = &queue->commands[
                mr_input_queue_index(queue, queue->count - 1u)];
            if (command->kind == MR_INPUT_COMMAND_TOUCH &&
                tail->kind == MR_INPUT_COMMAND_TOUCH &&
                tail->value.touch.action == MR_RDP_TOUCH_MOVE &&
                command->value.touch.action == MR_RDP_TOUCH_MOVE &&
                tail->value.touch.contact_id == command->value.touch.contact_id) {
                *tail = *command;
                return MR_INPUT_ENQUEUE_COALESCED;
            }
            if (command->kind == MR_INPUT_COMMAND_PEN &&
                tail->kind == MR_INPUT_COMMAND_PEN &&
                tail->value.pen.action == command->value.pen.action &&
                (command->value.pen.action == MR_RDP_PEN_HOVER ||
                 command->value.pen.action == MR_RDP_PEN_MOVE)) {
                *tail = *command;
                return MR_INPUT_ENQUEUE_COALESCED;
            }
        }
        if (mr_input_queue_free(queue) > 0u) {
            mr_input_queue_append(queue, command);
            return MR_INPUT_ENQUEUE_QUEUED;
        }
        return MR_INPUT_ENQUEUE_DROPPED;
    }
    if (command->kind == MR_INPUT_COMMAND_MACRDPX) {
        return mr_input_enqueue_macrdpx(queue, command);
    }
    if (command->kind != MR_INPUT_COMMAND_POINTER) {
        return MR_INPUT_ENQUEUE_INVALID;
    }
    if (command->value.pointer.kind == MR_RDP_POINTER_MOVE) {
        if (queue->count > 0u) {
            mr_input_command *tail = &queue->commands[
                mr_input_queue_index(queue, queue->count - 1u)];
            if (tail->kind == MR_INPUT_COMMAND_POINTER &&
                tail->value.pointer.kind == MR_RDP_POINTER_MOVE) {
                *tail = *command;
                return MR_INPUT_ENQUEUE_COALESCED;
            }
        }
        if (mr_input_queue_free(queue) > 0u) {
            mr_input_queue_append(queue, command);
            return MR_INPUT_ENQUEUE_QUEUED;
        }
        /* Never replace an older move across a key/button/wheel boundary:
         * doing so would reorder pointer state relative to that transition. */
        return MR_INPUT_ENQUEUE_DROPPED;
    }
    if (command->value.pointer.kind == MR_RDP_POINTER_WHEEL) {
        if (queue->count > 0u) {
            mr_input_command *tail = &queue->commands[
                mr_input_queue_index(queue, queue->count - 1u)];
            if (tail->kind == MR_INPUT_COMMAND_POINTER &&
                tail->value.pointer.kind == MR_RDP_POINTER_WHEEL) {
                mr_input_accumulate_wheel(tail, command);
                return MR_INPUT_ENQUEUE_COALESCED;
            }
        }
        if (mr_input_queue_free(queue) > 0u) {
            mr_input_queue_append(queue, command);
            return MR_INPUT_ENQUEUE_QUEUED;
        }
        if (queue->count > 0u) {
            mr_input_command *tail = &queue->commands[
                mr_input_queue_index(queue, queue->count - 1u)];
            if (tail->kind == MR_INPUT_COMMAND_POINTER &&
                tail->value.pointer.kind == MR_RDP_POINTER_MOVE) {
                /* A wheel event carries its own current coordinates, so it
                 * may replace only the immediately preceding move. */
                *tail = *command;
                return MR_INPUT_ENQUEUE_COALESCED;
            }
        }
        return MR_INPUT_ENQUEUE_DROPPED;
    }
    return MR_INPUT_ENQUEUE_INVALID;
}

int mr_input_command_queue_dequeue(
    mr_input_command_queue *queue,
    mr_input_command *out_command)
{
    if (queue == NULL || out_command == NULL || queue->capacity == 0u ||
        queue->count == 0u) {
        return 0;
    }
    *out_command = queue->commands[queue->head];
    queue->head = (queue->head + 1u) % queue->capacity;
    --queue->count;
    if (queue->count == 0u) {
        queue->head = 0u;
    }
    return 1;
}

size_t mr_input_command_queue_count(const mr_input_command_queue *queue)
{
    return queue == NULL ? 0u : queue->count;
}

size_t mr_input_command_queue_reserved_count(
    const mr_input_command_queue *queue)
{
    return queue == NULL ? 0u : queue->reservation_count;
}
