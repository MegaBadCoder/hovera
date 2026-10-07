# -*- coding: utf-8 -*-
"""Загрузка и разбор логов RayDesk для температурной характеристики датчиков.

Логи (~/Library/Logs/RayDesk-imu):
  imu-<ts>.csv     500 Гц, сырой IMU очков:
                   time,dt,ax,ay,az,gx,gy,gz,temp,mx,my,mz
                   аксель в g, гироскоп в °/с, temp — термодатчик чипа IMU (°C).
  glasses-<ts>.csv ~30 Гц, покадрово от камеры:
                   time,captured,face,x,y,z,score,turnyaw,turnpitch,source,aligned,
                   neckx,necky,neckz,verdict,speed,qw..qz,facedepth,fqw..fqz,pairs,
                   residual,cameraYawStep,faceYawScale,headingAge,headingError,
                   referenceID,cameraFOV
                   headingError — расхождение курса IMU с курсом по камере (°),
                   cameraYawStep — поворот мира за кадр (°), score — совпадение формы (%).

Время всюду Date().timeIntervalSinceReferenceDate (секунды с 2001-01-01).
"""
from __future__ import annotations

import glob
import os
from pathlib import Path

import numpy as np
import pandas as pd

IMU_COLUMNS = ["time", "dt", "ax", "ay", "az", "gx", "gy", "gz", "temp", "mx", "my", "mz"]

# Пороги неподвижности (гироскоп в °/с, аксель в g).
# Голова на теле никогда не стоит: 5-й перцентиль std гироскопа за 1.5 с ≈ 0.4 °/с,
# поэтому «неподвижность» = самые спокойные ~1–2 % времени.
STILL_GYRO_STD = 0.30      # std каждой оси гироскопа за окно
STILL_ACCEL_STD = 0.020    # std модуля акселя за окно
STILL_ACCEL_NEAR = (0.97, 1.03)
STILL_WINDOW_S = 1.0       # окно детектора
STILL_MIN_SEGMENT_S = 1.5  # минимальная длительность сегмента
STILL_BRIDGE_S = 1.0       # паузы тише этой длины склеиваются
STILL_DOWNSAMPLE = 5       # детект на 100 Гц, статистики на полных 500 Гц


def load_imu(log_dir: str | os.PathLike) -> pd.DataFrame:
    """Все imu-*.csv в один DataFrame с колонкой file (имя файла) и session (id старта)."""
    frames = []
    for path in sorted(glob.glob(os.path.join(log_dir, "imu-*.csv"))):
        try:
            df = pd.read_csv(path, names=IMU_COLUMNS, header=0,
                             dtype={c: "float64" for c in IMU_COLUMNS},
                             na_values=[""], engine="c")
        except Exception as e:  # битый/пустой файл не роняет весь анализ
            print(f"  пропуск {Path(path).name}: {e}")
            continue
        if df.empty:
            continue
        df["file"] = Path(path).stem
        df["session"] = int(Path(path).stem.split("-")[1])
        frames.append(df)
    if not frames:
        raise RuntimeError(f"нет imu-*.csv в {log_dir}")
    out = pd.concat(frames, ignore_index=True)
    out = out.sort_values("time").reset_index(drop=True)
    # разрыв времени > 1 с = новая сессия в рамках файла
    out["gap"] = out["time"].diff() > 1.0
    out["session"] = (out["session"].astype("int64") + out["gap"].cumsum()).astype("int64")
    return out


def load_glasses(log_dir: str | os.PathLike) -> pd.DataFrame:
    """Все glasses-*.csv (камера, ~30 Гц) в один DataFrame."""
    frames = []
    for path in sorted(glob.glob(os.path.join(log_dir, "glasses-*.csv"))):
        try:
            df = pd.read_csv(path, header=0, engine="c", na_values=[""])
        except Exception as e:
            print(f"  пропуск {Path(path).name}: {e}")
            continue
        if df.empty:
            continue
        df["file"] = Path(path).stem
        frames.append(df)
    if not frames:
        raise RuntimeError(f"нет glasses-*.csv в {log_dir}")
    out = pd.concat(frames, ignore_index=True)
    out = out.sort_values("time").reset_index(drop=True)
    out["gap"] = out["time"].diff() > 60.0
    out["session"] = out["gap"].cumsum().astype("int64")
    return out


