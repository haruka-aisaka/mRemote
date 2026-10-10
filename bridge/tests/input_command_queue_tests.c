#include "input_command_queue.h"

#include <limits.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "%s:%d: check failed: %s\n",                    \
                    __FILE__, __LINE__, #condition);                            \
            return 0;                                                           \
        }                                                                       \
    } while (0)

static mr_input_command key_command(
    uint16_t code,
    uint8_t extended,
    uint8_t extended1,
    mr_rdp_key_action action)
{
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_KEY;
    command.value.key.struct_size = (uint32_t)sizeof(command.value.key);
    command.value.key.code = code;
    command.value.key.extended = extended;
    command.value.key.extended1 = extended1;
    command.value.key.action = action;
    return command;
}

static mr_input_command button_command(
    mr_rdp_pointer_button button,
    mr_rdp_key_action action)
{
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_POINTER;
    command.value.pointer.struct_size =
        (uint32_t)sizeof(command.value.pointer);
    command.value.pointer.kind = MR_RDP_POINTER_BUTTON;
    command.value.pointer.button = button;
    command.value.pointer.action = action;
    return command;
}

static mr_input_command move_command(uint32_t x, uint32_t y)
{
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_POINTER;
    command.value.pointer.struct_size =
        (uint32_t)sizeof(command.value.pointer);
    command.value.pointer.kind = MR_RDP_POINTER_MOVE;
    command.value.pointer.x = x;
    command.value.pointer.y = y;
    return command;
}

static mr_input_command wheel_command(
    uint32_t x,
    uint32_t y,
    int32_t wheel_x,
    int32_t wheel_y)
{
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_POINTER;
    command.value.pointer.struct_size =
        (uint32_t)sizeof(command.value.pointer);
    command.value.pointer.kind = MR_RDP_POINTER_WHEEL;
    command.value.pointer.x = x;
    command.value.pointer.y = y;
    command.value.pointer.wheel_x = wheel_x;
    command.value.pointer.wheel_y = wheel_y;
    return command;
}

static int test_fifo(void)
{
    mr_input_command_queue queue;
    mr_input_command first = key_command(0x1eu, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command second = wheel_command(12u, 34u, -10, 20);
    mr_input_command third = key_command(0x30u, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 4u));
    CHECK(mr_input_command_queue_enqueue(&queue, &first) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &second) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &third) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.kind == MR_INPUT_COMMAND_KEY &&
          output.value.key.code == first.value.key.code);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.kind == MR_INPUT_COMMAND_POINTER &&
          output.value.pointer.kind == MR_RDP_POINTER_WHEEL &&
          output.value.pointer.wheel_y == 20);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.kind == MR_INPUT_COMMAND_KEY &&
          output.value.key.code == third.value.key.code);
    CHECK(!mr_input_command_queue_dequeue(&queue, &output));
    return 1;
}

static int test_matching_up_uses_reserved_slot_when_full(void)
{
    mr_input_command_queue queue;
    mr_input_command down = key_command(0x79u, 0u, 0u, MR_RDP_KEY_DOWN);
    mr_input_command move = move_command(100u, 200u);
    mr_input_command up = key_command(0x79u, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 3u));
    CHECK(mr_input_command_queue_enqueue(&queue, &down) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &move) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_count(&queue) == 2u);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &up) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_count(&queue) == 3u);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.key.action == MR_RDP_KEY_DOWN);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.kind == MR_RDP_POINTER_MOVE);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.key.action == MR_RDP_KEY_UP);
    return 1;
}

static int test_new_down_requires_command_and_release_slots(void)
{
    mr_input_command_queue queue;
    mr_input_command first = key_command(0x1eu, 0u, 0u, MR_RDP_KEY_DOWN);
    mr_input_command second = key_command(0x30u, 0u, 0u, MR_RDP_KEY_DOWN);
    CHECK(mr_input_command_queue_init(&queue, 3u));
    CHECK(mr_input_command_queue_enqueue(&queue, &first) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &second) ==
          MR_INPUT_ENQUEUE_TRANSITION_OVERFLOW);
    CHECK(mr_input_command_queue_count(&queue) == 1u);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    return 1;
}

