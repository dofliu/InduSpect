"""聲音層（§5.4 音軌）：逐片聲音異常。

夾具是合成音軌（`synth.AudioSpec`）：1/f 風噪 + 每片每轉一次的寬頻 swish，
缺陷以「指定葉片的 swish 增益」（前緣侵蝕）與「通過時的窄頻正弦」（後緣裂縫哨音）注入。
"""

import os

import numpy as np
import pytest

from blade_proto import acoustics as ac
from blade_proto.acoustics import (
    AudioClip, analyze_audio, analyze_samples, find_ffmpeg, load_audio,
)
from blade_proto.synth import AudioSpec, render_audio, write_wav

SR = 24000


def _run(rpm=12.0, seconds=14.0, seed=1, hint_rpm=True, **kw):
    y, truth = render_audio(AudioSpec(rpm=rpm, duration_s=seconds, seed=seed, **kw))
    res = analyze_samples(AudioClip(y, SR), rpm=rpm if hint_rpm else None)
    return res, truth


def _level_flag(res):
    return next((c for c in res.comparisons
                 if c["metric"] == "band_level_db" and c["flagged"]), None)


def test_healthy_rotor_gives_rpm_and_no_blade_flag():
    res, truth = _run()
    assert res.usable, res.notes
    assert abs(res.rpm_from_audio - truth["rpm"]) / truth["rpm"] < 0.03
    assert abs(res.blade_pass_hz - truth["blade_pass_hz"]) / truth["blade_pass_hz"] < 0.05
    assert res.periodicity_confidence > 0.4
    assert res.am_depth_db > 3.0  # 葉片通過本身就會造成振幅調變
    assert _level_flag(res) is None
    assert not any(b.tonal_exclusive for b in res.blades)
    assert [b.n_passes for b in res.blades] == pytest.approx([3, 3, 3], abs=1)


@pytest.mark.parametrize("blade", [0, 1, 2])
def test_eroded_blade_is_identified(blade):
    """任一片寬頻增益 +6 dB 都要被指出來，且指的是正確那片。"""
    res, _ = _run(broadband_gain_db={blade: 6.0})
    assert res.usable, res.notes
    flag = _level_flag(res)
    assert flag is not None and flag["outlier_index"] == blade
    assert flag["outlier_deviation"] > 2.0  # 方向性：偏高才算
    assert flag["direction"] == "high"
    # 高頻占比也該偏高（侵蝕把能量往上推）
    ratios = [b.high_band_ratio for b in res.blades]
    assert ratios[blade] == max(ratios)


def test_quieter_blade_is_not_flagged_as_defect():
    """比另兩片安靜不是缺陷：方向性指標不能把安靜的那片標成侵蝕。"""
    res, _ = _run(broadband_gain_db={0: 6.0, 1: 6.0})  # A、B 都吵 → C 相對安靜
    assert res.usable, res.notes
    flag = _level_flag(res)
    if flag is not None:
        assert flag["outlier_index"] != 2
        assert flag["outlier_deviation"] > 0


@pytest.mark.parametrize("blade,freq", [(1, 900.0), (2, 1400.0)])
def test_whistle_is_attributed_to_the_right_blade(blade, freq):
    res, _ = _run(whistle={blade: (freq, 0.03)})
    assert res.usable, res.notes
    exclusive = [b for b in res.blades if b.tonal_exclusive]
    assert len(exclusive) == 1
    assert exclusive[0].index == blade
    assert abs(exclusive[0].tonal_freq_hz - freq) / freq < 0.05
    assert exclusive[0].tonal_prominence_db > 8.0


@pytest.mark.parametrize("n_shared", [2, 3])
def test_shared_tone_is_not_attributed_to_a_single_blade(n_shared):
    """**三片（或兩片）在同一頻率都有哨音時，一片都不該被判為獨有。**

    這是 `tonal_exclusive` 存在的理由：設計特徵（鋸齒尾緣、VG 板）、路過的車輛、
    地面的發電機都會在每一片的視窗裡留下同一根峰。指成單片缺陷會讓人去拆錯的葉片。

    這條測試釘住的是一個真實的修正：原本的複查是在 ±3% 的窄頻帶上**再跑一次**
    9 點中值濾波，但手機常見取樣率下那個頻帶只有 4–5 個 bin，達不到中值濾波要求的
    13 個，於是一律回 NaN 而被當成「另兩片沒有」。實測舊做法在這兩個案例上分別把
    3 片與 2 片都判成獨有（共 5 個誤報）。改成讀全頻帶基線在該頻率上的突出量後
    降到 0，而單片哨音仍然抓得到。
    """
    whistle = {i: (1400.0, 0.03) for i in range(n_shared)}
    res, _ = _run(whistle=whistle)
    assert res.usable, res.notes
    # 每一片都要真的量到那根峰（否則這條測試等於什麼都沒驗）
    hit = [b for b in res.blades
           if np.isfinite(b.tonal_freq_hz)
           and abs(b.tonal_freq_hz - 1400.0) / 1400.0 < 0.05
           and b.tonal_prominence_db > 6.0]
    assert len(hit) == n_shared, [
        (b.index, b.tonal_freq_hz, b.tonal_prominence_db) for b in res.blades]
    assert not any(b.tonal_exclusive for b in res.blades), \
        "同一頻率多片都有，就不是「只有這片」"


