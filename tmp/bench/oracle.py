import sys
import warnings

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

import loops

warnings.filterwarnings("ignore")


def run(tau, still_speed=5.0, span=2.0, magthr=None, col="ufyaw", carry=True):
    allpairs = []
    for name in loops.FILES:
        d = np.genfromtxt(f"out/current/{name}.trace", delimiter=",", names=True)
        pairs, head = loops.raw_cache(name)
        t = d["t"]
        y = np.degrees(np.unwrap(np.radians(d[col])))
        mag = np.interp(t, head[:, 0], head[:, 1])
        n = len(t)
        k = int(span / 0.01)
        rm = np.concatenate([np.full(k, 99.0), sliding_window_view(d["speed"], k + 1).max(1)])[:n]
        corr = np.zeros(n)
        b = 0.0
        acc = 0.0
        for i in range(n):
            if not carry and rm[i] >= still_speed:
                b = 0.0
            if i >= k and i % 25 == 0 and rm[i] < still_speed:
                dm = mag[i] - mag[i - k]
                if magthr is None or abs(dm) < magthr:
                    rate = (y[i] - y[i - k] - dm) / span
                    b += (rate - b) * min(1, 0.25 / tau)
            acc += b * 0.01
            corr[i] = acc
        yc = y - corr
        at = lambda x: np.clip(np.searchsorted(t, x), 0, n - 1)
        e = yc[at(pairs[:, 1])] - yc[at(pairs[:, 0])] - pairs[:, 2]
        allpairs.append(np.column_stack([pairs[:, 1] - pairs[:, 0], e]))
    p = np.concatenate(allpairs)
    out = []
    for lo, hi in ((5, 30), (30, 120), (120, 300), (300, 1e9)):
        s = (p[:, 0] >= lo) & (p[:, 0] < hi)
        out.append(np.sqrt((p[s, 1] ** 2).mean()))
    return np.round(out, 1)


if __name__ == "__main__":
    for tau in (1e9, 30, 10, 5, 2):
        print("tau", tau, run(tau))
    print("still 10°/s tau 5", run(5, still_speed=10))
    for sp in (3, 5, 10):
        print("zaru only while still, speed <", sp, run(0.25, still_speed=sp, carry=False))