static int test_orphan_up_overflow_is_fatal(void)
{
    mr_input_command_queue queue;
    mr_input_command first = key_command(0x1eu, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command second = key_command(0x30u, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command third = key_command(0x2eu, 0u, 0u, MR_RDP_KEY_UP);
    CHECK(mr_input_command_queue_init(&queue, 2u));
    CHECK(mr_input_command_queue_enqueue(&queue, &first) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &second) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &third) ==
          MR_INPUT_ENQUEUE_TRANSITION_OVERFLOW);
    CHECK(mr_input_command_queue_count(&queue) == 2u);
    return 1;
}

static int test_move_does_not_cross_transition_at_capacity(void)
{
    mr_input_command_queue queue;
    mr_input_command old_move = move_command(10u, 20u);
    mr_input_command transition =
        key_command(0x1eu, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command new_move = move_command(30u, 40u);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 2u));
    CHECK(mr_input_command_queue_enqueue(&queue, &old_move) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &transition) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &new_move) ==
          MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.kind == MR_RDP_POINTER_MOVE &&
          output.value.pointer.x == 10u && output.value.pointer.y == 20u);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.kind == MR_INPUT_COMMAND_KEY);
    return 1;
}

static int test_move_does_not_cross_button_down_at_capacity(void)
{
    mr_input_command_queue queue;
    mr_input_command old_move = move_command(10u, 20u);
    mr_input_command button_down = button_command(
        MR_RDP_POINTER_BUTTON_LEFT, MR_RDP_KEY_DOWN);
    mr_input_command new_move = move_command(30u, 40u);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 3u));
    CHECK(mr_input_command_queue_enqueue(&queue, &old_move) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &button_down) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &new_move) ==
          MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.kind == MR_RDP_POINTER_MOVE &&
          output.value.pointer.x == 10u && output.value.pointer.y == 20u);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.kind == MR_RDP_POINTER_BUTTON &&
          output.value.pointer.button == MR_RDP_POINTER_BUTTON_LEFT &&
          output.value.pointer.action == MR_RDP_KEY_DOWN);
    return 1;
}

static int test_wheel_accumulates_and_saturates(void)
{
    mr_input_command_queue queue;
    mr_input_command first = wheel_command(
        1u, 2u, INT32_MAX - 4, INT32_MIN + 4);
    mr_input_command second = wheel_command(90u, 91u, 10, -10);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 2u));
    CHECK(mr_input_command_queue_enqueue(&queue, &first) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &second) ==
          MR_INPUT_ENQUEUE_COALESCED);
    CHECK(mr_input_command_queue_count(&queue) == 1u);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.wheel_x == MR_RDP_MAX_WHEEL_DELTA);
    CHECK(output.value.pointer.wheel_y == -MR_RDP_MAX_WHEEL_DELTA);
    CHECK(output.value.pointer.x == 90u && output.value.pointer.y == 91u);
    return 1;
}

static int test_first_wheel_evicts_a_move(void)
{
    mr_input_command_queue queue;
    mr_input_command move = move_command(10u, 20u);
    mr_input_command transition =
        key_command(0x1eu, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command wheel = wheel_command(30u, 40u, 120, -120);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 2u));
    CHECK(mr_input_command_queue_enqueue(&queue, &transition) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &move) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &wheel) ==
          MR_INPUT_ENQUEUE_COALESCED);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.kind == MR_INPUT_COMMAND_KEY);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.kind == MR_RDP_POINTER_WHEEL &&
          output.value.pointer.wheel_x == 120 &&
          output.value.pointer.wheel_y == -120);
    return 1;
}

static int test_button_reservation_uses_button_identity(void)
{
    mr_input_command_queue queue;
    mr_input_command left_down = button_command(
        MR_RDP_POINTER_BUTTON_LEFT, MR_RDP_KEY_DOWN);
    mr_input_command right_up = button_command(
        MR_RDP_POINTER_BUTTON_RIGHT, MR_RDP_KEY_UP);
    mr_input_command left_up = button_command(
        MR_RDP_POINTER_BUTTON_LEFT, MR_RDP_KEY_UP);
    CHECK(mr_input_command_queue_init(&queue, 4u));
    CHECK(mr_input_command_queue_enqueue(&queue, &left_down) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &right_up) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &left_up) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    CHECK(mr_input_command_queue_count(&queue) == 3u);
    return 1;
}

