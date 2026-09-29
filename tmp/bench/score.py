"""Оценка варианта фильтра курса по трассам zzBenchReplay.

Запуск: python3 score.py <папка с *.trace и *.resets> <events.log> [--points]

Истина — нажатия ⌃R (CORRECTION recenter) и ⌃⌥M (MARK): пользователь смотрит в опорное
направление, значит отрисованный курс в этот момент и есть ошибка мира. Нажатие чистое, если
голова стоит (скорость ≤ CLEAN_SPEED в последние 0,25 с и курс по гироскопу сдвинулся ≤ CLEAN_MOVE
за 0,3 с). Точка истины — чистое нажатие, у которого и опорный ⌃R (последний перед ним) чистый.

Метрики (все углы в градусах):
- truth: RMS / медиана |ошибки| / максимум по точкам истины, отдельно длинные (≥ 60 с от опоры);
- gyro: то же для фильтра без компаса (ноль гироскопа учится в покое, старт с сохранённого);
- swing10: насколько компас поворачивает мир относительно гироскопа за 10 с —
  max и перцентили |Δ(курс − курс по гироскопу с сохранённым нулём)| на окнах 10 с;
- creep: голова стоит по сырому полю (курс поля за 2 с сдвинулся < 0,4°), а отрисованный мир
  за те же 2 с сдвинулся быстрее 0,3°/с — доля таких окон; это видимое «уплывание» экранов.
"""
import re
import sys
from pathlib import Path

import numpy as np

import loops

CREEP_SPAN = 2.0
CREEP_TRUE_STILL = 0.4
CREEP_RATE = 0.3
CREEP_MAX_TILT = 0.25
QUIET_SPEED = 8.0

TIERS = {"A": (12.0, 1.5), "B": (30.0, 4.0)}
FILES = ["full0", "full1", "full2", "exp", "w"]


def wrap(a):
    return (np.asarray(a) + 180.0) % 360.0 - 180.0


def load_events(path):
    events = []
    for line in open(path):
        m = re.search(r"(CORRECTION recenter|MARK) yaw (-?[\d.]+).*since (\d+) s.* at ([\d.]+)", line)
        if m:
            events.append(dict(t=float(m.group(4)), kind="R" if m.group(1).startswith("C") else "M",
                               app=float(m.group(2)), since=int(m.group(3))))
    return sorted(events, key=lambda e: e["t"])