def test_excess_at_reads_the_requested_frequency_not_the_peak():
    """`_excess_at` 讀的是**指定頻率**上的突出量，不是頻帶內的最大值。

    也順便釘住它不再依賴窄頻中值：帶寬只有幾個 bin 時舊做法回 NaN，
    新做法照樣給得出數字。
    """
    f = np.arange(0, 8001, 25.0)
    spec_db = np.zeros_like(f)
    spec_db[np.argmin(np.abs(f - 1400.0))] = 20.0   # 只有 1400 Hz 有一根峰
    peak_f, peak_db = ac._tonal_peak(spec_db, f, ac.BAND_LO_HZ, ac.BAND_HI_HZ)
    assert abs(peak_f - 1400.0) < 26.0
    assert peak_db > 15.0
    # 峰所在的頻率讀得到；別的頻率讀到的是基線附近
    assert ac._excess_at(spec_db, f, 1400.0, ac.BAND_LO_HZ, ac.BAND_HI_HZ) > 15.0
    assert abs(ac._excess_at(spec_db, f, 3000.0, ac.BAND_LO_HZ, ac.BAND_HI_HZ)) < 1.0
    # 頻帶太窄（bin 數不足中值濾波）時明確回 NaN，不要假裝有答案
    assert not np.isfinite(
        ac._excess_at(spec_db, f, 1400.0, 1360.0, 1440.0))


def test_erosion_and_whistle_on_different_blades_are_both_found():
    res, _ = _run(broadband_gain_db={1: 6.0}, whistle={2: (1400.0, 0.03)})
    assert res.usable, res.notes
    flag = _level_flag(res)
    assert flag is not None and flag["outlier_index"] == 1
    exclusive = [b for b in res.blades if b.tonal_exclusive]
    assert [b.index for b in exclusive] == [2]


def test_wind_dominated_clip_is_reported_unusable_not_guessed():
    """風噪壓過訊號時要明確說不可用，而不是給一個看起來像數據的答案。"""
    res, _ = _run(wind_level=0.6, swish_level=0.01)
    assert not res.usable
    assert res.notes and any("信賴度" in n or "訊噪比" in n or "風噪" in n for n in res.notes)
    assert res.blades == [] and res.comparisons == []


def test_marginal_snr_is_noted_but_still_analyzed():
    """訊噪比偏低時照做比較，但要附上「輕度侵蝕可能漏判」的提醒。"""
    res, _ = _run(wind_level=0.3, broadband_gain_db={1: 6.0})
    assert res.usable, res.notes
    assert any("訊噪比" in n and "偏低" in n for n in res.notes)
    # 位準最高的仍是缺陷那片（只是差異可能小到不足以標記）
    levels = [b.band_level_db for b in res.blades]
    assert levels.index(max(levels)) == 1


def test_asymmetry_rises_with_defect_but_ranges_overlap():
    """1P/3P 不對稱：同一組參數下缺陷會讓它上升（趨勢真實），
    但**跨轉速的值域會重疊**，所以不能單獨當判定門檻。
    這兩件事都鎖進測試，避免日後有人把它當成「> X dB 就是壞掉」。"""
    # 趨勢：同 seed 同轉速，加了缺陷一定往上
    for seed in range(3):
        healthy = _run(seed=seed)[0].asymmetry_db
        eroded = _run(seed=seed, broadband_gain_db={seed % 3: 6.0})[0].asymmetry_db
        assert np.isfinite(healthy) and np.isfinite(eroded)
        assert eroded > healthy, f"seed {seed}: {eroded} 應高於 {healthy}"
    # 重疊：這兩組是掃描 rpm 8–16 × seed 0–4 找出的極端值
    worst_healthy = _run(rpm=10.0, seed=4)[0].asymmetry_db  # 健康裡最高的
    best_eroded = _run(rpm=16.0, seed=2, broadband_gain_db={2: 6.0})[0].asymmetry_db  # 缺陷裡最低的
    assert worst_healthy > best_eroded, (
        f"健康 {worst_healthy:.1f} dB 不再高於缺陷 {best_eroded:.1f} dB —— "
        "若演算法改進到值域分離，請同步更新報告與 SENSITIVITY.md 的措辭")


def test_rpm_estimated_without_hint():
    res, truth = _run(hint_rpm=False)
    assert res.usable, res.notes
    assert abs(res.rpm_from_audio - truth["rpm"]) / truth["rpm"] < 0.05


def test_wav_roundtrip_and_short_clip_error(tmp_path):
    y, _ = render_audio(AudioSpec(duration_s=14.0, seed=2))
    path = str(tmp_path / "a.wav")
    write_wav(path, y, SR)
    clip = load_audio(path)
    assert clip.sample_rate == SR
    assert abs(clip.duration_s - 14.0) < 0.05
    assert np.max(np.abs(clip.samples)) <= 1.0
    # 16-bit 量化誤差以內
    assert np.allclose(clip.samples[:1000], y[:1000], atol=2e-4)

    res = analyze_audio(path, rpm=12.0)
    assert res.usable, res.notes

    with pytest.raises(ValueError):
        analyze_samples(AudioClip(np.zeros(100, np.float32), SR))


def test_ffmpeg_lookup_is_optional():
    """找不到 ffmpeg 不該讓 import 或 WAV 路徑掛掉（只有影片抽音軌才需要）。"""
    ff = find_ffmpeg()
    assert ff is None or os.path.isfile(ff)