static int test_key_reservation_uses_extended_selectors(void)
{
    mr_input_command_queue queue;
    mr_input_command down = key_command(0x1du, 1u, 0u, MR_RDP_KEY_DOWN);
    mr_input_command mismatched_up =
        key_command(0x1du, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command matching_up =
        key_command(0x1du, 1u, 0u, MR_RDP_KEY_UP);
    CHECK(mr_input_command_queue_init(&queue, 4u));
    CHECK(mr_input_command_queue_enqueue(&queue, &down) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &mismatched_up) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &matching_up) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    return 1;
}

static int test_wheel_does_not_cross_transition_at_capacity(void)
{
    mr_input_command_queue queue;
    mr_input_command first = wheel_command(1u, 2u, 10, 20);
    mr_input_command transition =
        key_command(0x1eu, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command second = wheel_command(3u, 4u, -3, 5);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 2u));
    CHECK(mr_input_command_queue_enqueue(&queue, &first) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &transition) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &second) ==
          MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.kind == MR_RDP_POINTER_WHEEL &&
          output.value.pointer.wheel_x == 10 &&
          output.value.pointer.wheel_y == 20 &&
          output.value.pointer.x == 1u && output.value.pointer.y == 2u);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.kind == MR_INPUT_COMMAND_KEY);
    return 1;
}

static int test_wheel_does_not_cross_modifier_down_at_capacity(void)
{
    mr_input_command_queue queue;
    mr_input_command first = wheel_command(1u, 2u, 10, 20);
    mr_input_command modifier_down =
        key_command(0x1du, 0u, 0u, MR_RDP_KEY_DOWN);
    mr_input_command second = wheel_command(3u, 4u, -3, 5);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 3u));
    CHECK(mr_input_command_queue_enqueue(&queue, &first) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &modifier_down) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &second) ==
          MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.kind == MR_RDP_POINTER_WHEEL &&
          output.value.pointer.wheel_x == 10 &&
          output.value.pointer.wheel_y == 20 &&
          output.value.pointer.x == 1u && output.value.pointer.y == 2u);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.kind == MR_INPUT_COMMAND_KEY &&
          output.value.key.code == 0x1du &&
          output.value.key.action == MR_RDP_KEY_DOWN);
    return 1;
}

static int test_duplicate_down_reuses_one_release_reservation(void)
{
    mr_input_command_queue queue;
    mr_input_command down = key_command(0x1eu, 0u, 0u, MR_RDP_KEY_DOWN);
    mr_input_command up = key_command(0x1eu, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 2u));
    CHECK(mr_input_command_queue_enqueue(&queue, &down) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_count(&queue) == 1u);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &down) ==
          MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &up) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.key.action == MR_RDP_KEY_DOWN);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.key.action == MR_RDP_KEY_UP);
    return 1;
}

static int test_duplicate_button_down_reuses_one_release_reservation(void)
{
    mr_input_command_queue queue;
    mr_input_command down = button_command(
        MR_RDP_POINTER_BUTTON_LEFT, MR_RDP_KEY_DOWN);
    mr_input_command up = button_command(
        MR_RDP_POINTER_BUTTON_LEFT, MR_RDP_KEY_UP);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 2u));
    CHECK(mr_input_command_queue_enqueue(&queue, &down) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &down) ==
          MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &up) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.action == MR_RDP_KEY_DOWN);
    CHECK(mr_input_command_queue_dequeue(&queue, &output));
    CHECK(output.value.pointer.action == MR_RDP_KEY_UP);
    return 1;
}

static int test_reset_discards_commands_and_reservations(void)
{
    mr_input_command_queue queue;
    mr_input_command down = key_command(0x1eu, 0u, 0u, MR_RDP_KEY_DOWN);
    mr_input_command output;
    CHECK(mr_input_command_queue_init(&queue, 4u));
    CHECK(mr_input_command_queue_enqueue(&queue, &down) ==
          MR_INPUT_ENQUEUE_QUEUED);
    mr_input_command_queue_reset(&queue);
    CHECK(mr_input_command_queue_count(&queue) == 0u);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    CHECK(!mr_input_command_queue_dequeue(&queue, &output));
    CHECK(mr_input_command_queue_enqueue(&queue, &down) ==
          MR_INPUT_ENQUEUE_QUEUED);
    return 1;
}

