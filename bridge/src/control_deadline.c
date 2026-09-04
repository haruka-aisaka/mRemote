#include "control_deadline.h"

#include <limits.h>
#include <stddef.h>
#include <string.h>

void mr_control_deadline_reset(mr_control_deadline *deadline)
{
    if (deadline != NULL) {
        memset(deadline, 0, sizeof(*deadline));
    }
}

void mr_control_deadline_arm(
    mr_control_deadline *deadline,
    uint64_t now_ms,
    uint64_t timeout_ms,
    uint8_t stage)
{
    if (deadline == NULL) {
        return;
    }
    deadline->expires_at_ms = timeout_ms > UINT64_MAX - now_ms
        ? UINT64_MAX
        : now_ms + timeout_ms;
    deadline->stage = stage;
    deadline->armed = 1u;
}

int mr_control_deadline_is_armed_for(
    const mr_control_deadline *deadline,
    uint8_t stage)
{
    return deadline != NULL && deadline->armed && deadline->stage == stage;
}

uint32_t mr_control_deadline_remaining_ms(
    const mr_control_deadline *deadline,
    uint64_t now_ms)
{
    uint64_t remaining;
    if (deadline == NULL || !deadline->armed) {
        return UINT32_MAX;
    }
    if (now_ms >= deadline->expires_at_ms) {
        return 0u;
    }
    remaining = deadline->expires_at_ms - now_ms;
    return remaining >= UINT32_MAX
        ? UINT32_MAX - 1u
        : (uint32_t)remaining;
}

int mr_control_deadline_take_expired(
    mr_control_deadline *deadline,
    uint64_t now_ms,
    uint8_t *out_stage)
{
    uint8_t stage;
    if (deadline == NULL || !deadline->armed ||
        now_ms < deadline->expires_at_ms) {
        return 0;
    }
    stage = deadline->stage;
    mr_control_deadline_reset(deadline);
    if (out_stage != NULL) {
        *out_stage = stage;
    }
    return 1;
}
