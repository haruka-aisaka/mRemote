#include "control_deadline.h"

#include <stdint.h>
#include <stdio.h>

#define REQUIRE(condition)                                                     \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "requirement failed at %s:%d: %s\n",            \
                    __FILE__, __LINE__, #condition);                           \
            return 1;                                                          \
        }                                                                      \
    } while (0)

int main(void)
{
    mr_control_deadline deadline = {0};
    uint8_t stage = 0u;

    REQUIRE(mr_control_deadline_remaining_ms(&deadline, 100u) == UINT32_MAX);
    REQUIRE(!mr_control_deadline_take_expired(&deadline, 100u, &stage));

    mr_control_deadline_arm(&deadline, 100u, 25u, 2u);
    REQUIRE(mr_control_deadline_is_armed_for(&deadline, 2u));
    REQUIRE(!mr_control_deadline_is_armed_for(&deadline, 3u));
    REQUIRE(mr_control_deadline_remaining_ms(&deadline, 100u) == 25u);
    REQUIRE(mr_control_deadline_remaining_ms(&deadline, 124u) == 1u);
    REQUIRE(!mr_control_deadline_take_expired(&deadline, 124u, &stage));
    REQUIRE(mr_control_deadline_take_expired(&deadline, 125u, &stage));
    REQUIRE(stage == 2u);
    REQUIRE(!mr_control_deadline_is_armed_for(&deadline, 2u));
    REQUIRE(mr_control_deadline_remaining_ms(&deadline, 125u) == UINT32_MAX);
    REQUIRE(!mr_control_deadline_take_expired(&deadline, 126u, &stage));

    mr_control_deadline_arm(&deadline, 200u, 50u, 3u);
    REQUIRE(mr_control_deadline_is_armed_for(&deadline, 3u));
    mr_control_deadline_arm(&deadline, 210u, 50u, 4u);
    REQUIRE(!mr_control_deadline_is_armed_for(&deadline, 3u));
    REQUIRE(mr_control_deadline_is_armed_for(&deadline, 4u));
    REQUIRE(mr_control_deadline_remaining_ms(&deadline, 250u) == 10u);
    REQUIRE(mr_control_deadline_take_expired(&deadline, 260u, &stage));
    REQUIRE(stage == 4u);

    mr_control_deadline_arm(&deadline, 0u, UINT64_MAX, 5u);
    REQUIRE(mr_control_deadline_remaining_ms(&deadline, 0u) == UINT32_MAX - 1u);
    REQUIRE(mr_control_deadline_take_expired(&deadline, UINT64_MAX, &stage));
    REQUIRE(stage == 5u);

    mr_control_deadline_arm(&deadline, UINT64_MAX - 5u, 10u, 6u);
    REQUIRE(mr_control_deadline_remaining_ms(&deadline, UINT64_MAX - 1u) == 1u);
    REQUIRE(mr_control_deadline_take_expired(&deadline, UINT64_MAX, &stage));
    REQUIRE(stage == 6u);

    mr_control_deadline_arm(&deadline, 300u, 10u, 7u);
    mr_control_deadline_reset(&deadline);
    REQUIRE(mr_control_deadline_remaining_ms(&deadline, 400u) == UINT32_MAX);

    return 0;
}
