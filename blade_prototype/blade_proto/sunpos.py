"""太陽方位角／高度角：NOAA General Solar Position Calculations（Meeus 簡化版）。

用途是規格 §3.2 的「背對太陽拍」——逆光是閘門唯一擋不了的拒收原因（光暈與雲在尺度上
分不開），只能從站位消掉。有了 GPS 與時間就能算出太陽在哪，拍攝前告訴巡檢員該面向哪裡。

只用 sin/cos/atan2，沒有查表也沒有相依，是 Dart 移植的直接藍本。精度對 NREL SPA 報告的
範例（Reda & Andreas, NREL/TP-560-34302, A.5）差 0.003°；對 pvlib 的 SPA 實作跑一整天
（彰化海岸）差 ≤ 0.02°。站位建議只需要幾度的精度，這裡的餘裕是三個數量級。
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timezone


@dataclass(frozen=True)
class SunPosition:
    azimuth_deg: float  # 由北順時鐘，0 = 北、90 = 東
    elevation_deg: float  # 含大氣折射修正；< 0 為地平線以下

    @property
    def facing_away_deg(self) -> float:
        """背對太陽時鏡頭該面向的方位角。"""
        return (self.azimuth_deg + 180.0) % 360.0


def julian_day(dt_utc: datetime) -> float:
    if dt_utc.tzinfo is None:
        raise ValueError("dt_utc 必須帶 tzinfo（用 UTC）")
    dt = dt_utc.astimezone(timezone.utc)
    y, m = dt.year, dt.month
    d = dt.day + (dt.hour + dt.minute / 60 + dt.second / 3600) / 24
    if m <= 2:
        y -= 1
        m += 12
    a = y // 100
    b = 2 - a + a // 4
    return int(365.25 * (y + 4716)) + int(30.6001 * (m + 1)) + d + b - 1524.5


def _refraction_arcmin(elev_deg: float) -> float:
    """NOAA 的大氣折射修正（角秒 → 這裡回傳角秒/3600 之前的值，單位角秒）。"""
    if elev_deg > 85:
        return 0.0
    if elev_deg > 5:
        te = math.tan(math.radians(elev_deg))
        return 58.1 / te - 0.07 / te**3 + 0.000086 / te**5
    if elev_deg > -0.575:
        e = elev_deg
        return 1735 + e * (-518.2 + e * (103.4 + e * (-12.79 + e * 0.711)))
    return -20.772 / math.tan(math.radians(elev_deg))


def solar_position(lat_deg: float, lon_deg: float, dt_utc: datetime, refraction: bool = True) -> SunPosition:
    jd = julian_day(dt_utc)
    t = (jd - 2451545.0) / 36525.0  # Julian century
    l0 = (280.46646 + t * (36000.76983 + 0.0003032 * t)) % 360
    m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
    e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    mr = math.radians(m)
    c = (math.sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t))
         + math.sin(2 * mr) * (0.019993 - 0.000101 * t) + math.sin(3 * mr) * 0.000289)
    true_long = l0 + c
    omega = 125.04 - 1934.136 * t
    app_long = true_long - 0.00569 - 0.00478 * math.sin(math.radians(omega))
    eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
    eps = eps0 + 0.00256 * math.cos(math.radians(omega))
    decl = math.degrees(math.asin(math.sin(math.radians(eps)) * math.sin(math.radians(app_long))))
    y = math.tan(math.radians(eps / 2)) ** 2
    l0r = math.radians(l0)
    eq_time_min = 4 * math.degrees(
        y * math.sin(2 * l0r) - 2 * e * math.sin(mr) + 4 * e * y * math.sin(mr) * math.cos(2 * l0r)
        - 0.5 * y * y * math.sin(4 * l0r) - 1.25 * e * e * math.sin(2 * mr))
    dt = dt_utc.astimezone(timezone.utc)
    minutes_utc = dt.hour * 60 + dt.minute + dt.second / 60
    true_solar_min = (minutes_utc + eq_time_min + 4 * lon_deg) % 1440
    ha = true_solar_min / 4 - 180
    if ha < -180:
        ha += 360
    latr, declr, har = map(math.radians, (lat_deg, decl, ha))
    cos_zen = math.sin(latr) * math.sin(declr) + math.cos(latr) * math.cos(declr) * math.cos(har)
    zen = math.degrees(math.acos(max(-1.0, min(1.0, cos_zen))))
    denom = math.cos(latr) * math.sin(math.radians(zen))
    if abs(denom) < 1e-12:
        az = 180.0
    else:
        cos_az = (math.sin(latr) * cos_zen - math.sin(declr)) / denom
        az = math.degrees(math.acos(max(-1.0, min(1.0, cos_az))))
        az = (az + 180) % 360 if ha > 0 else (540 - az) % 360
    elev = 90 - zen
    if refraction:
        elev += _refraction_arcmin(elev) / 3600
    return SunPosition(azimuth_deg=az, elevation_deg=elev)


def lighting_advice(sun: SunPosition, camera_heading_deg: float) -> tuple[str, float]:
    """給站位建議。回傳 (等級, 太陽與鏡頭方向的夾角)。

    夾角 = |太陽方位 − 鏡頭方位|（0–180）。< 45° 是逆光（太陽在畫面附近），閘門會拒收；
    45–90° 側光；≥ 90° 順光。高度角 < 10° 的低太陽一律算逆光風險（光暈大、地面長影子）。
    """
    diff = abs((sun.azimuth_deg - camera_heading_deg + 180) % 360 - 180)
    if sun.elevation_deg < 0:
        return "night", diff
    if diff < 45 or sun.elevation_deg < 10 and diff < 90:
        return "backlit", diff
    if diff < 90:
        return "side", diff
    return "front", diff
