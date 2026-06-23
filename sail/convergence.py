"""Autonomous-mode convergence oracle (#77).

The deterministic loop decision the autonomous `/sail` driver (under `/surf`) consults
instead of eyeballing a "continue / abort / proceed" judgment a human used to make.

Contract: `rc` is the exit code of the gate that just ran (`sail run` / `sail review` /
`sail plan`), whose contract is `0 = green, non-zero = not green`. Any non-zero rc
(1, 127, ...) is treated uniformly as "not green". `round_num` is the 1-based count of
review rounds run so far; `max_rounds` is the genuine-non-convergence backstop (default 3).

This encodes the discipline:
  - exit 0 is the stop signal — LOW/MEDIUM findings never flip the exit code, so a green
    light stays green and the driver never spins another round to chase tidiness ("LOWs
    are non-blocking and are not chased past green").
  - while not green and under the cap, revise and re-review.
  - at the cap with the gate still red, PARK for a human rather than loop forever.
"""

from __future__ import annotations

PROCEED = "proceed"
REVISE = "revise"
PARK = "park"


def loop_decision(rc: int, round_num: int, max_rounds: int = 3) -> str:
    """Return the loop decision: 'proceed' | 'revise' | 'park'.

    rc == 0            -> 'proceed' (green; stop — do not chase non-blocking LOWs)
    rc != 0, under cap -> 'revise'
    rc != 0, at cap    -> 'park'   (genuine non-convergence backstop)
    """
    if rc == 0:
        return PROCEED
    if round_num < max_rounds:
        return REVISE
    return PARK
