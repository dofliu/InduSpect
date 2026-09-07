"""聲音層（§5.4 音軌）：逐片聲音異常分析。

現場人員本來就是靠耳朵先發現葉片問題的，這個模組把它量化。物理依據：

- **前緣侵蝕 → 寬頻噪音上升**。表面變粗糙會加厚紊流邊界層，後緣散射出的寬頻噪音
  跟著變大，能量集中在數百 Hz 到數 kHz。
- **後緣損傷／裂縫／破洞 → 窄頻哨音**。缺口形成空腔或邊緣音（edge tone），
  在頻譜上是一根突出的細峰。
- **關鍵是「哪一片」**：三片葉片每轉各通過觀測者一次，所以缺陷葉片的噪音是
  **以葉片通過週期出現的**。把音軌依通過時刻切成三份互比，就能指出是哪一片在叫；
  這也是它跟「整台風機都吵」「風噪很大」的分辨方式。

流程：

1. 讀音軌（WAV 直讀；其他容器用 ffmpeg 轉檔）→ 單聲道
2. STFT → 分析頻帶的逐幀能量 = 振幅包絡（wind turbine 的 AM 現象）
3. 包絡自相關求**葉片通過週期**（有 rpm 就在 3/rev 附近搜尋），再定相位求各次通過時刻
4. 每片取自己通過時刻 ±T/6 的幀 → 平均頻譜、寬頻位準、窄頻峰突出量
5. 三片互比（沿用幾何層的 `compare_metric`）+ 風噪可用性判斷

**風噪是這一層的頭號干擾**，所以輸出一律附可用性判斷：低頻占比過高、
包絡週期性信賴度不足、或訊噪比太低時，明確回報「不可用」而不是給一個看起來像數據的數字。
"""

from __future__ import annotations

import contextlib
import os
import shutil
import subprocess
import tempfile
import wave
from dataclasses import dataclass, asdict, field

import numpy as np
from scipy import signal

from .geometry import compare_metric

__all__ = [
    "AudioClip", "BladeAcoustics", "AcousticResult",
    "load_audio", "find_ffmpeg", "extract_audio", "analyze_audio", "analyze_samples",
]

# 分析頻帶：下限避開風噪與機械低頻，上限避開手機麥克風的高頻滾降
BAND_LO_HZ = 400.0
BAND_HI_HZ = 8000.0
WIND_BAND_HZ = 200.0  # 此頻率以下視為風噪／機械低頻主導區
HIGH_BAND_LO_HZ = 2000.0  # 「高頻占比」的分界（侵蝕會把能量往上推）


@dataclass
class AudioClip:
    samples: np.ndarray  # float32, 單聲道, -1..1
    sample_rate: int

    @property
    def duration_s(self) -> float:
        return len(self.samples) / float(self.sample_rate)


@dataclass
class BladeAcoustics:
    """單片葉片（實際上是「通過順序第 i 位」）的聲學指標。"""

    index: int
    n_passes: int
    band_level_db: float  # 分析頻帶 RMS，dB 相對三片中位數
    high_band_ratio: float  # 2–8 kHz / 0.4–8 kHz 能量比
    tonal_freq_hz: float  # 最突出的窄頻峰頻率（無則 nan）
    tonal_prominence_db: float  # 該峰高出本地頻譜基線多少 dB
    tonal_exclusive: bool  # 該峰是否只在這片出現（另兩片同頻沒有）

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class AcousticResult:
    sample_rate: int
    duration_s: float
    blade_pass_hz: float  # 葉片通過頻率（= rpm/60 × 3）
    rpm_from_audio: float
    rotor_hz: float  # 轉子轉動頻率（1P）
    periodicity_confidence: float  # 0–1，1P 與 3P 兩個 lag 的 ACF 較大者
    am_depth_db: float  # 葉片通過頻率（3P）上的振幅調變深度
    asymmetry_db: float  # 1P / 3P 調變比（>0 = 三片聲音不一致，單片異常的直接指標）
    wind_dominance: float  # <200 Hz 能量占比
    envelope_snr_db: float  # 包絡峰值相對中位數
    usable: bool
    pass_times_s: list[float] = field(default_factory=list)
    blades: list[BladeAcoustics] = field(default_factory=list)
    comparisons: list[dict] = field(default_factory=list)
    spectra: dict = field(default_factory=dict)  # {"freqs_hz": [...], "blade_db": [[...], ...]}
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["blades"] = [b.to_dict() for b in self.blades]
        return d


