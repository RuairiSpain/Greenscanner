#!/usr/bin/env python3
"""Offline accuracy report for an exported GreenSight green (.greensight.json).

Use it on a scan of a surface with a known grade (a level floor, or a board set to a measured grade):

    python3 Scripts/analyze_green.py scan.greensight.json --expected-grade 0

Compare reports from scans made with different depth sources, speeds or devices.
"""
from __future__ import annotations
import argparse, json, math, statistics, sys


def solve3(a, b):
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for c in range(3):
        p = max(range(c, 3), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        if abs(m[c][c]) < 1e-12:
            raise ValueError("degenerate fit")
        for r in range(c + 1, 3):
            f = m[r][c] / m[c][c]
            for k in range(c, 4):
                m[r][k] -= f * m[c][k]
    x = [0.0] * 3
    for r in (2, 1, 0):
        x[r] = (m[r][3] - sum(m[r][k] * x[k] for k in range(r + 1, 3))) / m[r][r]
    return x


def analyse(record, expected=None):
    size = record["cellSize"]
    cells = record["cells"]  # each: [ix, iz, height, observations, bestRange, (noise)]
    if len(cells) < 30:
        raise SystemExit("too few cells")
    xs = [(c[0] + 0.5) * size for c in cells]
    zs = [(c[1] + 0.5) * size for c in cells]
    hs = [c[2] for c in cells]
    ws = [min(max(c[3], 1), 20) for c in cells]
    mx, mz = sum(xs) / len(xs), sum(zs) / len(zs)
    robust = [1.0] * len(cells)
    sol = [0.0, 0.0, 0.0]
    for _ in range(4):
        a = [[0.0] * 3 for _ in range(3)]
        b = [0.0] * 3
        for i in range(len(cells)):
            w = ws[i] * robust[i]
            v = (1.0, xs[i] - mx, zs[i] - mz)
            for p in range(3):
                b[p] += v[p] * hs[i] * w
                for q in range(3):
                    a[p][q] += v[p] * v[q] * w
        sol = solve3(a, b)
        res = [hs[i] - (sol[0] + sol[1] * (xs[i] - mx) + sol[2] * (zs[i] - mz)) for i in range(len(cells))]
        sigma = max(sorted(abs(r) for r in res)[len(res) // 2] / 0.6745, 0.0005)
        robust = [(1 - (r / (4.685 * sigma)) ** 2) ** 2 if abs(r) < 4.685 * sigma else 0.0 for r in res]
    res = [hs[i] - (sol[0] + sol[1] * (xs[i] - mx) + sol[2] * (zs[i] - mz)) for i in range(len(cells))]
    grade = math.hypot(sol[1], sol[2]) * 100
    out = {
        "cells": len(cells),
        "plane_grade_percent": grade,
        "plane_direction_degrees": math.degrees(math.atan2(sol[2], sol[1])),
        "rms_residual_mm": math.sqrt(sum(r * r for r in res) / len(res)) * 1000,
        "robust_sigma_mm": sorted(abs(r) for r in res)[len(res) // 2] / 0.6745 * 1000,
        "depth_source": record.get("depthSource"),
        "device": record.get("deviceModel"),
    }
    if expected is not None:
        out["grade_error_percent"] = grade - expected

    # Local grade deviation from the plane over a 0.4 m baseline.
    lookup = {(c[0], c[1]): c[2] for c in cells}

    def axis(c, dx, dz):
        for r in (2, 1):
            p = lookup.get((c[0] + r * dx, c[1] + r * dz))
            q = lookup.get((c[0] - r * dx, c[1] - r * dz))
            if p is not None and q is not None:
                return (p - q) / (2 * r * size)
        return None

    devs = []
    for c in cells:
        gx, gz = axis(c, 1, 0), axis(c, 0, 1)
        if gx is None and gz is None:
            continue
        devs.append(math.hypot((gx or 0) - sol[1], (gz or 0) - sol[2]) * 100)
    if devs:
        devs.sort()
        out["local_grade_error_median_percent"] = devs[len(devs) // 2]
        out["local_grade_error_p95_percent"] = devs[min(len(devs) - 1, int(0.95 * len(devs)))]

    edges = [1.5, 2.5, 3.5]
    labels = ["<1.5 m", "1.5-2.5 m", "2.5-3.5 m", ">3.5 m"]
    buckets = []
    for k, label in enumerate(labels):
        lo = -math.inf if k == 0 else edges[k - 1]
        hi = math.inf if k == len(edges) else edges[k]
        idx = [i for i, c in enumerate(cells) if lo <= c[4] < hi]
        if idx:
            buckets.append({"range": label, "cells": len(idx),
                            "rms_mm": math.sqrt(sum(res[i] ** 2 for i in idx) / len(idx)) * 1000})
    out["by_range"] = buckets
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--expected-grade", type=float, default=None, help="known grade in percent")
    args = parser.parse_args()
    with open(args.file) as handle:
        record = json.load(handle)
    print(json.dumps(analyse(record, args.expected_grade), indent=2))


if __name__ == "__main__":
    sys.exit(main())