static int test_multiple_release_reservations(void)
{
    mr_input_command_queue queue;
    mr_input_command downs[] = {
        key_command(0x1eu, 0u, 0u, MR_RDP_KEY_DOWN),
        key_command(0x1du, 1u, 0u, MR_RDP_KEY_DOWN),
        button_command(MR_RDP_POINTER_BUTTON_LEFT, MR_RDP_KEY_DOWN)
    };
    mr_input_command ups[] = {
        button_command(MR_RDP_POINTER_BUTTON_LEFT, MR_RDP_KEY_UP),
        key_command(0x1du, 1u, 0u, MR_RDP_KEY_UP),
        key_command(0x1eu, 0u, 0u, MR_RDP_KEY_UP)
    };
    mr_input_command output;
    size_t index;
    CHECK(mr_input_command_queue_init(&queue, 6u));
    for (index = 0u; index < sizeof(downs) / sizeof(downs[0]); ++index) {
        CHECK(mr_input_command_queue_enqueue(&queue, &downs[index]) ==
              MR_INPUT_ENQUEUE_QUEUED);
    }
    CHECK(mr_input_command_queue_reserved_count(&queue) == 3u);
    for (index = 0u; index < sizeof(downs) / sizeof(downs[0]); ++index) {
        CHECK(mr_input_command_queue_dequeue(&queue, &output));
    }
    CHECK(mr_input_command_queue_count(&queue) == 0u);
    for (index = 0u; index < sizeof(ups) / sizeof(ups[0]); ++index) {
        CHECK(mr_input_command_queue_enqueue(&queue, &ups[index]) ==
              MR_INPUT_ENQUEUE_QUEUED);
    }
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    CHECK(mr_input_command_queue_count(&queue) == 3u);
    return 1;
}

static int test_non_transition_drops_only_without_coalescing_route(void)
{
    mr_input_command_queue queue;
    mr_input_command transition =
        key_command(0x1eu, 0u, 0u, MR_RDP_KEY_UP);
    mr_input_command move = move_command(1u, 2u);
    mr_input_command wheel = wheel_command(3u, 4u, 0, 120);
    CHECK(mr_input_command_queue_init(&queue, 1u));
    CHECK(mr_input_command_queue_enqueue(&queue, &transition) ==
          MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &move) ==
          MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_enqueue(&queue, &wheel) ==
          MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_count(&queue) == 1u);
    return 1;
}

typedef int (*test_function)(void);

typedef struct test_case {
    const char *name;
    test_function function;
} test_case;

static int test_unicode_tap_owes_nothing_and_drops_when_full(void)
{
    mr_input_command_queue queue;
    mr_input_command unicode;
    mr_input_command down = key_command(0x1du, 0u, 0u, MR_RDP_KEY_DOWN);
    mr_input_command out;
    memset(&unicode, 0, sizeof(unicode));
    unicode.kind = MR_INPUT_COMMAND_UNICODE;
    mr_rdp_unicode_event_init(&unicode.value.unicode);
    unicode.value.unicode.code_unit = 0x3042u;
    CHECK(mr_input_command_queue_init(&queue, 3u));
    CHECK(mr_input_command_queue_enqueue(&queue, &down) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &unicode) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    /* The modifier's release slot is never given to typed text. */
    CHECK(mr_input_command_queue_enqueue(&queue, &unicode) == MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.kind == MR_INPUT_COMMAND_KEY);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) &&
          out.kind == MR_INPUT_COMMAND_UNICODE && out.value.unicode.code_unit == 0x3042u);
    return 1;
}

static mr_input_command touch_command(uint32_t contact, mr_rdp_touch_action action, uint32_t x)
{
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_TOUCH;
    mr_rdp_touch_event_init(&command.value.touch);
    command.value.touch.contact_id = contact;
    command.value.touch.action = action;
    command.value.touch.x = x;
    return command;
}