# ---------------------------------------------------------------- 讀檔


def find_ffmpeg() -> str | None:
    """找 ffmpeg：環境變數 → PATH → Playwright 隨附的版本（本容器就有）。"""
    env = os.environ.get("FFMPEG_BINARY")
    if env and os.path.isfile(env):
        return env
    found = shutil.which("ffmpeg")
    if found:
        return found
    root = os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "/opt/pw-browsers")
    if os.path.isdir(root):
        for name in sorted(os.listdir(root)):
            if name.startswith("ffmpeg"):
                for cand in ("ffmpeg-linux", "ffmpeg-mac", "ffmpeg.exe", "ffmpeg"):
                    p = os.path.join(root, name, cand)
                    if os.path.isfile(p) and os.access(p, os.X_OK):
                        return p
    return None


def _read_wav(path: str) -> AudioClip:
    with contextlib.closing(wave.open(path, "rb")) as w:
        n_ch, width, sr, n_frames = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n_frames)
    if width == 1:  # 8-bit WAV 是無號數
        data = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    elif width == 2:
        data = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif width == 3:  # 24-bit：補一個位元組再當 int32 讀
        b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        as32 = np.zeros((len(b), 4), dtype=np.uint8)
        as32[:, 1:] = b
        data = as32.view("<i4").ravel().astype(np.float32) / (2.0 ** 31)
    elif width == 4:
        data = np.frombuffer(raw, dtype="<i4").astype(np.float32) / (2.0 ** 31)
    else:
        raise ValueError(f"不支援的 WAV 位元深度：{width * 8} bit")
    if n_ch > 1:
        data = data.reshape(-1, n_ch).mean(axis=1)
    return AudioClip(samples=data.astype(np.float32), sample_rate=sr)


def extract_audio(path: str, sample_rate: int = 48000) -> AudioClip:
    """用 ffmpeg 把任何容器（mp4/mov/m4a…）的音軌轉成單聲道 WAV 再讀。"""
    ff = find_ffmpeg()
    if ff is None:
        raise RuntimeError(
            "找不到 ffmpeg，無法從影片抽音軌。請安裝 ffmpeg、設定 FFMPEG_BINARY 環境變數，"
            "或改用 --audio 直接提供 WAV 檔。")
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "audio.wav")
        proc = subprocess.run(
            [ff, "-v", "error", "-y", "-i", path, "-vn", "-ac", "1",
             "-ar", str(sample_rate), "-c:a", "pcm_s16le", out],
            capture_output=True, text=True)
        if proc.returncode != 0 or not os.path.exists(out):
            raise RuntimeError(f"ffmpeg 抽音軌失敗（{path}）：{proc.stderr.strip()[:400]}")
        if os.path.getsize(out) < 1024:
            raise RuntimeError(f"{path} 似乎沒有音軌（抽出的 WAV 是空的）")
        return _read_wav(out)


def load_audio(path: str) -> AudioClip:
    """讀音訊。`.wav` 直讀（純 stdlib），其他格式走 ffmpeg。"""
    if path.lower().endswith(".wav"):
        try:
            return _read_wav(path)
        except (wave.Error, ValueError):
            return extract_audio(path)  # 非 PCM 的 wav（如 float32）交給 ffmpeg
    return extract_audio(path)


# ---------------------------------------------------------------- 分析