def stillness_mask(imu: pd.DataFrame) -> np.ndarray:
    """Булева маска неподвижности на полных 500 Гц (детект по прореженным 100 Гц)."""
    gx, gy, gz = imu["gx"].to_numpy(), imu["gy"].to_numpy(), imu["gz"].to_numpy()
    amag = np.sqrt(imu["ax"] ** 2 + imu["ay"] ** 2 + imu["az"] ** 2).to_numpy()
    n = len(imu)
    idx = np.arange(0, n, STILL_DOWNSAMPLE)
    win = max(int(round(STILL_WINDOW_S * 100)), 5)  # окно на 100 Гц

    def roll_std(x: np.ndarray) -> np.ndarray:
        s = pd.Series(x).rolling(win, center=True, min_periods=win // 2).std().to_numpy()
        return s

    calm = (
        (roll_std(gx[idx]) < STILL_GYRO_STD)
        & (roll_std(gy[idx]) < STILL_GYRO_STD)
        & (roll_std(gz[idx]) < STILL_GYRO_STD)
        & (roll_std(amag[idx]) < STILL_ACCEL_STD)
        & (amag[idx] > STILL_ACCEL_NEAR[0])
        & (amag[idx] < STILL_ACCEL_NEAR[1])
    )
    mask = np.repeat(calm, STILL_DOWNSAMPLE)[:n]
    if len(mask) < n:  # на случай короткого файла
        mask = np.concatenate([mask, np.zeros(n - len(mask), bool)])
    return mask


def stillness_segments(imu: pd.DataFrame, temp_col: str = "temp") -> pd.DataFrame:
    """Сегменты неподвижности ≥ STILL_MIN_SEGMENT_S со средними по каждому датчику.

    Возвращает DataFrame: t0,t1,dur,temp,gx,gy,gz (°/с = гиро-биас в покое),
    accel модуль, roll/pitch из гравитации (°), магнитный модуль и курс (°).
    """
    mask = stillness_mask(imu)
    # склейка коротких пауз: микротремор головы нулевой по среднему
    rate = 1.0 / imu["dt"].replace(0, np.nan).median()
    gap = int(STILL_BRIDGE_S * rate)
    z = np.flatnonzero(np.diff(np.concatenate([[0], (~mask).view(np.int8), [0]])))
    for k in range(0, len(z), 2):
        if z[k + 1] - z[k] <= gap:
            mask[z[k]:z[k + 1]] = True
    d = mask.astype("int8")
    edges = np.flatnonzero(np.diff(np.concatenate([[0], d, [0]])))
    rows = []
    t = imu["time"].to_numpy()
    for k in range(0, len(edges), 2):
        i0, i1 = edges[k], edges[k + 1]  # [i0, i1)
        dur = (t[i1 - 1] - t[i0]) if i1 > i0 + 1 else 0
        if dur < STILL_MIN_SEGMENT_S:
            continue
        sl = slice(i0, i1)
        seg = imu.iloc[sl]
        ax, ay, az = seg["ax"].mean(), seg["ay"].mean(), seg["az"].mean()
        amag = float(np.sqrt(ax * ax + ay * ay + az * az))
        roll = float(np.degrees(np.arctan2(ay, az)))
        pitch = float(np.degrees(np.arctan2(-ax, np.hypot(ay, az))))
        mx, my, mz = seg["mx"], seg["my"], seg["mz"]
        mmag = float(np.sqrt(mx**2 + my**2 + mz**2).mean())
        m_yaw = float(np.degrees(np.arctan2(-my, mx)).mean()) if seg["mx"].notna().all() else np.nan
        rows.append({
            "session": int(seg["session"].iloc[0]),
            "t0": t[i0], "t1": t[i1 - 1], "dur": dur,
            "temp": float(seg[temp_col].mean()),
            "gx": float(seg["gx"].mean()), "gy": float(seg["gy"].mean()), "gz": float(seg["gz"].mean()),
            "g_std": float(np.sqrt(seg["gx"].var() + seg["gy"].var() + seg["gz"].var())),
            "amag": amag, "roll": roll, "pitch": pitch,
            "mmag": mmag, "m_yaw": m_yaw,
        })
    return pd.DataFrame(rows)


def temp_curve(imu: pd.DataFrame, step_s: float = 30.0) -> pd.DataFrame:
    """Температура по времени с шагом step_s — кривые прогрева по сессиям."""
    rows = []
    for sess, g in imu.groupby("session"):
        t0 = g["time"].iloc[0]
        grid = np.arange(g["time"].iloc[0], g["time"].iloc[-1], step_s)
        binned = g.assign(bin=((g["time"] - t0) // step_s).astype(int))
        means = binned.groupby("bin")[["temp", "gx", "gy", "gz"]].mean()
        for b, row in means.iterrows():
            rows.append({"session": sess, "t": t0 + b * step_s, "rel": b * step_s, **row.to_dict()})
    return pd.DataFrame(rows)


def merge_temp(glasses: pd.DataFrame, imu: pd.DataFrame) -> pd.DataFrame:
    """Присоединяет температуру IMU к кадрам камеры (asof-слияние по time)."""
    t = imu[["time", "temp"]].sort_values("time")
    g = glasses.sort_values("time")
    return pd.merge_asof(g, t, on="time", direction="nearest", tolerance=0.5)


def linfit(x, y, w=None):
    """Взвешенный линейный фит y = a + b·x. Возвращает (a, b, r2, b_stderr)."""
    x = np.asarray(x, float)
    y = np.asarray(y, float)
    ok = np.isfinite(x) & np.isfinite(y)
    if w is not None:
        w = np.asarray(w, float)
        ok &= np.isfinite(w) & (w > 0)
    x, y = x[ok], y[ok]
    w = (np.asarray(w, float)[ok] if w is not None else np.ones_like(x))
    if len(x) < 3 or np.ptp(x) == 0:
        return np.nan, np.nan, np.nan, np.nan
    W = w / w.sum()
    mx, my = np.sum(W * x), np.sum(W * y)
    vx = np.sum(W * (x - mx) ** 2)
    b = np.sum(W * (x - mx) * (y - my)) / vx
    a = my - b * mx
    resid = y - (a + b * x)
    ss_res = np.sum(W * resid**2)
    ss_tot = np.sum(W * (y - my) ** 2)
    r2 = 1 - ss_res / ss_tot if ss_tot > 0 else np.nan
    n_eff = max(len(x), 2)
    b_err = np.sqrt(ss_res / (n_eff - 2) / vx) if n_eff > 2 else np.nan
    return a, b, r2, b_err


def per_hour(deg_per_s: float) -> float:
    """°/с → °/ч."""
    return deg_per_s * 3600.0


def camera_drift_rate(cam: pd.DataFrame, window_s: float = 10.0) -> pd.DataFrame:
    """Оценка скорости ухода курса IMU относительно камеры по окнам window_s.

    Берёт кадры с надёжным лицом, в каждом окне — медианная производная headingError
    и средние temp, speed. Наклон headingError: мир камерой доворачивается, поэтому
    сырая производная = уплывание гироскопа минус уже применённые коррекции; для
    полной картины рядом считается накопленная сумма cameraYawStep.
    """
    g = cam[cam["face"] == 1].copy()
    g = g[g["score"] >= 0.75]  # score — доля 0..1 (в логе его показывают как проценты)
    g = g[g["headingAge"] < 0.3]
    g = g[np.isfinite(g["headingError"])]
    rows = []
    for sess, s in g.groupby("session"):
        s = s.sort_values("time")
        t = s["time"].to_numpy()
        if len(t) < 30:
            continue
        step = max(int(window_s * 30), 30)
        for i in range(0, len(s) - step, step // 2):
            w = s.iloc[i:i + step]
            dt = w["time"].iloc[-1] - w["time"].iloc[0]
            if dt < window_s * 0.8:
                continue
            err = w["headingError"].to_numpy()
            de = np.median(np.diff(err)) / np.median(np.diff(w["time"].to_numpy()))
            rows.append({
                "session": sess,
                "t": w["time"].iloc[len(w) // 2],
                "derr": de,                      # °/с, скорость расхождения IMU-камера
                "step_sum": w["cameraYawStep"].clip(-5, 5).sum() / dt,  # °/с коррекций
                "speed": w["speed"].median(),    # °/с
                "temp": w["temp"].median(),
                "score": w["score"].median(),
            })
    return pd.DataFrame(rows)


# Полка — окно, где камера видит неподвижную голову: курс по лицу не гуляет.
PLATEAU_FLAT_DEG = 1.5
PLATEAU_MIN_S = 2.5
PLATEAU_SPEED_MAX = 8.0     # °/с, отсечка кадров с движением головы
PLATEAU_X_MM = 10.0         # мм, размах положения очков: голова не только стоит, но и не едет
FACE_SCORE_MIN = 0.60


def camera_yaw(cam: pd.DataFrame) -> np.ndarray:
    """Курс головы по камере (°, плюс — влево) с поправкой `faceYawScale`, NaN без лица."""
    scale = cam["faceYawScale"].to_numpy() if "faceYawScale" in cam else np.ones(len(cam))
    scale = np.where(np.isfinite(scale) & (scale > 0), scale, 1.0)
    yaw = cam["turnyaw"].to_numpy() / scale
    ok = (cam["face"].to_numpy() == 1) & (cam["score"].to_numpy() >= FACE_SCORE_MIN)
    return np.where(ok, yaw, np.nan)


def imu_runs(imu: pd.DataFrame) -> list[tuple[int, int]]:
    """Непрерывные куски времени в IMU: разрыв > 1 с — стык файлов или переподключение."""
    t = imu["time"].to_numpy()
    edges = np.flatnonzero(np.concatenate([[True], np.diff(t) > 1.0]))
    return list(zip(edges, list(edges[1:]) + [len(t)]))


def head_plateaus(cam: pd.DataFrame, imu: pd.DataFrame) -> pd.DataFrame:
    """Окна, где голова стоит, и что в них показывают гироскоп и камера.

    Полка — окно ≥ `PLATEAU_MIN_S`, в котором курс по камере укладывается в
    `PLATEAU_FLAT_DEG` и логовая скорость головы не превышает `PLATEAU_SPEED_MAX`.
    Вертикальная скорость гироскопа считается по локальной гравитации (среднее
    ускорение окна), поэтому наклон головы не подмешивает горизонтальные оси.

    - Returns: DataFrame с t0, dur, yaw (курс по камере), gyro_rate и cam_rate (°/с),
      их разницей rel_rate, temp и score.
    """
    yaw_cam = camera_yaw(cam)
    t_cam = cam["time"].to_numpy()
    speed = cam["speed"].to_numpy()
    score = cam["score"].to_numpy()
    glasses_x = cam["x"].to_numpy() if "x" in cam else None
    acc = imu[["ax", "ay", "az"]].to_numpy()
    gyr = imu[["gx", "gy", "gz"]].to_numpy()
    temp = imu["temp"].to_numpy()
    t_imu = imu["time"].to_numpy()
    win = int(round(PLATEAU_MIN_S * 500))
    step = max(win // 5, 1)
    rows = []
    for a, b in imu_runs(imu):
        t = t_imu[a:b]
        if len(t) < win * 2:
            continue
        inside = (t_cam >= t[0] - 1) & (t_cam <= t[-1] + 1)
        if inside.sum() < 10:
            continue
        valid = inside & np.isfinite(yaw_cam)
        if valid.sum() < 10:
            continue
        tc, yc = t_cam[valid], yaw_cam[valid]
        yi = np.interp(t, tc, yc)
        sp = np.interp(t, tc, speed[valid])
        sc = np.interp(t, tc, score[valid])
        x_valid = valid & np.isfinite(glasses_x) if glasses_x is not None else None
        gx = np.interp(t, t_cam[x_valid], glasses_x[x_valid]) if x_valid is not None and x_valid.sum() > 10 else None
        for i in range(0, len(t) - win, step):
            w = slice(i, i + win)
            if not np.isfinite(yi[w]).all() or np.ptp(yi[w]) > PLATEAU_FLAT_DEG:
                continue
            if np.percentile(sp[w], 90) > PLATEAU_SPEED_MAX:
                continue
            if gx is not None and np.ptp(gx[w]) * 1000 > PLATEAU_X_MM:
                continue
            up = acc[a + i:a + i + win].mean(0)
            up = up / np.linalg.norm(up)
            rate = float(np.median(gyr[a + i:a + i + win] @ up))
            dur = t[i + win - 1] - t[i]
            rows.append({"t0": t[i], "dur": dur, "yaw": float(np.median(yi[w])),
                         "gyro_rate": rate,
                         "cam_rate": float((yi[i + win - 1] - yi[i]) / dur),
                         "rel_rate": rate - float((yi[i + win - 1] - yi[i]) / dur),
                         "temp": float(np.median(temp[a + i:a + i + win])),
                         "score": float(np.median(sc[w]))})
    out = pd.DataFrame(rows)
    if out.empty:
        return out
    out["band"] = pd.cut(out["yaw"], [-90, -30, -15, -6, 6, 15, 30, 90])
    return out


def world_drift(cam: pd.DataFrame) -> pd.DataFrame:
    """Уход мира относительно комнаты: курс из кватерниона головы минус курс по камере.

    Кватернион головы записан в мире, который приложение доворачивает коррекциями,
    поэтому разница — это то, насколько картинка разошлась с комнатой. Считается
    только по кадрам с надёжным лицом; ряд развёрнут (без переходов через ±180°).
    """
    q = cam[["qw", "qx", "qy", "qz"]].to_numpy()
    yaw_cam = camera_yaw(cam)
    ok = np.isfinite(q).all(1) & np.isfinite(yaw_cam)
    w, x, y, z = q[ok, 0], q[ok, 1], q[ok, 2], q[ok, 3]
    fwd_x = -2 * (x * z + w * y)
    fwd_z = -(1 - 2 * (x * x + y * y))
    yaw_q = np.degrees(np.arctan2(-fwd_x, -fwd_z))
    out = pd.DataFrame({"session": cam["session"].to_numpy()[ok],
                        "time": cam["time"].to_numpy()[ok],
                        "yaw_world": yaw_q, "yaw_cam": yaw_cam[ok]})
    out["drift"] = np.nan
    for _, g in out.groupby("session"):
        out.loc[g.index, "drift"] = np.degrees(np.unwrap(np.radians(g["yaw_world"] - g["yaw_cam"])))
    return out


# Пересчёт нуля гироскопа прошивкой очков: показания квантованы шагом 0,035 °/с,
# а своё смещение прошивка сдвигает на среднее последних 2 с — в том числе на
# медленном повороте. Порт `FirmwareZeroRestorer` из RayDeskCore.
FIRMWARE_STEP = 0.035
FIRMWARE_WINDOW = 1000
FIRMWARE_LOCK = 20
FIRMWARE_PHASE_TOL = 0.02
FIRMWARE_MIN_AXES = 2
FIRMWARE_MATCH_TOL = 0.1


def _wrapped(x):
    return x - np.rint(x)


def firmware_zero_restore(gyro: np.ndarray) -> tuple[np.ndarray, pd.DataFrame]:
    """Отменяет пересчёты нуля прошивки в сыром логе гироскопа.

    - Parameter gyro: (N, 3) °/с, как их пишет `imu-*.csv` (сырые показания прошивки).
    - Returns: (восстановленный сигнал с постоянным нулём, события пересчёта:
      индекс, сдвиг нуля °/с, накопленный сдвиг).
    """
    n = len(gyro)
    out = np.empty_like(gyro)
    phase = _wrapped(gyro / FIRMWARE_STEP)
    ring = np.zeros((FIRMWARE_WINDOW, 3))
    ring_next = ring_count = 0
    ring_sum = np.zeros(3)
    shift = np.zeros(3)
    last_phase = None
    steady = 0
    events = []
    for i in range(n):
        output = gyro[i] - shift
        if ring_count == FIRMWARE_WINDOW:
            ring_sum -= ring[ring_next]
        else:
            ring_count += 1
        ring[ring_next] = output
        ring_sum += output
        ring_next = (ring_next + 1) % FIRMWARE_WINDOW
        if last_phase is not None:
            change = _wrapped(phase[i] - last_phase)
            changed = int((np.abs(change) > FIRMWARE_PHASE_TOL).sum())
            if changed == 0:
                steady += 1
            else:
                locked = steady >= FIRMWARE_LOCK
                steady = 0
                if locked and changed >= FIRMWARE_MIN_AXES and ring_count == FIRMWARE_WINDOW:
                    jump = -(ring_sum / ring_count + shift)
                    if np.abs(_wrapped(jump / FIRMWARE_STEP - change)).max() < FIRMWARE_MATCH_TOL:
                        shift = shift + (change + np.rint(jump / FIRMWARE_STEP - change)) * FIRMWARE_STEP
                        output = gyro[i] - shift
                        newest = (ring_next + FIRMWARE_WINDOW - 1) % FIRMWARE_WINDOW
                        ring_sum += output - ring[newest]
                        ring[newest] = output
                        events.append({"i": i, "shift": shift.copy(), "step": (shift - (events[-1]["shift"] if events else np.zeros(3))).copy()})
        last_phase = phase[i]
        out[i] = output
    cols = ["i", "dx", "dy", "dz", "sx", "sy", "sz"]
    rows = [[e["i"], *e["step"], *e["shift"]] for e in events]
    return out, pd.DataFrame(rows, columns=cols)