static mr_input_command pen_command(mr_rdp_pen_action action, uint32_t x)
{
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_PEN;
    mr_rdp_pen_event_init(&command.value.pen);
    command.value.pen.action = action;
    command.value.pen.x = x;
    return command;
}

static int test_touch_contacts_owe_their_release(void)
{
    mr_input_command_queue queue;
    mr_input_command out;
    mr_input_command first_down = touch_command(1u, MR_RDP_TOUCH_DOWN, 0u);
    mr_input_command second_down = touch_command(2u, MR_RDP_TOUCH_DOWN, 0u);
    mr_input_command first_move = touch_command(1u, MR_RDP_TOUCH_MOVE, 10u);
    mr_input_command first_later = touch_command(1u, MR_RDP_TOUCH_MOVE, 20u);
    mr_input_command second_move = touch_command(2u, MR_RDP_TOUCH_MOVE, 30u);
    mr_input_command first_up = touch_command(1u, MR_RDP_TOUCH_UP, 20u);
    mr_input_command second_cancel = touch_command(2u, MR_RDP_TOUCH_CANCEL, 30u);
    CHECK(mr_input_command_queue_init(&queue, 8u));
    CHECK(mr_input_command_queue_enqueue(&queue, &first_down) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &second_down) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 2u);
    CHECK(mr_input_command_queue_enqueue(&queue, &first_move) == MR_INPUT_ENQUEUE_QUEUED);
    /* Only a move of the same contact right before it is replaced. */
    CHECK(mr_input_command_queue_enqueue(&queue, &first_later) == MR_INPUT_ENQUEUE_COALESCED);
    CHECK(mr_input_command_queue_enqueue(&queue, &second_move) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &first_up) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &second_cancel) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    CHECK(mr_input_command_queue_count(&queue) == 6u);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.touch.contact_id == 1u);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.touch.contact_id == 2u);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.touch.x == 20u);
    return 1;
}

static int test_a_full_queue_keeps_room_for_a_lift(void)
{
    mr_input_command_queue queue;
    mr_input_command down = touch_command(4u, MR_RDP_TOUCH_DOWN, 0u);
    mr_input_command move = touch_command(4u, MR_RDP_TOUCH_MOVE, 1u);
    mr_input_command other = touch_command(5u, MR_RDP_TOUCH_MOVE, 1u);
    mr_input_command up = touch_command(4u, MR_RDP_TOUCH_UP, 1u);
    CHECK(mr_input_command_queue_init(&queue, 3u));
    CHECK(mr_input_command_queue_enqueue(&queue, &down) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &move) == MR_INPUT_ENQUEUE_QUEUED);
    /* The last slot is the lift's: another contact's move is dropped. */
    CHECK(mr_input_command_queue_enqueue(&queue, &other) == MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_enqueue(&queue, &up) == MR_INPUT_ENQUEUE_QUEUED);
    return 1;
}

static int test_pen_hover_and_moves_coalesce(void)
{
    mr_input_command_queue queue;
    mr_input_command out;
    mr_input_command hover = pen_command(MR_RDP_PEN_HOVER, 1u);
    mr_input_command hover_later = pen_command(MR_RDP_PEN_HOVER, 2u);
    mr_input_command down = pen_command(MR_RDP_PEN_DOWN, 2u);
    mr_input_command move = pen_command(MR_RDP_PEN_MOVE, 3u);
    mr_input_command move_later = pen_command(MR_RDP_PEN_MOVE, 4u);
    mr_input_command up = pen_command(MR_RDP_PEN_UP, 4u);
    CHECK(mr_input_command_queue_init(&queue, 8u));
    CHECK(mr_input_command_queue_enqueue(&queue, &hover) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &hover_later) == MR_INPUT_ENQUEUE_COALESCED);
    CHECK(mr_input_command_queue_enqueue(&queue, &down) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &move) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_enqueue(&queue, &move_later) == MR_INPUT_ENQUEUE_COALESCED);
    CHECK(mr_input_command_queue_enqueue(&queue, &up) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.pen.x == 2u);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.pen.action == MR_RDP_PEN_DOWN);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.pen.x == 4u);
    return 1;
}

