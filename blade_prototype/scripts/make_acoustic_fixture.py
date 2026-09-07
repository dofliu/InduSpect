"""產生聲音層 Dart 移植的交叉驗證夾具。

兩段合成音軌（WAV 進版控）+ Python 在**同一段音軌上**逐階段量到的參考值，
寫進 `flutter_app/test/assets/`：

- `blade_audio_healthy.wav`：三片一致。驗「不誤報」——互比不得標記。
- `blade_audio_eroded.wav`：第 2 片 +4 dB 寬頻（模擬前緣侵蝕）、
  第 3 片 1800 Hz 哨音（模擬後緣裂縫）。驗「真的會報」，而且報在對的那一片。

**參考值一律從寫出去的 WAV 讀回來之後才算**，不是從 render 的 float 陣列算。
兩者差一次 int16 量化；若從 float 算，Dart 讀 WAV 得到的輸入就與參考值不同源，
之後每個對不上的數字都會分不清是移植錯還是量化差。

改動 `acoustics.py` 之後要重跑這支，否則 Flutter 的交叉驗證測試會紅：

    cd blade_prototype && python scripts/make_acoustic_fixture.py

音軌刻意做短（16 kHz / 6 s / 每段 192 KB）：測的是移植正確性，那與長度無關，
而檔案要進版控。16 kHz 的 Nyquist 剛好是分析頻帶上限 8 kHz，頻帶選取不變。
"""
import json, os, sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
import numpy as np
from scipy import signal

from blade_proto import acoustics as ac
from blade_proto.synth import AudioSpec, render_audio, write_wav

OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'flutter_app', 'test', 'assets')
SR, DUR, RPM, SEED = 16000, 6.0, 24.0, 5

SCENARIOS = [
    ('healthy', 'blade_audio_healthy.wav', {}, {}),
    ('eroded', 'blade_audio_eroded.wav', {1: 4.0}, {2: (1800.0, 0.02)}),
]


def _f(v, nd=12):
    """預設存到小數第 12 位。

    位數決定 Dart 端測試容差的下限：轉寫對照顯示兩邊一致到 ~1e-15，
    所以存太少位數會讓測試只驗到「大致相同」，反而放過真正的移植錯誤。
    先前存 6 位、測試寫 1e-9，結果是測試自己紅——差的是**參考值的位數**
    不是計算結果。
    """
    v = float(v)
    return None if not np.isfinite(v) else round(v, nd)


