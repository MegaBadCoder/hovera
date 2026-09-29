"""Замыкания петель по сырому полю: пары моментов покоя, когда голова стояла в той же ориентации.

Запуск: python3 loops.py <папка с *.trace> [--fit]

Для каждой секунды покоя берётся средняя гравитация и среднее сырое поле в осях очков. Пара
«та же ориентация»: гравитация совпадает в пределах MAX_TILT, а разница поля почти целиком —
поворот вокруг вертикали (остаток ≤ MAX_RESIDUAL). Остаточный поворот δ считается из разницы поля.
Калибровка компаса не нужна (центр железа входит только в малую поправку). Слабое место — помеха,
поворачивающая горизонталь поля без изменения силы и наклона (голова сдвинулась к металлу):
такие пары неотличимы от поворота, поэтому пары берутся с |δ| ≤ MAX_DELTA.

Ошибка варианта на паре = Δ(курс без сбросов ⌃R) − δ. Печатает RMS/медиану/p90 по парам,
разбитым по интервалу между моментами.
"""
import sys
from pathlib import Path

import warnings

import numpy as np

warnings.filterwarnings("ignore")

DATA = Path("/Users/v/projects/hovera-research")
CENTER = np.array([22.98, 82.39, -27.55])
SEED = np.degrees([-0.0006469, -0.0010660, -0.0019105])
MAX_TILT = np.radians(0.4)
MAX_RESIDUAL = 0.3
MAX_DELTA = 2.0
FILES = ["full1", "full2", "exp", "w"]


def still_windows(raw):
    t = raw[:, 0]
    n = 250
    step = 125
    rows = []
    for s in range(0, len(raw) - n, step):
        w = raw[s:s + n]
        g = (w[:, 5:8] - SEED).reshape(10, 25, 3).mean(1)
        if np.linalg.norm(g, axis=1).max() > 3.0:
            continue
        a = w[:, 2:5].mean(0)
        rows.append((t[s + n // 2], *(a / np.linalg.norm(a)), *w[:, 9:12].mean(0)))
    return np.array(rows)


def pairs(win):
    t, u, m = win[:, 0], win[:, 1:4], win[:, 4:7]
    out = []
    for i in range(len(win)):
        j = np.arange(i + 1, len(win))
        j = j[t[j] - t[i] >= 5]
        if len(j) == 0:
            continue
        cos = np.clip(u[j] @ u[i], -1, 1)
        j = j[np.arccos(cos) < MAX_TILT]
        if len(j) == 0:
            continue
        up = (u[i] + u[j]) / 2
        field = (m[i] + m[j]) / 2 - CENTER
        axis = np.cross(up, field)
        norm = np.linalg.norm(axis, axis=1, keepdims=True)
        e = axis / norm
        dm = m[j] - m[i]
        along = (dm * e).sum(1)
        residual = np.linalg.norm(dm - along[:, None] * e, axis=1)
        delta = -np.degrees(along / norm[:, 0])
        ok = (residual < MAX_RESIDUAL) & (np.abs(delta) < MAX_DELTA)
        for k in np.nonzero(ok)[0]:
            out.append((t[i], t[j[k]], delta[k], residual[k]))
    return np.array(out)


def raw_cache(name):
    """Кэш по записи: пары петель и курс головы по сырому полю с поправкой на наклон, 100 Гц."""
    cache = Path(__file__).parent / "loops-cache"
    cache.mkdir(exist_ok=True)
    pairs_path, head_path = cache / f"{name}.pairs.npy", cache / f"{name}.maghead.npy"
    if not (pairs_path.exists() and head_path.exists()):
        raw = np.genfromtxt(DATA / f"{name}.csv", delimiter=",", skip_header=1)
        np.save(pairs_path, pairs(still_windows(raw)))
        n = len(raw) // 5 * 5
        blocks = raw[:n].reshape(-1, 5, raw.shape[1]).mean(1)
        up = blocks[:, 2:5] / np.linalg.norm(blocks[:, 2:5], axis=1, keepdims=True)
        m = blocks[:, 9:12] - CENTER
        mh = m - (m * up).sum(1, keepdims=True) * up
        f = np.array([0.0, 0.0, -1.0])
        fh = f - up[:, 2:3] * -1 * up
        head = np.degrees(np.unwrap(np.arctan2((np.cross(mh, fh) * up).sum(1), (mh * fh).sum(1))))
        np.save(head_path, np.column_stack([blocks[:, 0], head, np.linalg.norm(mh, axis=1), up]))
    return np.load(pairs_path), np.load(head_path)


def main():
    folder = Path(sys.argv[1])
    report = {}
    all_rows = []
    for name in FILES:
        trace_path = folder / f"{name}.trace"
        if not trace_path.exists():
            continue
        p, _ = raw_cache(name)
        d = np.genfromtxt(trace_path, delimiter=",", names=True)
        def at(time):
            return np.clip(np.searchsorted(d["t"], time), 0, len(d) - 1)
        def mean_yaw(col, times):
            k = np.arange(-25, 25)
            return d[col][np.clip(at(times)[:, None] + k, 0, len(d) - 1)].mean(1)
        def err(col):
            return mean_yaw(col, p[:, 1]) - mean_yaw(col, p[:, 0]) - p[:, 2]
        all_rows.append(np.column_stack([p[:, 1] - p[:, 0], err("uyaw"), err("ufyaw"), err("ugyaw"),
                                         np.full(len(p), FILES.index(name)), p[:, 0], p[:, 1], p[:, 2]]))
    rows = np.concatenate(all_rows)
    np.save(folder / "loops.npy", rows)
    gap = rows[:, 0]
    print(f"loops (same orientation by raw field+gravity, error of Δyaw), pairs: {len(rows)}")
    for label, lo, hi in (("5-30 s", 5, 30), ("30-120 s", 30, 120), ("2-5 min", 120, 300), ("5+ min", 300, 1e9)):
        sel = (gap >= lo) & (gap < hi)
        if sel.sum() == 0:
            continue
        f, z, g = np.abs(rows[sel, 1]), np.abs(rows[sel, 2]), np.abs(rows[sel, 3])
        print(f"  {label:9} n={sel.sum():5d} | fused rms {np.sqrt((f**2).mean()):5.1f} p90 {np.percentile(f, 90):5.1f}"
              f" | gyro learner rms {np.sqrt((g**2).mean()):5.1f} p90 {np.percentile(g, 90):5.1f}"
              f" | gyro frozen rms {np.sqrt((z**2).mean()):5.1f} p90 {np.percentile(z, 90):5.1f}")


if __name__ == "__main__":
    main()