def main():
    folder = Path(sys.argv[1])
    events = load_events(sys.argv[2])
    show_points = "--points" in sys.argv
    points, swings, creep, quiet_swings = [], [], {}, []
    per_file = []
    for name in FILES:
        trace_path = folder / f"{name}.trace"
        if not trace_path.exists():
            continue
        d = np.genfromtxt(trace_path, delimiter=",", names=True)
        t = d["t"]
        resets = {}
        for line in open(folder / f"{name}.resets"):
            m = re.search(r"at ([\d.]+) fused (-?[\d.]+) gyro (-?[\d.]+) frozen (-?[\d.]+)", line)
            resets[round(float(m.group(1)), 3)] = (float(m.group(2)), float(m.group(3)), float(m.group(4)))
        inside = [e for e in events if t[0] + 5 < e["t"] < t[-1]]

        def at(time):
            return max(0, min(np.searchsorted(t, time) - 1, len(t) - 1))

        def clean(time):
            w = (t > time - 0.25) & (t <= time + 0.02)
            move = abs(wrap(d["gyaw"][at(time)] - d["gyaw"][at(time - 0.3)]))
            speed = d["speed"][w].max()
            for tier, (max_speed, max_move) in TIERS.items():
                if speed <= max_speed and move <= max_move:
                    return tier
            return "C"

        reference = None
        for e in inside:
            e_clean = clean(e["t"])
            if e["kind"] == "R":
                fused, gyro, frozen = resets[round(e["t"], 3)]
            else:
                i = at(e["t"])
                fused, gyro, frozen = -d["yaw"][i], -d["gyaw"][i], -d["fyaw"][i]
            if reference is not None:
                since = e["t"] - reference["t"]
                usable = max(e_clean, reference["clean"]) if since >= 20 else "C"
                points.append(dict(file=name, t=e["t"], kind=e["kind"], since=since, fused=fused, gyro=gyro, frozen=frozen,
                                   app=e["app"], clean=e_clean, ref_clean=reference["clean"], usable=usable,
                                   speed=d["speed"][(t > e["t"] - 0.25) & (t <= e["t"] + 0.02)].max(),
                                   pitch=d["pitch"][at(e["t"])]))
            if e["kind"] == "R":
                reference = dict(t=e["t"], clean=e_clean)

        reset_times = np.array(sorted(resets))
        segment = np.searchsorted(reset_times, t)
        step = np.median(np.diff(t))
        lag10 = int(round(10 / step))
        same10 = segment[lag10:] == segment[:-lag10]
        rel = np.degrees(np.unwrap(np.radians(wrap(d["uyaw"] - d["ufyaw"]))))
        d10 = np.abs(rel[lag10:] - rel[:-lag10])[same10]
        swings.append(d10)
        quiet_step = np.diff(rel, prepend=rel[0]) * (d["speed"] < QUIET_SPEED) * (np.diff(segment, prepend=segment[0]) == 0)
        quiet10 = np.convolve(quiet_step, np.ones(lag10), mode="valid")
        quiet_swings.append(np.abs(quiet10))

        _, head = loops.raw_cache(name)
        mag = np.interp(t, head[:, 0], head[:, 1])
        span, half = int(round(CREEP_SPAN / step)), int(round(0.25 / step))
        kernel = np.ones(2 * half + 1) / (2 * half + 1)
        smooth = lambda x: np.convolve(x, kernel, mode="same")
        unwrapped = lambda x: np.degrees(np.unwrap(np.radians(x)))
        mag_s = smooth(mag)
        yaw_s, gyro_s, frozen_s = (smooth(unwrapped(d[c])) for c in ("uyaw", "ugyaw", "ufyaw"))
        fast = np.lib.stride_tricks.sliding_window_view(d["speed"], span + 1).max(axis=1)
        idx = np.arange(half, len(t) - span - half, int(round(0.25 / step)))
        ups = np.column_stack([smooth(np.interp(t, head[:, 0], head[:, k])) for k in (3, 4, 5)])
        ups /= np.linalg.norm(ups, axis=1, keepdims=True)
        tilt = np.degrees(np.arccos(np.clip((ups[idx + span] * ups[idx]).sum(1), -1, 1)))
        still = (np.abs(mag_s[idx + span] - mag_s[idx]) < CREEP_TRUE_STILL) & (fast[idx] < 15) & (tilt < CREEP_MAX_TILT)
        idx = idx[still]
        true_move = mag_s[idx + span] - mag_s[idx]
        for key, series in (("fused", yaw_s), ("gyro", gyro_s), ("frozen", frozen_s)):
            rate = np.abs(series[idx + span] - series[idx] - true_move) / CREEP_SPAN
            creep.setdefault(key, []).append(rate)
        per_file.append((name, d10.max() if len(d10) else 0, np.percentile(d10, 95) if len(d10) else 0,
                         np.mean(creep["fused"][-1] > CREEP_RATE), len(idx) * 0.25))

    usable = [p for p in points if p["usable"] <= "B"]
    strict = [p for p in points if p["usable"] == "A"]
    def stats(values):
        v = np.abs(np.array(values))
        if len(v) == 0:
            return "n=0"
        return f"n={len(v):2d} rms {np.sqrt((v ** 2).mean()):5.1f} med {np.median(v):5.1f} max {v.max():5.1f}"
    long_pts = [p for p in usable if p["since"] >= 60]
    print(f"truth tier A  fused {stats([p['fused'] for p in strict])} | gyro {stats([p['gyro'] for p in strict])} | frozen {stats([p['frozen'] for p in strict])}")
    print(f"truth A+B     fused {stats([p['fused'] for p in usable])} | gyro {stats([p['gyro'] for p in usable])} | frozen {stats([p['frozen'] for p in usable])}")
    print(f"truth ≥60 s   fused {stats([p['fused'] for p in long_pts])} | gyro {stats([p['gyro'] for p in long_pts])} | frozen {stats([p['frozen'] for p in long_pts])}")
    all10 = np.concatenate(swings)
    print(f"swing10 (fused − frozen gyro) max {all10.max():5.1f}  p95 {np.percentile(all10, 95):4.1f}  p99 {np.percentile(all10, 99):4.1f}")
    q10 = np.concatenate(quiet_swings)
    print(f"quiet swing10 (compass turn of the world while head < {QUIET_SPEED:.0f}°/s, per 10 s) max {q10.max():4.1f}  p95 {np.percentile(q10, 95):4.1f}  p99 {np.percentile(q10, 99):4.1f}")
    rates = {k: np.concatenate(v) for k, v in creep.items()}
    print(f"creep (world glides > {CREEP_RATE}°/s while field says head still, {len(rates['fused']) * 0.25 / 60:.0f} min): "
          + " | ".join(f"{k} {100 * np.mean(v > CREEP_RATE):4.1f}% med {np.median(v):.2f} p95 {np.percentile(v, 95):.2f}°/s" for k, v in rates.items()))
    for name, mx, p95, cr, st in per_file:
        print(f"  {name:5} swing10 max {mx:5.1f} p95 {p95:4.1f}  creep {100 * cr:4.1f}% of {st:4.0f} s")
    if show_points:
        print("points (file time kind since | fused gyro frozen app | clean refclean speed pitch):")
        for p in points:
            flag = p["usable"] if p["usable"] != "C" else " "
            print(f" {flag} {p['file']:5} {p['t']:.2f} {p['kind']} {p['since']:6.0f}s | {p['fused']:6.1f} {p['gyro']:6.1f} {p['frozen']:6.1f} "
                  f"{p['app']:6.1f} | {p['clean']} {p['ref_clean']} {p['speed']:5.1f} {p['pitch']:5.1f}")


if __name__ == "__main__":
    main()