def _spectrogram(x: np.ndarray, sr: int, win_s: float = 0.032):
    nper = int(2 ** round(np.log2(max(64, win_s * sr))))
    f, t, Z = signal.stft(x, fs=sr, nperseg=nper, noverlap=nper // 2, window="hann")
    return f, t, np.abs(Z)


def _band_energy(f: np.ndarray, S: np.ndarray, lo: float, hi: float) -> np.ndarray:
    sel = (f >= lo) & (f <= hi)
    if not sel.any():
        return np.zeros(S.shape[1])
    return (S[sel] ** 2).sum(axis=0)


def _acf(env: np.ndarray) -> np.ndarray:
    """包絡的正規化自相關（lag 0 = 1）。"""
    e = env - env.mean()
    if not np.any(e):
        return np.zeros(len(env))
    ac = np.correlate(e, e, mode="full")[len(e) - 1:]
    return ac / (ac[0] + 1e-12)


def _refine_peak(ac: np.ndarray, k: int) -> float:
    """拋物線精修 ACF 峰位置（回傳可能非整數的 lag）。"""
    if 0 < k < len(ac) - 1:
        y0, y1, y2 = ac[k - 1], ac[k], ac[k + 1]
        denom = y0 - 2 * y1 + y2
        if denom != 0:
            return float(k + 0.5 * (y0 - y2) / denom)
    return float(k)


def _at_lag(ac: np.ndarray, lag: float) -> float:
    """線性內插取 ACF 值。"""
    if lag < 0 or lag >= len(ac) - 1:
        return 0.0
    i = int(np.floor(lag))
    w = lag - i
    return float(ac[i] * (1 - w) + ac[i + 1] * w)


def _estimate_rotation(env: np.ndarray, frame_hz: float, n_blades: int,
                       expect_rpm: float | None):
    """求轉子週期與葉片通過週期。回傳 (T_rot 秒, T_bp 秒, 信賴度 0–1)。

    兩個要處理的糾纏：

    1. **ACF 的諧波歧義**：三片一致時包絡以葉片通過週期重複，ACF 在 T_bp、2T_bp、3T_bp
       都有高峰，最大值落在哪一個不一定。所以找到峰之後要判斷它是基頻還是諧波——
       用「1/n_blades 處還有沒有明顯的峰」來判：有，代表找到的是轉子週期（3P 的三倍）；
       沒有，代表找到的就是葉片通過週期。
    2. **單片異常會把主週期從 3P 推到 1P**：三片一樣時 3P 主導，有一片特別吵時
       1P 冒出來。所以信賴度取兩個 lag 的 ACF 較大者——任一站得住就代表鎖到了轉動，
       不能因為 3P 弱就判不可用，那正是我們要找的不對稱。
    """
    ac = _acf(env)
    if not np.any(ac):
        return float("nan"), float("nan"), 0.0
    if expect_rpm and expect_rpm > 0:
        rot_lag = frame_hz * 60.0 / expect_rpm
        lo, hi = int(rot_lag * 0.8), int(np.ceil(rot_lag * 1.25))
    else:
        # 轉子週期 1–10 秒（6–60 rpm）；下界用 T_bp 尺度，讓基頻也落在窗內
        lo, hi = int(frame_hz * 0.5), int(frame_hz * 10.0)
    lo = max(2, lo)
    hi = min(len(ac) - 2, hi)
    if hi <= lo + 1:
        return float("nan"), float("nan"), 0.0
    k = _refine_peak(ac, int(np.argmax(ac[lo:hi + 1])) + lo)

    # 找到的峰是轉子週期還是葉片通過週期？看 k/n_blades 處是否也有實質的峰
    sub = k / n_blades
    ac_k, ac_sub = _at_lag(ac, k), _at_lag(ac, sub)
    if sub >= 2 and ac_sub >= max(0.15, 0.30 * ac_k):
        rot_lag_f, bp_lag_f = k, sub  # k 是轉子週期（3P 的整數倍）
    else:
        rot_lag_f, bp_lag_f = k * n_blades, k  # k 就是葉片通過週期
    if rot_lag_f > len(ac) - 2:
        # 音軌太短，涵蓋不到一整圈：仍可用 T_bp，轉速由 T_bp 推算
        rot_lag_f = bp_lag_f * n_blades
    conf = max(_at_lag(ac, bp_lag_f), _at_lag(ac, min(rot_lag_f, len(ac) - 2)))
    return (float(rot_lag_f / frame_hz), float(bp_lag_f / frame_hz),
            float(np.clip(conf, 0.0, 1.0)))


def _mod_depth(env: np.ndarray, frame_hz: float, freq: float) -> float:
    """指定頻率上的振幅調變分量（相對包絡均值的比例，0–1）。"""
    if not np.isfinite(freq) or freq <= 0 or len(env) < 8:
        return float("nan")
    t = np.arange(len(env)) / frame_hz
    mean = env.mean()
    if mean <= 0:
        return float("nan")
    c = 2.0 * np.abs(np.sum(env * np.exp(-2j * np.pi * freq * t))) / len(env)
    return float(c / mean)


def _pass_phase(env: np.ndarray, frame_hz: float, period_s: float) -> float:
    """在一個週期內掃相位，取包絡同步平均最大者（= 葉片通過的時刻）。"""
    T = period_s * frame_hz
    n = len(env)
    best_phi, best_val = 0.0, -np.inf
    for phi in np.linspace(0.0, T, 24, endpoint=False):
        idx = np.round(np.arange(phi, n - 1, T)).astype(int)
        idx = idx[(idx >= 0) & (idx < n)]
        if len(idx) == 0:
            continue
        v = float(env[idx].mean())
        if v > best_val:
            best_phi, best_val = float(phi), v
    return best_phi / frame_hz


def _ratio_to_db(ratio: float) -> float:
    """調變比例 → 峰谷差 dB。"""
    if not np.isfinite(ratio):
        return float("nan")
    r = float(np.clip(ratio, 0.0, 0.999))
    return float(20.0 * np.log10((1.0 + r) / (1.0 - r)))


def _tonal_excess(spec_db: np.ndarray, f: np.ndarray, lo: float, hi: float,
                  med_bins: int = 25):
    """頻譜減去中值濾波基線 → 突出量。回傳 (頻率陣列, 突出量陣列)。

    頻帶內 bin 數不足中值濾波所需時回兩個空陣列（呼叫端要當成「量不出來」，
    不是「沒有峰」）。
    """
    sel = (f >= lo) & (f <= hi)
    if sel.sum() < med_bins + 4:
        return np.empty(0), np.empty(0)
    fs, ss = f[sel], spec_db[sel]
    baseline = signal.medfilt(ss, kernel_size=med_bins if med_bins % 2 else med_bins + 1)
    return fs, ss - baseline


def _tonal_peak(spec_db: np.ndarray, f: np.ndarray, lo: float, hi: float, med_bins: int = 25):
    """窄頻峰：突出量最大處。回傳 (頻率, 突出 dB)。"""
    fs, excess = _tonal_excess(spec_db, f, lo, hi, med_bins)
    if len(fs) == 0:
        return float("nan"), float("nan")
    k = int(np.argmax(excess))
    return float(fs[k]), float(excess[k])


def _excess_at(spec_db: np.ndarray, f: np.ndarray, freq: float,
               lo: float, hi: float, med_bins: int = 25) -> float:
    """**指定頻率**上的突出量（取最近的 bin）。用於「這根峰是不是只有這片有」。

    原本的做法是在 ±3% 的窄頻帶上**再跑一次**中值濾波。那是錯的：手機常見取樣率下
    ±3% 只有 4–5 個 bin（48 kHz/nperseg 2048 → bin 間距 23 Hz，1800 Hz 的 ±3% 是
    108 Hz），達不到 9 點中值濾波要求的 13 個 bin，於是一律回 NaN 而被呼叫端當成
    「另兩片在這個頻率沒有東西」。結果 `tonal_exclusive` 退化成「突出量 ≥ 6 dB」，
    完全沒有驗過獨有性——三片同時有的哨音（設計特徵、路過的車輛、發電機）
    會被報成單片缺陷。

    全頻帶的基線本來就為了找自己的峰算過一次，直接讀那個頻率上的值就好，
    不需要窄頻中值。
    """
    fs, excess = _tonal_excess(spec_db, f, lo, hi, med_bins)
    if len(fs) == 0 or not np.isfinite(freq):
        return float("nan")
    return float(excess[int(np.argmin(np.abs(fs - freq)))])


def analyze_samples(
    clip: AudioClip,
    *,
    rpm: float | None = None,
    n_blades: int = 3,
    pass_times_hint: list[float] | None = None,
    min_confidence: float = 0.25,
    min_snr_db: float = 1.5,
    marginal_snr_db: float = 4.0,
    max_wind_dominance: float = 0.97,
    tonal_min_prominence_db: float = 6.0,
    level_noise_floor_db: float = 0.8,
) -> AcousticResult:
    """分析已載入的音訊。

    `rpm` 由影片分析提供時，週期搜尋會收斂到 3/rev 附近（更穩）。
    `pass_times_hint` 可傳影片的六點鐘時刻，用來把「通過順序」對齊到實際葉片編號。
    """
    notes: list[str] = []
    x = clip.samples.astype(np.float64)
    if len(x) < clip.sample_rate // 2:
        raise ValueError("音訊太短（不足 0.5 秒）")
    x = x - x.mean()
    f, t, S = _spectrogram(x, clip.sample_rate)
    frame_hz = 1.0 / float(np.median(np.diff(t))) if len(t) > 1 else 1.0

    band = _band_energy(f, S, BAND_LO_HZ, BAND_HI_HZ)
    wind = _band_energy(f, S, 0.0, WIND_BAND_HZ)
    total = _band_energy(f, S, 0.0, BAND_HI_HZ)
    wind_dominance = float(wind.sum() / (total.sum() + 1e-20))

    env = np.sqrt(np.maximum(band, 0.0))
    env = signal.savgol_filter(env, min(len(env) // 2 * 2 - 1, 9), 2) if len(env) >= 11 else env
    med = float(np.median(env)) + 1e-20
    snr_db = float(20.0 * np.log10((float(np.percentile(env, 98)) + 1e-20) / med))

    rot_s, period_s, confidence = _estimate_rotation(env, frame_hz, n_blades, rpm)
    f_bp = 1.0 / period_s if np.isfinite(period_s) and period_s > 0 else float("nan")
    f_rot = 1.0 / rot_s if np.isfinite(rot_s) and rot_s > 0 else float("nan")
    rpm_audio = f_rot * 60.0 if np.isfinite(f_rot) else float("nan")
    m_bp, m_rot = _mod_depth(env, frame_hz, f_bp), _mod_depth(env, frame_hz, f_rot)
    am_db = _ratio_to_db(m_bp)
    asym_db = float(20.0 * np.log10((m_rot + 1e-6) / (m_bp + 1e-6))) \
        if np.isfinite(m_bp) and np.isfinite(m_rot) else float("nan")

    usable = True
    if not np.isfinite(period_s):
        usable = False
        notes.append("包絡找不到週期性，無法切分葉片（可能風噪過大或風機未轉動）")
    if confidence < min_confidence:
        usable = False
        notes.append(f"轉動週期信賴度僅 {confidence:.2f}（門檻 {min_confidence}）："
                     f"包絡鎖不到 1P 或 3P，逐片比較不可信")
    if snr_db < min_snr_db:
        usable = False
        notes.append(f"包絡訊噪比僅 {snr_db:.1f} dB（門檻 {min_snr_db}）：葉片通過的起伏被雜訊淹沒")
    if usable and snr_db < marginal_snr_db:
        # 不判為不可用：位準比較照做，但要說清楚只有較大的差異才抓得到。
        # 合成資料實測：包絡 SNR 約 5 dB 時 +3 dB 的侵蝕仍可標記，
        # 降到約 2 dB 時同樣的缺陷只量到 +1.3 dB，落在雜訊底以下被抑制。
        notes.append(f"包絡訊噪比 {snr_db:.1f} dB 偏低（建議 ≥ {marginal_snr_db:.0f} dB）："
                     f"只有明顯的逐片差異抓得到，輕度侵蝕可能漏判；"
                     f"建議在較低風速、站到下風處並加防風罩重錄")
    if wind_dominance > max_wind_dominance:
        usable = False
        notes.append(f"低於 {WIND_BAND_HZ:.0f} Hz 的能量占 {wind_dominance * 100:.0f}%："
                     f"風噪主導，建議站到下風處並加防風罩重錄")

    blades: list[BladeAcoustics] = []
    comparisons: list[dict] = []
    spectra: dict = {}
    pass_times: list[float] = []

    if usable:
        # 相位以轉子週期為錨：三片的標籤在整段音軌內保持一致
        # （只鎖葉片通過週期的話，標籤每轉可能整體位移一格）
        phase_s = _pass_phase(env, frame_hz, rot_s) if np.isfinite(rot_s) else 0.0
        phase_s = phase_s % period_s if np.isfinite(period_s) and period_s > 0 else phase_s
        pass_times = [float(v) for v in np.arange(phase_s, clip.duration_s, period_s)]
        if pass_times_hint:
            # 以影片的六點鐘時刻對齊：找出最接近第一個 hint 的通過，讓它成為葉片 A
            offsets = [min(range(len(pass_times)), key=lambda i: abs(pass_times[i] - h))
                       for h in pass_times_hint[:1]]
            if offsets:
                shift = offsets[0] % n_blades
                pass_times = pass_times[shift:] + pass_times[:0]
                notes.append("葉片標籤已對齊影片的六點鐘時刻")
        else:
            notes.append("葉片標籤 A/B/C 為通過觀測者的先後順序（循環），非實際葉片編號")

        half = period_s / (2.0 * n_blades)  # 三片的視窗互不重疊
        blade_frames: list[list[int]] = [[] for _ in range(n_blades)]
        for k, tp in enumerate(pass_times):
            sel = np.flatnonzero(np.abs(t - tp) <= half)
            if len(sel):
                blade_frames[k % n_blades].extend(int(i) for i in sel)

        eps = 1e-20
        mean_specs, levels, ratios, tonals = [], [], [], []
        for b in range(n_blades):
            idx = blade_frames[b]
            if len(idx) < 3:
                mean_specs.append(np.full(len(f), np.nan))
                levels.append(float("nan"))
                ratios.append(float("nan"))
                tonals.append((float("nan"), float("nan")))
                continue
            spec = S[:, idx].mean(axis=1)
            mean_specs.append(spec)
            e_band = float((spec[(f >= BAND_LO_HZ) & (f <= BAND_HI_HZ)] ** 2).sum())
            e_high = float((spec[(f >= HIGH_BAND_LO_HZ) & (f <= BAND_HI_HZ)] ** 2).sum())
            levels.append(10.0 * np.log10(e_band + eps))
            ratios.append(e_high / (e_band + eps))
            tonals.append(_tonal_peak(20.0 * np.log10(spec + eps), f, BAND_LO_HZ, BAND_HI_HZ))

        finite = [v for v in levels if np.isfinite(v)]
        ref = float(np.median(finite)) if finite else 0.0
        rel_levels = [(v - ref) if np.isfinite(v) else float("nan") for v in levels]

        for b in range(n_blades):
            tf, tp_db = tonals[b]
            exclusive = False
            if np.isfinite(tf) and np.isfinite(tp_db) and tp_db >= tonal_min_prominence_db:
                others = []
                for o in range(n_blades):
                    if o == b or not np.isfinite(mean_specs[o]).any():
                        continue
                    # 讀另一片在**同一個頻率**上的突出量（全頻帶基線，不重跑窄頻中值）
                    op = _excess_at(20.0 * np.log10(mean_specs[o] + eps), f, tf,
                                    BAND_LO_HZ, BAND_HI_HZ)
                    others.append(op if np.isfinite(op) else 0.0)
                exclusive = bool(others) and tp_db - max(others) >= tonal_min_prominence_db / 2.0
            blades.append(BladeAcoustics(
                index=b,
                n_passes=sum(1 for k in range(len(pass_times)) if k % n_blades == b),
                band_level_db=float(rel_levels[b]), high_band_ratio=float(ratios[b]),
                tonal_freq_hz=float(tf), tonal_prominence_db=float(tp_db),
                tonal_exclusive=exclusive))

        # 方向性：只有「比另兩片吵／高頻更多」才是缺陷徵兆；比較安靜的那片不是侵蝕
        if sum(np.isfinite(v) for v in rel_levels) >= 2:
            comparisons.append(compare_metric(
                "band_level_db", [float(v) for v in rel_levels], level_noise_floor_db,
                direction="high").to_dict())
        if sum(np.isfinite(v) for v in ratios) >= 2:
            comparisons.append(compare_metric(
                "high_band_ratio", [float(v) for v in ratios], 0.02, direction="high").to_dict())

        # 頻譜輸出降採樣（報告畫圖用；全解析度沒必要塞進 JSON）
        keep = (f >= BAND_LO_HZ) & (f <= BAND_HI_HZ)
        fk = f[keep]
        step = max(1, len(fk) // 220)
        spectra = {
            "freqs_hz": [float(v) for v in fk[::step]],
            "blade_db": [[float(v) for v in (20.0 * np.log10(s[keep][::step] + eps) - ref / 2.0)]
                         if np.isfinite(s).any() else [] for s in mean_specs],
        }

    return AcousticResult(
        sample_rate=clip.sample_rate, duration_s=clip.duration_s,
        blade_pass_hz=float(f_bp), rotor_hz=float(f_rot), rpm_from_audio=float(rpm_audio),
        periodicity_confidence=float(confidence), am_depth_db=float(am_db),
        asymmetry_db=float(asym_db),
        wind_dominance=wind_dominance, envelope_snr_db=snr_db, usable=usable,
        pass_times_s=[round(v, 3) for v in pass_times], blades=blades,
        comparisons=comparisons, spectra=spectra, notes=notes,
    )


def analyze_audio(path: str, **kw) -> AcousticResult:
    """從檔案（WAV 或含音軌的影片）分析。"""
    return analyze_samples(load_audio(path), **kw)
