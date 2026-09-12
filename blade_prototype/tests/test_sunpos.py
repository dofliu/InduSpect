"""太陽方位算法對兩個外部真值：NREL SPA 報告的範例，與 pvlib 的 SPA 實作（有裝才比）。"""

from datetime import datetime, timedelta, timezone

import pytest

from blade_proto.sunpos import SunPosition, lighting_advice, solar_position


def test_matches_nrel_spa_report_example():
    # Reda & Andreas, NREL/TP-560-34302 (rev. 2008), Appendix A.5：
    # 2003-10-17 12:30:30 LST (TZ −7) 於 Golden, CO（39.742476, −105.1786）
    # → 天頂角 50.11162°、方位角 194.34024°（含折射）。
    dt = datetime(2003, 10, 17, 19, 30, 30, tzinfo=timezone.utc)
    sun = solar_position(39.742476, -105.1786, dt)
    assert abs(sun.azimuth_deg - 194.34024) < 0.01
    assert abs((90 - sun.elevation_deg) - 50.11162) < 0.01


def test_matches_pvlib_spa_through_a_day_if_available():
    pvlib = pytest.importorskip("pvlib")
    import pandas as pd

    lat, lon = 24.05, 120.42  # 彰化海岸
    times = pd.date_range("2026-09-12 06:00", "2026-09-12 18:00", freq="30min", tz="Asia/Taipei")
    ref = pvlib.solarposition.spa_python(times, lat, lon, altitude=5)
    for ts, row in ref.iterrows():
        if row["apparent_elevation"] < 2:
            continue
        sun = solar_position(lat, lon, ts.tz_convert("UTC").to_pydatetime())
        assert abs((sun.azimuth_deg - row["azimuth"] + 180) % 360 - 180) < 0.05
        assert abs(sun.elevation_deg - row["apparent_elevation"]) < 0.05


def test_requires_timezone_aware_datetime():
    with pytest.raises(ValueError):
        solar_position(24.0, 120.0, datetime(2026, 9, 12, 4, 0, 0))


def test_facing_away_is_opposite_of_sun():
    assert SunPosition(azimuth_deg=100.0, elevation_deg=40.0).facing_away_deg == 280.0
    assert SunPosition(azimuth_deg=300.0, elevation_deg=40.0).facing_away_deg == 120.0


@pytest.mark.parametrize(
    "sun_az, elev, heading, expected",
    [
        (100.0, 40.0, 100.0, "backlit"),  # 鏡頭正對太陽
        (100.0, 40.0, 140.0, "backlit"),  # 夾角 40°，太陽還在畫面邊
        (100.0, 40.0, 170.0, "side"),
        (100.0, 40.0, 280.0, "front"),  # 背對太陽
        (100.0, 5.0, 170.0, "backlit"),  # 低太陽：側光也算逆光風險
        (100.0, -3.0, 280.0, "night"),
    ],
)
def test_lighting_advice_levels(sun_az, elev, heading, expected):
    level, _ = lighting_advice(SunPosition(sun_az, elev), heading)
    assert level == expected


def test_taiwan_noon_sun_is_south_and_high_in_september():
    # 2026-09-12 12:00 台北時間，彰化：太陽略偏南、高度角約 70°
    dt = datetime(2026, 9, 12, 12, 0, tzinfo=timezone(timedelta(hours=8)))
    sun = solar_position(24.05, 120.42, dt)
    assert 150 < sun.azimuth_deg < 210
    assert 60 < sun.elevation_deg < 80
