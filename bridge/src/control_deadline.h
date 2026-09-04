#ifndef MREMOTE_CONTROL_DEADLINE_H
#define MREMOTE_CONTROL_DEADLINE_H

#include <stdint.h>

typedef struct mr_control_deadline {
    uint64_t expires_at_ms;
    uint8_t stage;
    uint8_t armed;
} mr_control_deadline;

void mr_control_deadline_reset(mr_control_deadline *deadline);

void mr_control_deadline_arm(
    mr_control_deadline *deadline,
    uint64_t now_ms,
    uint64_t timeout_ms,
    uint8_t stage);

int mr_control_deadline_is_armed_for(
    const mr_control_deadline *deadline,
    uint8_t stage);

/* UINT32_MAX represents an unarmed/infinite wait. Armed waits are capped at
 * UINT32_MAX - 1 so a very distant deadline is never mistaken for infinite. */
uint32_t mr_control_deadline_remaining_ms(
    const mr_control_deadline *deadline,
    uint64_t now_ms);

/* Consumes an expired logical deadline. The caller owns synchronization and
 * supplies the clock value so wrap/saturation cases are deterministic and
 * unit-testable. */
int mr_control_deadline_take_expired(
    mr_control_deadline *deadline,
    uint64_t now_ms,
    uint8_t *out_stage);

#endif