def stage_dump(clip: ac.AudioClip) -> dict:
    """把 `analyze_samples` 的中間量逐階段掏出來（同一條程式路徑，同樣的呼叫順序）。"""
    x = clip.samples.astype(np.float64)
    x = x - x.mean()
    f, t, S = ac._spectrogram(x, clip.sample_rate)
    frame_hz = 1.0 / float(np.median(np.diff(t))) if len(t) > 1 else 1.0

    band = ac._band_energy(f, S, ac.BAND_LO_HZ, ac.BAND_HI_HZ)
    wind = ac._band_energy(f, S, 0.0, ac.WIND_BAND_HZ)
    total = ac._band_energy(f, S, 0.0, ac.BAND_HI_HZ)

    env = np.sqrt(np.maximum(band, 0.0))
    env = signal.savgol_filter(env, min(len(env) // 2 * 2 - 1, 9), 2) if len(env) >= 11 else env
    med = float(np.median(env)) + 1e-20
    snr_db = float(20.0 * np.log10((float(np.percentile(env, 98)) + 1e-20) / med))

    acf = ac._acf(env)
    rot_s, period_s, conf = ac._estimate_rotation(env, frame_hz, 3, None)
    f_bp = 1.0 / period_s if np.isfinite(period_s) and period_s > 0 else float('nan')
    f_rot = 1.0 / rot_s if np.isfinite(rot_s) and rot_s > 0 else float('nan')

    # 固定取樣點：Dart 端逐點比對
    ti = [0, 1, 5, 40, len(t) // 2, len(t) - 1]
    fi = [0, 1, 8, 13, 64, 128, len(f) - 1]
    return {
        'n_freqs': len(f), 'n_times': len(t), 'nperseg': (len(f) - 1) * 2,
        'frame_hz': _f(frame_hz),
        'freq_hz_at': {str(k): _f(f[k]) for k in fi},
        'time_s_at': {str(k): _f(t[k]) for k in ti},
        'mag_at': {f'{a},{b}': _f(S[a, b], 12) for a in fi for b in ti},
        'band_energy_at': {str(k): _f(band[k], 12) for k in ti},
        'wind_sum': _f(wind.sum()), 'total_sum': _f(total.sum()),
        'wind_dominance': _f(wind.sum() / (total.sum() + 1e-20)),
        'envelope_at': {str(k): _f(env[k], 12) for k in ti},
        'envelope_median': _f(med, 12), 'envelope_p98': _f(np.percentile(env, 98), 12),
        'snr_db': _f(snr_db),
        'acf_at': {str(k): _f(acf[k]) for k in (0, 1, 2, 26, 52, 78, 104, 156, 208, 300)},
        'rot_s': _f(rot_s), 'period_s': _f(period_s), 'confidence': _f(conf),
        'blade_pass_hz': _f(f_bp), 'rotor_hz': _f(f_rot),
        'mod_depth_bp': _f(ac._mod_depth(env, frame_hz, f_bp)),
        'mod_depth_rot': _f(ac._mod_depth(env, frame_hz, f_rot)),
        'pass_phase_s': _f(ac._pass_phase(env, frame_hz, rot_s) if np.isfinite(rot_s) else 0.0),
    }


ref = {
    '_readme': [
        '聲音層 Dart 移植的交叉驗證參考值。由 blade_prototype 在同名 WAV 上量出。',
        '參考值從寫出去的 WAV 讀回來之後才算（含 int16 量化），與 Dart 端輸入同源。',
        '改動 acoustics.py 後要重跑 scripts/make_acoustic_fixture.py，否則 Flutter 交叉驗證會紅。',
    ],
    'spec': {'sample_rate': SR, 'duration_s': DUR, 'rpm': RPM, 'seed': SEED,
             'band_lo_hz': ac.BAND_LO_HZ, 'band_hi_hz': ac.BAND_HI_HZ,
             'wind_band_hz': ac.WIND_BAND_HZ, 'high_band_lo_hz': ac.HIGH_BAND_LO_HZ},
    'savgol_9_2_coeffs': [round(float(v), 12) for v in signal.savgol_coeffs(9, 2)],
}

for label, fname, gains, whistle in SCENARIOS:
    spec = AudioSpec(sample_rate=SR, duration_s=DUR, rpm=RPM, seed=SEED,
                     broadband_gain_db=gains, whistle=whistle)
    y, truth = render_audio(spec)
    path = os.path.join(OUT, fname)
    write_wav(path, y, SR)
    clip = ac._read_wav(path)          # 讀回來：與 Dart 端同源
    r = ac.analyze_samples(clip)
    stages = stage_dump(clip)
    # **自我對帳。** `stage_dump` 為了掏出中間量而重寫了一次 `analyze_samples`
    # 的前處理，那是一份重複的程式——`acoustics.py` 改了而這裡沒跟上，就會靜靜
    # 寫出一份錯的參考值，然後 Flutter 端紅在一個看不出原因的數字上。
    # （實際發生過一次：一個順手的字串取代把 savgol 窗長從 9 改成 12。）
    # 所以凡是兩邊都算得出來的量，這裡逐項比對，不一致就直接爆掉。
    for key, got in [('snr_db', r.envelope_snr_db),
                     ('confidence', r.periodicity_confidence),
                     ('blade_pass_hz', r.blade_pass_hz),
                     ('rotor_hz', r.rotor_hz),
                     ('wind_dominance', r.wind_dominance)]:
        mine, theirs = stages[key], _f(got)
        if mine != theirs:
            raise SystemExit(
                f'{label}: stage_dump 的 {key} 與 analyze_samples 不一致'
                f'（{mine} vs {theirs}）——stage_dump 已與 acoustics.py 漂開，'
                f'先對齊再重跑，不要寫出這份夾具')

    ent = {
        'wav': fname, 'wav_bytes': os.path.getsize(path),
        'clip': {'sample_rate': clip.sample_rate, 'n_samples': len(clip.samples),
                 'duration_s': _f(clip.duration_s),
                 'sample_at': {str(k): _f(clip.samples[k], 12)
                               for k in (0, 1, 100, 8000, len(clip.samples) // 2,
                                         len(clip.samples) - 1)}},
        'stages': stages,
        'result': {
            'usable': bool(r.usable), 'n_notes': len(r.notes),
            'rpm_from_audio': _f(r.rpm_from_audio), 'blade_pass_hz': _f(r.blade_pass_hz),
            'rotor_hz': _f(r.rotor_hz), 'periodicity_confidence': _f(r.periodicity_confidence),
            'am_depth_db': _f(r.am_depth_db), 'asymmetry_db': _f(r.asymmetry_db),
            'wind_dominance': _f(r.wind_dominance), 'envelope_snr_db': _f(r.envelope_snr_db),
            'n_passes': len(r.pass_times_s),
            'pass_times_s': [_f(v) for v in r.pass_times_s],
            'blades': [{'index': b.index, 'n_passes': b.n_passes,
                        'band_level_db': _f(b.band_level_db), 'high_band_ratio': _f(b.high_band_ratio),
                        'tonal_freq_hz': _f(b.tonal_freq_hz),
                        'tonal_prominence_db': _f(b.tonal_prominence_db),
                        'tonal_exclusive': bool(b.tonal_exclusive)} for b in r.blades],
            'comparisons': {c['metric']: {'z': _f(c['z']), 'flagged': bool(c['flagged']),
                                          'outlier_index': int(c['outlier_index']),
                                          'outlier_deviation': _f(c['outlier_deviation']),
                                          'others_spread': _f(c['others_spread']),
                                          'direction': c['direction']}
                            for c in r.comparisons},
        },
        'truth': {'rpm': truth['rpm'], 'blade_pass_hz': _f(truth['blade_pass_hz']),
                  'n_passes': len(truth['pass_times_s']),
                  'pass_times_s': [_f(v) for v in truth['pass_times_s']],
                  'broadband_gain_db': {str(k): v for k, v in truth['broadband_gain_db'].items()},
                  'whistle': {str(k): v for k, v in truth['whistle'].items()}},
    }
    ref[label] = ent
    print(f"--- {label}: {fname} {ent['wav_bytes'] / 1024:.0f} KB  usable={r.usable} "
          f"rpm={ent['result']['rpm_from_audio']} (真值 {RPM})")
    print(f"    levels={[b['band_level_db'] for b in ent['result']['blades']]}")
    print(f"    tonal_exclusive={[b['tonal_exclusive'] for b in ent['result']['blades']]}")
    print(f"    comparisons={ {k: v['flagged'] for k, v in ent['result']['comparisons'].items()} }")

with open(os.path.join(OUT, 'blade_acoustic_reference.json'), 'w', encoding='utf-8') as fh:
    json.dump(ref, fh, indent=1, ensure_ascii=False)
    fh.write('\n')
print('已寫出 blade_acoustic_reference.json')
