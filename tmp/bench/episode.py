"""Эпизоды помехи: компоненты поля, не зависящие от курса (вертикальная и модуль горизонтальной), рядом с ошибкой компаса."""
import sys
import warnings

import numpy as np

warnings.filterwarnings("ignore")
NEW = np.array([22.98, 82.39, -27.55])
name, start, end = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
variant = sys.argv[4] if len(sys.argv) > 4 else "norate"
raw = np.load(f"/private/tmp/claude-501/-Users-v-projects-hovera/b90f430e-37e0-4413-bc04-41e002b801ec/scratchpad/{name}_full.npy")
d = np.genfromtxt(f"out/{variant}/{name}.trace", delimiter=",", names=True)
for a in np.arange(start, end, 2.0):
    s = (raw[:, 0] >= a) & (raw[:, 0] < a + 2)
    w = raw[s]
    up = w[:, 2:5].mean(0)
    up /= np.linalg.norm(up)
    m = w[:, 9:12].mean(0) - NEW
    mv = m @ up
    mh = np.linalg.norm(m - mv * up)
    k = (d["t"] >= a) & (d["t"] < a + 2)
    print(f"{a - start:5.0f}s mv {mv:6.2f} |mh| {mh:5.2f} |m| {np.linalg.norm(m):5.2f} speed {d['speed'][k].mean():5.1f} "
          f"yaw {d['yaw'][k].mean():6.1f} pitch {d['pitch'][k].mean():5.1f} cerr {d['cerr'][k].mean():5.1f} "
          f"fused-frozen {np.mean(d['uyaw'][k] - d['ufyaw'][k]):6.1f}")