static mr_input_command mac_command(mrx_message_type type)
{
    mr_input_command command;
    memset(&command, 0, sizeof(command));
    command.kind = MR_INPUT_COMMAND_MACRDPX;
    command.value.macrdpx.type = type;
    return command;
}

static int test_mac_moves_and_scrolls_coalesce(void)
{
    mr_input_command_queue queue;
    mr_input_command move = mac_command(MRX_MSG_POINTER);
    mr_input_command scroll = mac_command(MRX_MSG_SCROLL);
    mr_input_command out;
    CHECK(mr_input_command_queue_init(&queue, 8u));
    move.value.macrdpx.u.pointer.x = 1.0f;
    CHECK(mr_input_command_queue_enqueue(&queue, &move) == MR_INPUT_ENQUEUE_QUEUED);
    move.value.macrdpx.u.pointer.x = 2.0f;
    CHECK(mr_input_command_queue_enqueue(&queue, &move) == MR_INPUT_ENQUEUE_COALESCED);
    scroll.value.macrdpx.u.scroll.phase = MRX_PHASE_BEGAN;
    scroll.value.macrdpx.u.scroll.delta_y = 1.0f;
    CHECK(mr_input_command_queue_enqueue(&queue, &scroll) == MR_INPUT_ENQUEUE_QUEUED);
    /* BEGAN does not merge; CHANGED events do, summing their deltas. */
    scroll.value.macrdpx.u.scroll.phase = MRX_PHASE_CHANGED;
    CHECK(mr_input_command_queue_enqueue(&queue, &scroll) == MR_INPUT_ENQUEUE_QUEUED);
    scroll.value.macrdpx.u.scroll.delta_y = 2.5f;
    CHECK(mr_input_command_queue_enqueue(&queue, &scroll) == MR_INPUT_ENQUEUE_COALESCED);
    scroll.value.macrdpx.u.scroll.phase = MRX_PHASE_ENDED;
    scroll.value.macrdpx.u.scroll.delta_y = 0.0f;
    CHECK(mr_input_command_queue_enqueue(&queue, &scroll) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_count(&queue) == 4u);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.macrdpx.u.pointer.x == 2.0f);
    CHECK(mr_input_command_queue_dequeue(&queue, &out));
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.macrdpx.u.scroll.delta_y == 3.5f);
    return 1;
}

static int test_mac_gestures_coalesce_their_changes(void)
{
    mr_input_command_queue queue;
    mr_input_command pinch = mac_command(MRX_MSG_GESTURE);
    mr_input_command dock = mac_command(MRX_MSG_GESTURE);
    mr_input_command out;
    CHECK(mr_input_command_queue_init(&queue, 8u));
    pinch.value.macrdpx.u.gesture.kind = MRX_GESTURE_MAGNIFY;
    pinch.value.macrdpx.u.gesture.phase = MRX_PHASE_BEGAN;
    CHECK(mr_input_command_queue_enqueue(&queue, &pinch) == MR_INPUT_ENQUEUE_QUEUED);
    pinch.value.macrdpx.u.gesture.phase = MRX_PHASE_CHANGED;
    pinch.value.macrdpx.u.gesture.value = 0.25f;
    CHECK(mr_input_command_queue_enqueue(&queue, &pinch) == MR_INPUT_ENQUEUE_QUEUED);
    /* Magnification deltas add up. */
    CHECK(mr_input_command_queue_enqueue(&queue, &pinch) == MR_INPUT_ENQUEUE_COALESCED);
    dock.value.macrdpx.u.gesture.kind = MRX_GESTURE_DOCK_VERTICAL;
    dock.value.macrdpx.u.gesture.phase = MRX_PHASE_CHANGED;
    dock.value.macrdpx.u.gesture.value = 0.25f;
    CHECK(mr_input_command_queue_enqueue(&queue, &dock) == MR_INPUT_ENQUEUE_QUEUED);
    /* A Dock swipe's progress is a total: the later one stands. */
    dock.value.macrdpx.u.gesture.value = 0.75f;
    CHECK(mr_input_command_queue_enqueue(&queue, &dock) == MR_INPUT_ENQUEUE_COALESCED);
    dock.value.macrdpx.u.gesture.phase = MRX_PHASE_ENDED;
    CHECK(mr_input_command_queue_enqueue(&queue, &dock) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_count(&queue) == 4u);
    CHECK(mr_input_command_queue_dequeue(&queue, &out));
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.macrdpx.u.gesture.value == 0.5f);
    CHECK(mr_input_command_queue_dequeue(&queue, &out) && out.value.macrdpx.u.gesture.value == 0.75f);
    return 1;
}

