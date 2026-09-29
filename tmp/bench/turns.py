"""Масштаб гироскопа по поворотам: курс по гироскопу против курса по сырому полю между двумя моментами покоя."""
import warnings

import numpy as np

import loops

warnings.filterwarnings("ignore")
OLD = np.array([24.012, 82.716, -30.646])
NEW = np.array([22.98, 82.39, -27.55])
SEED = np.degrees([-0.0006469, -0.0010660, -0.0019105])


def still_heads(raw, center):
    rows = []
    for s in range(0, len(raw) - 250, 125):
        w = raw[s:s + 250]
        g = (w[:, 5:8] - SEED).reshape(10, 25, 3).mean(1)
        if np.linalg.norm(g, axis=1).max() > 3.0:
            continue
        up = w[:, 2:5].mean(0)
        up /= np.linalg.norm(up)
        m = w[:, 9:12].mean(0) - center
        mh = m - (m @ up) * up
        f = np.array([0.0, 0.0, -1.0])
        fh = f - (f @ up) * up
        rows.append((s, np.degrees(np.arctan2(np.cross(mh, fh) @ up, mh @ fh)), np.linalg.norm(mh)))
    return rows


for name, center in (("full1", OLD), ("full2", NEW), ("exp", NEW), ("w", NEW)):
    raw = np.load(f"/private/tmp/claude-501/-Users-v-projects-hovera/b90f430e-37e0-4413-bc04-41e002b801ec/scratchpad/{name}_full.npy")
    up = raw[:, 2:5] / np.linalg.norm(raw[:, 2:5], axis=1, keepdims=True)
    for scale_y in (1.0346, 1.0):
        g = (raw[:, 5:8] - SEED) * np.array([1, scale_y, 1])
        vert = np.concatenate([[0], np.cumsum((g * up).sum(1) * raw[:, 1])])
        heads = still_heads(raw, center)
        xs, ys = [], []
        for (s0, h0, _), (s1, h1, _) in zip(heads, heads[1:]):
            dt = (s1 - s0) / 500
            if dt > 8 or s1 - s0 <= 250:
                continue
            dg = vert[s1 + 125] - vert[s0 + 125]
            dm = (h1 - h0 + 180) % 360 - 180
            if 15 < abs(dg) < 100:
                xs.append(dg)
                ys.append(dm)
        xs, ys = np.array(xs), np.array(ys)
        slope = (xs * ys).sum() / (xs * xs).sum()
        res = ys - slope * xs
        pos, neg = xs > 0, xs < 0
        sp = (xs[pos] * ys[pos]).sum() / (xs[pos] ** 2).sum()
        sn = (xs[neg] * ys[neg]).sum() / (xs[neg] ** 2).sum()
        print(f"{name:5} gyro y scale {scale_y}: turns {len(xs):3d} mag/gyro {slope:.3f} (left {sp:.3f}, right {sn:.3f}) resid {res.std():.1f}°")
