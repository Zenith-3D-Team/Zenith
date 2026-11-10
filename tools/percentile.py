"""The percentile the measuring tools report (moving_summary.py, perf_audit.py, belt_path_check.py,
bench/compare_builds.py): the nearest rank, the smallest value with at least p of the values at or
below it, so p99 of frame times is a frame that happened."""
import math


def pct(values, p, empty=float("nan")):
    """The p-th (0..1) percentile of values; `empty` when there are none."""
    if not values:
        return empty
    s = sorted(values)
    return s[max(0, min(len(s) - 1, math.ceil(p * len(s)) - 1))]