static int test_mac_key_and_button_owe_their_release(void)
{
    mr_input_command_queue queue;
    mr_input_command down = mac_command(MRX_MSG_KEY);
    mr_input_command up = mac_command(MRX_MSG_KEY);
    mr_input_command click = mac_command(MRX_MSG_POINTER);
    mr_input_command filler = mac_command(MRX_MSG_MODIFIERS);
    CHECK(mr_input_command_queue_init(&queue, 4u));
    down.value.macrdpx.u.key.keycode = 13u;
    up.value.macrdpx.u.key.keycode = 13u;
    up.value.macrdpx.u.key.action = MRX_KEY_UP;
    click.value.macrdpx.u.pointer.action = MRX_POINTER_DOWN;
    click.value.macrdpx.u.pointer.button = MRX_BUTTON_RIGHT;
    CHECK(mr_input_command_queue_enqueue(&queue, &down) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 1u);
    CHECK(mr_input_command_queue_enqueue(&queue, &click) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 2u);
    /* Full: the reserved ups still fit, other messages are dropped. */
    CHECK(mr_input_command_queue_enqueue(&queue, &filler) == MR_INPUT_ENQUEUE_DROPPED);
    CHECK(mr_input_command_queue_enqueue(&queue, &up) == MR_INPUT_ENQUEUE_QUEUED);
    click.value.macrdpx.u.pointer.action = MRX_POINTER_UP;
    CHECK(mr_input_command_queue_enqueue(&queue, &click) == MR_INPUT_ENQUEUE_QUEUED);
    CHECK(mr_input_command_queue_reserved_count(&queue) == 0u);
    return 1;
}

int main(void)
{
    const test_case tests[] = {
        { "FIFO", test_fifo },
        { "matching up uses reserved slot", test_matching_up_uses_reserved_slot_when_full },
        { "new down requires two slots", test_new_down_requires_command_and_release_slots },
        { "orphan up overflow", test_orphan_up_overflow_is_fatal },
        { "move preserves transition order", test_move_does_not_cross_transition_at_capacity },
        { "move preserves button order", test_move_does_not_cross_button_down_at_capacity },
        { "wheel accumulation", test_wheel_accumulates_and_saturates },
        { "wheel evicts move", test_first_wheel_evicts_a_move },
        { "button identity", test_button_reservation_uses_button_identity },
        { "key selector identity", test_key_reservation_uses_extended_selectors },
        { "wheel preserves transition order", test_wheel_does_not_cross_transition_at_capacity },
        { "wheel preserves modifier order", test_wheel_does_not_cross_modifier_down_at_capacity },
        { "duplicate down reservation", test_duplicate_down_reuses_one_release_reservation },
        { "duplicate button reservation", test_duplicate_button_down_reuses_one_release_reservation },
        { "reset", test_reset_discards_commands_and_reservations },
        { "multiple reservations", test_multiple_release_reservations },
        { "non-transition drop", test_non_transition_drops_only_without_coalescing_route },
        { "unicode tap", test_unicode_tap_owes_nothing_and_drops_when_full },
        { "touch release", test_touch_contacts_owe_their_release },
        { "touch lift slot", test_a_full_queue_keeps_room_for_a_lift },
        { "pen coalescing", test_pen_hover_and_moves_coalesce },
        { "mac move/scroll coalescing", test_mac_moves_and_scrolls_coalesce },
        { "mac gesture coalescing", test_mac_gestures_coalesce_their_changes },
        { "mac key/button release", test_mac_key_and_button_owe_their_release }
    };
    size_t index;
    for (index = 0u; index < sizeof(tests) / sizeof(tests[0]); ++index) {
        if (!tests[index].function()) {
            fprintf(stderr, "FAILED: %s\n", tests[index].name);
            return 1;
        }
        printf("PASS: %s\n", tests[index].name);
    }
    return 0;
}
