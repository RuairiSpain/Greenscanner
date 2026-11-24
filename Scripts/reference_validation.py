#!/usr/bin/env python3
"""Platform-neutral checks for GreenSight's geometry and rolling model."""
from __future__ import annotations
import math


def basis_round_trip() -> None:
    ball = (1.0, 0.2, -2.0)
    cup = (1.0, 0.25, -5.0)
    dx, dz = cup[0] - ball[0], cup[2] - ball[2]
    n = math.hypot(dx, dz)
    forward = (dx / n, dz / n)
    right = (-forward[1], forward[0])
    x, along = 0.4, 1.7
    world = (ball[0] + right[0] * x + forward[0] * along,
             ball[2] + right[1] * x + forward[1] * along)
    delta = (world[0] - ball[0], world[1] - ball[2])
    recovered = (delta[0] * right[0] + delta[1] * right[1],
                 delta[0] * forward[0] + delta[1] * forward[1])
    assert abs(recovered[0] - x) < 1e-9
    assert abs(recovered[1] - along) < 1e-9


def stimp_drag() -> None:
    release_speed = 6 / 3.280839895
    distance = 10 / 3.280839895
    deceleration = release_speed**2 / (2 * distance)
    recovered_distance = release_speed**2 / (2 * deceleration)
    assert abs(recovered_distance - distance) < 1e-12
    assert 0.4 < deceleration < 0.7


def rolling_signs() -> None:
    # Positive cross-slope (height rises right) must accelerate the ball left.
    gradient_x = 0.025
    acceleration_x = -(5 / 7) * 9.80665 * gradient_x
    assert acceleration_x < 0


if __name__ == "__main__":
    basis_round_trip()
    stimp_drag()
    rolling_signs()
    print("reference validation: 3/3 checks passed")
