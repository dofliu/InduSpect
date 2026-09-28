"""`scripts/commons_portable_fetch.py` 的守門：可攜版 Commons 縮圖抓取器。

這個腳本是要**帶到另一個網路上跑**的（本機出口 IP 已被 upload.wikimedia.org 持續封鎖），
所以測試守的不是「功能正確」而是**「不得偷偷做壞事」**——一個沒人盯著的下載器在別人的網路上
偷偷加速、偷偷換身分、偷偷把錯誤頁當成抓到了，代價是那個網路也被封、而且要好幾天才發現。

十條不可退化的約定：
  ① **絕不並發、絕不換身分**：UA 就是 repo 那一個帶聯絡方式的字串（與 `fetch_commons_turbines` 同一個），
     原始碼裡沒有任何 threading／並發，也沒有任何旗標能改 UA 或加 worker。
  ② **429 一律全額等 `Retry-After`**：伺服器說 600 就等 600（既有腳本的 cap=300 會夾成一半、
     提早敲門，那正是懲罰從 300 被墊到 600 的最可能原因），而且同一張只重試一次、第二次中止整趟。
  ③ **只送常用縮圖寬度**：非常用寬度每張都要現算縮圖，是真正昂貴的請求；一律改寫或拒絕，
     而且**任何情況都不抓原圖**（manifest 裡 82 張的 `thumb_url` 其實是原圖網址）。
  ④ **續傳只跳過真的抓完的檔**：0 byte／截斷檔／HTML 錯誤頁都不算完成（光看大小會把 30 KB 的
     429 錯誤頁當成影像，之後 `cv2.imread` 回 None，只會看到「怎麼少了幾張」而查不出原因）；
     只驗開頭的 magic 還不夠——截斷的 JPEG 前 3 個 byte 一模一樣，所以結尾標記也要驗。
  ⑤ **`--dry-run` 一個請求都不准發**（注入一個會 raise 的假抓取器來證明它沒被呼叫）。
  ⑥ **檔名是驗證端唯一的對應鍵**（`c<pageid>.jpg`），而**待抓清單以磁碟實際狀態為準**：
     manifest 的 `file` 欄位只說「原機器上曾經抓到過」，這台機器上有沒有要看磁碟；
     磁碟濾一定要排在 `--limit`／`--per-model` **之前**，否則續傳原地空轉。
  ⑦ **全域 429 預算**：每張各自重試成功不算沒事——收到 429 步調要**加倍**（不是象徵性地加幾秒），
     累計超過門檻要中止整趟（不是跑完回報成功），而且每一次 429 的**時刻、網址、Retry-After、
     實際等待秒數**都要寫進 `fetch_log.json`（那是寄給 bot-traffic@wikimedia.org 的實證）。
     這一條守的是「**不會害使用者的新 IP 也被封**」。
  ⑧ **煞車要跨趟**：單趟的預算不算煞車——這支腳本的 UX 就是「中斷後重跑同一行就是續傳」，
     而被限流中止的畫面停在「抓到 5/313」，包進 `while ! cmd; do sleep 60; done` 是最自然的寫法。
     所以：被限流／被擋中止過就**拒跑**（rc=2、零請求），`--new-network` 是唯一的解除方式，
     429 預算的起算值是**最近 24 小時**內的次數而不是 0；而減速要能**回復**（否則使用者會以為
     當掉了而 Ctrl-C）、`--pace` 的地板是腳本自己推導的 7.2 s（不是「建議」）、
     永久失敗的圖不准佔住 `--limit` 的名額、中止那一趟的收尾統計要對得上帳。

  ⑨ **鏡像那條路的規則刻意與 Wikimedia 不同**（步調 1 s、不計入 429 預算、抓的是原圖），
     所以每一條「為什麼這裡可以」都要有測試守著——否則下一個人會順手把它們套回 Wikimedia。
  ⑩ **上面那些的邊界綁在常數上**（`MAX_TOTAL_429`／`RECENT_429_WINDOW_H`／`PACE_RECOVER_AFTER`
     ／`FAIL_STREAK_DEMOTE`／`TAIL_PROBE_BYTES`／`SAFE_PACE_FLOOR_S`），不是寫死的數字：
     放寬煞車的人要先讓測試說話，而不是看到一條看不懂的紅線。

**測試不碰網路**：所有會連線的地方都由注入的假函式取代（`fetch_one`／`main` 的 `fetch=`／`sleep=`
兩個縫沿用 `fetch_commons_turbines.subcategories(fetch=)` 的慣例），等待也一律是假的——
驗的是「等了幾秒」這個數字，不是真的睡 600 秒。
"""

from __future__ import annotations

import json
import re
import sys
import urllib.error
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import commons_portable_fetch as F  # noqa: E402

MANIFEST = ROOT / "data" / "commons_turbines_manifest.json"
SOURCE = (ROOT / "scripts" / "commons_portable_fetch.py").read_text(encoding="utf-8")

THUMB = "https://thumb.wikimedia.org/wikipedia/commons/thumb/0/0c/X.jpg/2400px-X.jpg"
ORIGINAL = "https://upload.wikimedia.org/wikipedia/commons/0/0c/X.jpg"
URL = "https://thumb.wikimedia.org/wikipedia/commons/thumb/0/0c/X.jpg/1280px-X.jpg"

GOOD_JPEG = F.JPEG_MAGIC + b"\x00" * 30_000 + F.JPEG_EOI      # magic + 大小 + 結尾標記三關都過
GOOD_PNG = F.PNG_MAGIC + b"\x00" * 30_000 + F.PNG_IEND
TRUNCATED_JPEG = F.JPEG_MAGIC + b"\x00" * 30_000              # 夠大、magic 對，就是沒有 FFD9
HTML_ERROR_PAGE = b"<!DOCTYPE html><html>" + b"x" * 40_000   # 429/503 的錯誤頁可以很大

FILENAME_RE = re.compile(r"^c\d+\.jpg$")


@pytest.fixture(scope="module")
def doc() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# 假網路與假時鐘——這兩個是整份測試唯一「連線」的地方，它們不連線
# ---------------------------------------------------------------------------

class FakeNet:
    """記下每一個被要求的網址，照 `script` 依序回應（用完之後一律回一張合法 JPEG）。

    `script` 的元素可以是 `(blob, status)` 或一個 Exception（會被 raise）。一個 socket 都不會開。
    """

    def __init__(self, script=None, blob: bytes = GOOD_JPEG) -> None:
        self.urls: list[str] = []
        self.blob = blob
        self.script = list(script or [])

    def __call__(self, url: str, timeout: float):
        self.urls.append(url)
        if self.script:
            act = self.script.pop(0)
            if isinstance(act, Exception):
                raise act
            return act
        return self.blob, 200


class ThrottlingNet:
    """**每一張都先 429、重試就過**——限流最標準的形狀，也是最危險的那一種：
    每張各自重試一次都會成功，於是「連續兩次 429」永遠不會發生，整趟會 rc=0 跑完並吃掉幾百次 429。"""

    def __init__(self, retry_after: str = "600") -> None:
        self.urls: list[str] = []
        self.retry_after = retry_after
        self._n = 0

    def __call__(self, url: str, timeout: float):
        self.urls.append(url)
        self._n += 1
        if self._n % 2 == 1:
            raise _http_error(429, {"Retry-After": self.retry_after})
        return GOOD_JPEG, 200


class Sleeper:
    """假 sleep：只記下「被要求等幾秒」，不真的等。"""

    def __init__(self) -> None:
        self.waits: list[float] = []

    def __call__(self, seconds: float) -> None:
        self.waits.append(seconds)


def _boom(*a, **k):
    raise AssertionError("這一條路徑不准發出任何請求")


def _http_error(code: int, headers: dict | None = None) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(URL, code, "boom", headers or {}, None)


def _cand(pageid: int, model: str = "Enercon E-82", thumb: str | None = None, **kw) -> dict:
    c = {"pageid": pageid, "selected": True, "model": model,
         "title": f"File:T{pageid}.jpg", "license": "CC BY-SA 4.0",
         "page_url": f"https://commons.wikimedia.org/?curid={pageid}",
         "focal_35mm": 50.0, "width": 4000, "height": 3000,
         "url": f"https://upload.wikimedia.org/wikipedia/commons/0/0c/T{pageid}.jpg",
         "thumb_url": thumb}
    c.update(kw)
    return c


def _manifest(tmp_path: Path, cands: list[dict]) -> str:
    p = tmp_path / "m.json"
    p.write_text(json.dumps({"candidates": cands}, ensure_ascii=False), encoding="utf-8")
    return str(p)


def _args(**kw):
    import argparse
    base = dict(manifest=str(MANIFEST), dir="/nonexistent", thumb_width=1280, pace=15.0,
                limit=0, per_model=0, order="manifest", include_fetched=False,
                thumb_host="", timeout=120.0, dry_run=True)
    base.update(kw)
    return argparse.Namespace(**base)


# ---------------------------------------------------------------------------
# ① 絕不並發、絕不換身分
# ---------------------------------------------------------------------------

def test_source_contains_no_concurrency_at_all() -> None:
    """並發是把「一個有禮貌的客戶端」變成「攻擊流量」最短的一步，而且在別人的網路上沒人會發現。
    Robot policy 的地板就是並發 ≤ 1——這裡連工具都不許存在，不是「預設關掉」。"""
    for banned in ("import threading", "import asyncio", "import multiprocessing",
                   "concurrent.futures", "ThreadPool", "ProcessPool", "Executor",
                   "os.fork", "Thread("):
        assert banned not in SOURCE, f"原始碼出現並發工具：{banned}"


def test_no_flag_can_change_identity_or_widen_the_rate() -> None:
    """反向：只要有一個 `--user-agent` 或 `--workers`，下一個人被擋住時就會去轉它——
    而「把請求分散到多個 UA 以隱藏單一操作者的用量」正是 API Usage Guidelines 明文禁止的事。"""
    flags = set(re.findall(r'ap\.add_argument\("(--[a-z0-9-]+)"', SOURCE))
    assert "--pace" in flags and "--dry-run" in flags          # sanity：真的抓到旗標了
    for bad in ("--user-agent", "--ua", "--agent", "--workers", "--jobs", "--threads",
                "--parallel", "--concurrency", "--no-pace", "--force"):
        assert bad not in flags, f"不該存在的旗標：{bad}"


def test_ua_is_the_repo_string_and_carries_contact() -> None:
    """UA 政策：可辨識的 client name + 聯絡方式。拿掉聯絡資訊會被歸進未識別流量（配額差 20 倍），
    而且毀掉 WMF 唯一能找到你談出解法的管道。"""
    assert F.UA.startswith("InduSpectBladeResearch/0.1")
    assert "github.com/dofliu/InduSpect" in F.UA and "moredof@gmail.com" in F.UA
    import fetch_commons_turbines as Legacy
    assert F.UA == Legacy.UA        # 兩個腳本用同一個身分，不是兩個看起來不同的客戶端


def test_http_get_sends_exactly_that_ua(monkeypatch: pytest.MonkeyPatch) -> None:
    """UA 常數存在不等於真的送出去——這裡攔下 Request 物件逐條看 header。"""
    captured: dict = {}

    class FakeResponse:
        status = 200

        def read(self, size: int | None = None) -> bytes:
            return GOOD_JPEG[:size] if size else GOOD_JPEG

        def __enter__(self):
            return self

        def __exit__(self, *a) -> bool:
            return False

    def fake_urlopen(req, timeout=None):
        captured["headers"] = {k.lower(): v for k, v in req.header_items()}
        captured["url"] = req.full_url
        return FakeResponse()

    monkeypatch.setattr(F.urllib.request, "urlopen", fake_urlopen)
    blob, status, final_url = F.http_get(URL, 10)
    assert (blob, status) == (GOOD_JPEG, 200)
    assert final_url == URL          # 沒有重導向時就是原網址
    assert captured["url"] == URL
    assert captured["headers"]["user-agent"] == F.UA
    assert captured["headers"]["referer"] == F.REFERER
    assert captured["headers"]["accept-encoding"] == "identity"   # urllib 不會自動解壓


def test_pace_floor_and_defaults_stay_polite() -> None:
    assert F.DEFAULT_PACE_S >= 1.0                 # Robot policy 的地板
    assert F.main(["--dry-run", "--pace", "0.5"]) == 2
    assert F.MAX_CONSECUTIVE_FAILURES <= 5         # 連續失敗要停手，不是硬幹到底


def test_run_is_strictly_sequential_and_paced(tmp_path: Path) -> None:
    """並發不存在的**行為面**證據：三張照片 → 三次請求、兩次間隔，而且每次間隔都是整個 pace。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2), _cand(3)])
    net, nap = FakeNet(), Sleeper()
    rc = F.main(["--manifest", m, "--dir", str(tmp_path / "out"), "--pace", "15",
                 "--order", "manifest"], fetch=net, sleep=nap)
    assert rc == 0
    assert len(net.urls) == 3
    assert len(nap.waits) == 2                                  # 第一張不必等，之後每張都等
    assert all(13.0 < w <= 15.0 for w in nap.waits), nap.waits   # 等的是 pace，不是被砍過的殘值


# ---------------------------------------------------------------------------
# ② 429 一律全額等 Retry-After
# ---------------------------------------------------------------------------

def test_retry_after_is_not_clamped_to_300() -> None:
    """反向：既有腳本的 cap=300 會把 600 夾成 300、提早一半時間重試。這裡必須全額等。"""
    assert F.retry_after_seconds("600") == 600.0
    assert F.retry_after_seconds("32") == 32.0
    assert F.retry_after_seconds("999999") == F.BACKOFF_CAP_S      # 上限只擋荒謬值
    assert F.retry_after_seconds("garbage") == F.BACKOFF_NO_HEADER_S
    assert F.retry_after_seconds(None) == F.BACKOFF_NO_HEADER_S
    assert F.retry_after_seconds("Wed, 21 Oct 2015 07:28:00 GMT") == 1.0   # 過去的日期 → 至少 1 s
    assert F.BACKOFF_CAP_S >= 600.0        # 實測 upload.wikimedia.org 給的就是 600
    assert F.BACKOFF_NO_HEADER_S >= 5.0    # 沒有 header 時官方指示「至少 5 秒並指數退避」


def test_429_waits_exactly_what_the_server_asked(tmp_path: Path) -> None:
    """真的讀 header、真的等到該等的秒數——用注入的假 sleep 驗數字，不用真的睡 600 秒。"""
    net = FakeNet(script=[_http_error(429, {"Retry-After": "600"}), (GOOD_JPEG, 200)])
    nap = Sleeper()
    res = F.fetch_one(URL, str(tmp_path / "c1.jpg"), 10, quiet=True, fetch=net, sleep=nap)
    assert res["status"] == "ok"
    assert nap.waits == [600.0]              # 不是 300、不是 90、不是 0
    assert len(net.urls) == 2


def test_429_without_header_falls_back_to_the_documented_backoff(tmp_path: Path) -> None:
    net = FakeNet(script=[_http_error(429), (GOOD_JPEG, 200)])
    nap = Sleeper()
    F.fetch_one(URL, str(tmp_path / "c1.jpg"), 10, quiet=True, fetch=net, sleep=nap)
    assert nap.waits == [F.BACKOFF_NO_HEADER_S]


def test_429_event_is_recorded_as_evidence(tmp_path: Path) -> None:
    """429 的逐次紀錄是寄信給 bot-traffic@wikimedia.org 時唯一的實證，不能只印在畫面上。"""
    net = FakeNet(script=[_http_error(429, {"Retry-After": "600"}), (GOOD_JPEG, 200)])
    res = F.fetch_one(URL, str(tmp_path / "c1.jpg"), 10, quiet=True, fetch=net, sleep=Sleeper())
    ev = res["events"]
    assert len(ev) == 1
    assert ev[0]["http_status"] == 429
    assert ev[0]["retry_after_header"] == "600" and ev[0]["waited_s"] == 600.0
    assert ev[0]["url"] == URL and ev[0]["at"].endswith("Z")


def test_second_429_aborts_the_whole_run(tmp_path: Path) -> None:
    """CDN 的 429 是「這個客戶端現在不受歡迎」，不是「這個 URL 有問題」——整趟中止，不是跳過這一張。"""
    net = FakeNet(script=[_http_error(429, {"Retry-After": "600"})] * 2)
    nap = Sleeper()
    with pytest.raises(F.Blocked):
        F.fetch_one(URL, str(tmp_path / "c1.jpg"), 10, quiet=True, fetch=net, sleep=nap)
    assert len(net.urls) == 2        # 只重試同一張一次，不是既有腳本的 3 次
    assert nap.waits == [600.0]      # 第二次不再等、直接中止


def test_blocked_stops_the_batch_and_reports_it(tmp_path: Path) -> None:
    """反向：被擋之後還繼續跑下一張，313 張就會往一個已經說不的 CDN 打掉幾百次請求。

    **被擋當下的 429 實證必須留在 `fetch_log.json`**：`fetch_one` 丟 `Blocked` 時那兩次 429
    是這一趟唯一的證據，而唯一真正需要它的情境就是這一趟。它隨例外消失的話，
    收尾那句「寄信給 bot-traffic@wikimedia.org 時附上它」在該印的時候印不出來。
    """
    net = FakeNet(script=[_http_error(429, {"Retry-After": "600"})] * 2)
    out = tmp_path / "out"
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 6)]),
                 "--dir", str(out), "--order", "manifest"], fetch=net, sleep=Sleeper())
    assert rc == 1
    assert len(net.urls) == 2                      # 第一張就停了，後面四張碰都不碰
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert "bot-traffic@wikimedia.org" in log["aborted"]
    assert "不要再試探這個 IP" in log["aborted"]
    # 實證：兩次 429 都在，而且帶著 Retry-After 與實際等待秒數
    assert len(log["events_429"]) == 2
    assert [e["http_status"] for e in log["events_429"]] == [429, 429]
    assert all(e["retry_after_header"] == "600" and e["waited_s"] == 600.0
               for e in log["events_429"])
    # **被擋的是哪一個網址**也要留下來：寄信給 bot-traffic@wikimedia.org 時，
    # 「幾點被擋」沒有用，「被擋的是哪一條縮圖路徑」才對得上他們 CDN 上的規則。
    assert all(e["url"] == net.urls[0] for e in log["events_429"])
    assert "/thumb/" in log["events_429"][0]["url"]
    assert log["total_429"] == 2
    # 被擋的那一張也要留下紀錄，否則連「碰過它」都看不出來
    rec = log["files"]["1"]
    assert rec["status"] == "failed" and "429" in rec["reason"]
    assert rec["source_url"] == net.urls[0] and rec["http_status"] == 429


def test_survived_429_is_kept_in_the_log_across_resumes(tmp_path: Path) -> None:
    """撐過去的 429 要留在 `fetch_log.json`，而且**續傳時不得被覆蓋**——
    429 的累積次數是「這個出口 IP 快要被列入黑名單」的唯一早期訊號。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    out = tmp_path / "out"
    net = FakeNet(script=[_http_error(429, {"Retry-After": "600"}), (GOOD_JPEG, 200)])
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=net, sleep=Sleeper()) == 0
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert len(log["events_429"]) == 1 and log["events_429"][0]["waited_s"] == 600.0

    started = log["started"]
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
           fetch=FakeNet(), sleep=Sleeper())
    again = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert len(again["events_429"]) == 1 and again["started"] == started


def test_server_error_pauses_for_fifteen_minutes(tmp_path: Path) -> None:
    net = FakeNet(script=[_http_error(503)] * 2)
    nap = Sleeper()
    with pytest.raises(F.Blocked):
        F.fetch_one(URL, str(tmp_path / "c1.jpg"), 10, quiet=True, fetch=net, sleep=nap)
    assert nap.waits == [F.SERVER_ERROR_PAUSE_S] and F.SERVER_ERROR_PAUSE_S >= 900.0


def test_ordinary_http_error_skips_only_that_image(tmp_path: Path) -> None:
    """404 是那個 URL 的問題不是客戶端的問題——不等、不中止、只記這一張失敗。"""
    net = FakeNet(script=[_http_error(404)])
    nap = Sleeper()
    res = F.fetch_one(URL, str(tmp_path / "c1.jpg"), 10, quiet=True, fetch=net, sleep=nap)
    assert res["status"] == "failed" and res["http_status"] == 404
    assert nap.waits == [] and len(net.urls) == 1


def test_consecutive_failures_stop_the_run(tmp_path: Path) -> None:
    """連續失敗多半是新網路本身斷了；繼續跑只是對著 CDN 空轉。"""
    net = FakeNet(blob=HTML_ERROR_PAGE)
    out = tmp_path / "out"
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 11)]),
                 "--dir", str(out), "--order", "manifest"], fetch=net, sleep=Sleeper())
    assert rc == 1
    assert len(net.urls) == F.MAX_CONSECUTIVE_FAILURES
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert "連續" in log["aborted"]


# ---------------------------------------------------------------------------
# ③ 只送常用縮圖寬度，而且永遠不抓原圖
# ---------------------------------------------------------------------------

def test_standard_thumb_url_behaviour_is_copied_verbatim() -> None:
    """與 fetch_commons_turbines 同行為：非常用寬度 raise、**原圖網址原樣回傳**。"""
    assert F.standard_thumb_url(THUMB, 1280) == THUMB.replace("2400px", "1280px")
    assert F.standard_thumb_url(None) is None
    assert F.standard_thumb_url(ORIGINAL) == ORIGINAL          # 正是這個 no-op 讓人誤抓原圖
    with pytest.raises(ValueError):
        F.standard_thumb_url(THUMB, 2400)


def test_every_standard_width_is_a_common_thumbnail_size() -> None:
    """常用寬度表就是 mediawiki.org/wiki/Common_thumbnail_sizes 那一張；非常用寬度每張都要現算。"""
    assert F.DEFAULT_THUMB_WIDTH in F.STANDARD_THUMB_WIDTHS
    assert F.DEFAULT_THUMB_WIDTH >= F.MIN_THUMB_WIDTH >= 1024   # 只縮不放，長邊要 ≥ App 的 1024
    # 1280 只是管線跑得動的下限，不是可以拿來抓語料的寬度：RESOLUTION_SENSITIVITY.md 實測
    # 9 張已放行的照片縮到寬 1280，4 張側視有 3 張被改判成正視並拒收。預設不准掉回 1280。
    assert F.DEFAULT_THUMB_WIDTH >= 1920
    for w in (2400, 1000, 1281, 0, -1):
        assert w not in F.STANDARD_THUMB_WIDTHS
        with pytest.raises(ValueError):
            F.standard_thumb_url(THUMB, w)
        with pytest.raises(ValueError):
            F.derive_thumb_url(ORIGINAL, w)


def test_derive_thumb_url_turns_an_original_into_a_thumb() -> None:
    """反向：原圖網址進去，出來的**不可以**還是原圖（原圖是多 MB，而且同樣在 429 名單上）。"""
    got = F.derive_thumb_url(ORIGINAL, 1280)
    assert got != ORIGINAL
    assert got == "https://thumb.wikimedia.org/wikipedia/commons/thumb/0/0c/X.jpg/1280px-X.jpg"
    assert F.derive_thumb_url(None) is None
    assert F.derive_thumb_url("https://example.com/not/commons.jpg") is None


def test_derive_thumb_url_matches_api_ground_truth(doc: dict) -> None:
    """用 API 自己給的縮圖網址當真值，逐條驗自行推導的規則——這是離線驗證推導正確性的唯一方法。"""
    truth_set = [c for c in doc["candidates"]
                 if c.get("selected") and re.search(r"/(\d+)px-", c.get("thumb_url") or "")]
    assert len(truth_set) >= 200
    for c in truth_set:
        assert F.derive_thumb_url(c["url"], 1280, "thumb.wikimedia.org") == \
            F.standard_thumb_url(F._strip_query(c["thumb_url"]), 1280)


def test_every_selected_candidate_resolves_to_a_thumb(doc: dict) -> None:
    hows = [F.thumb_url_for(c, 1280) for c in doc["candidates"] if c.get("selected")]
    assert all(url for url, _ in hows)
    assert sum(1 for _, how in hows if how == "derived") > 0          # 原圖網址那一批確實存在
    assert all("/thumb/" in url and "1280px-" in url for url, _ in hows)


def test_main_refuses_small_or_uncommon_width() -> None:
    """反向：800 px 會讓分析跑在比 App 更小的尺度上；2400 px 非常用寬度每張現算縮圖必被 429。"""
    assert F.main(["--dry-run", "--thumb-width", "800"]) == 2
    assert F.main(["--dry-run", "--thumb-width", "1024"]) == 2     # 常用寬度但低於 MIN_THUMB_WIDTH
    assert F.main(["--dry-run", "--thumb-width", "2400"]) == 2


def test_a_real_run_only_ever_asks_for_a_common_width(tmp_path: Path) -> None:
    """端到端：manifest 裡混著非常用寬度的縮圖網址與原圖網址，送出去的**每一個**都要是常用寬度的縮圖。"""
    m = _manifest(tmp_path, [
        _cand(1, thumb="https://thumb.wikimedia.org/wikipedia/commons/thumb/0/0c/T1.jpg/2400px-T1.jpg"),
        _cand(2, model="Enercon E-126", thumb=None),        # thumb_url 是原圖 → 自行推導
        _cand(3, thumb="https://thumb.wikimedia.org/wikipedia/commons/thumb/0/0c/T3.jpg/330px-T3.jpg?x=1"),
    ])
    net = FakeNet()
    rc = F.main(["--manifest", m, "--dir", str(tmp_path / "out"), "--thumb-width", "1280",
                 "--order", "manifest"], fetch=net, sleep=Sleeper())
    assert rc == 0 and len(net.urls) == 3
    for u in net.urls:
        assert "/thumb/" in u, u                       # 永遠不抓原圖
        assert "?" not in u                            # 追蹤參數要被剝掉
        width = int(re.search(r"/(\d+)px-", u).group(1))
        assert width == 1280 and width in F.STANDARD_THUMB_WIDTHS, u


# ---------------------------------------------------------------------------
# ④ 續傳只跳過真的抓完的檔
# ---------------------------------------------------------------------------

def test_existing_file_ok_needs_magic_bytes_and_size(tmp_path: Path) -> None:
    """反向：只看 `getsize > 20_000` 會把 30 KB 的 429 HTML 頁當成抓到了，下次重跑還會跳過它。"""
    cases = {
        "html.jpg": (HTML_ERROR_PAGE, False),                      # 夠大但不是影像
        "empty.jpg": (b"", False),                                 # 0 byte
        "truncated.jpg": (F.JPEG_MAGIC + b"\x00" * 100, False),    # 是 JPEG 但沒抓完
        "cut_at_the_end.jpg": (TRUNCATED_JPEG, False),             # 夠大、magic 對，就是沒有 FFD9
        "good.jpg": (GOOD_JPEG, True),
        "png.jpg": (GOOD_PNG, True),
    }
    for name, (blob, expected) in cases.items():
        (tmp_path / name).write_bytes(blob)
        assert F.existing_file_ok(str(tmp_path / name)) is expected, name
    assert F.existing_file_ok(str(tmp_path / "missing.jpg")) is False
    assert F.existing_file_ok(str(tmp_path)) is False              # 目錄不是檔案


def test_resume_skips_complete_files_but_refetches_broken_ones(tmp_path: Path) -> None:
    """續傳的整條路徑：完整檔跳過（連請求都不發），0 byte 與截斷檔**不算完成**、要重抓。"""
    out = tmp_path / "out"
    out.mkdir()
    (out / "c1.jpg").write_bytes(GOOD_JPEG)                      # 完整
    (out / "c2.jpg").write_bytes(b"")                            # 0 byte
    (out / "c3.jpg").write_bytes(F.JPEG_MAGIC + b"\x00" * 500)   # 截斷
    (out / "c4.jpg").write_bytes(HTML_ERROR_PAGE)                # 上一趟落地的錯誤頁

    m = _manifest(tmp_path, [_cand(i) for i in (1, 2, 3, 4)])
    net = FakeNet()
    rc = F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                fetch=net, sleep=Sleeper())
    assert rc == 0
    assert len(net.urls) == 3 and not any("T1.jpg" in u for u in net.urls)

    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    # c1 根本沒進這一趟的計畫（磁碟濾在名額之前），但開跑前的盤點仍把它記進 log——
    # sha256 是帶回去驗完整性的唯一依據，漏記就驗不到。
    assert log["files"]["1"]["status"] == "skipped_existing"
    assert log["files"]["1"]["sha256"] == F.sha256_of(str(out / "c1.jpg"))
    assert [log["files"][k]["status"] for k in ("2", "3", "4")] == ["ok"] * 3
    assert log["summary"]["ok"] == 3 and log["summary"]["skipped_existing"] == 1
    # 跳過的不准被算進「這一趟下載了多少」
    assert log["summary"]["bytes_downloaded"] == 3 * len(GOOD_JPEG)
    assert log["summary"]["bytes"] == 4 * len(GOOD_JPEG)
    for name in ("c2.jpg", "c3.jpg", "c4.jpg"):
        assert (out / name).read_bytes() == GOOD_JPEG


def test_a_second_run_asks_for_nothing(tmp_path: Path) -> None:
    """跑完再跑一次應該是零請求——否則「重跑同一行指令續傳」這句話會變成重抓一輪。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    out = tmp_path / "out"
    first = FakeNet()
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"], fetch=first, sleep=Sleeper())
    second = FakeNet(script=[AssertionError("已經抓完的不准再抓一次")])
    rc = F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                fetch=second, sleep=Sleeper())
    assert rc == 0 and len(first.urls) == 2 and second.urls == []
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["summary"]["skipped_existing"] == 2 and log["summary"]["bytes_downloaded"] == 0


def test_bad_response_never_lands_on_disk(tmp_path: Path) -> None:
    """不落地是關鍵：落地了下一趟就會把它當成已抓到而跳過，最後查不出為什麼少了幾張。"""
    path = tmp_path / "c1.jpg"
    res = F.fetch_one(URL, str(path), 10, quiet=True,
                      fetch=FakeNet(blob=HTML_ERROR_PAGE), sleep=Sleeper())
    assert res["status"] == "failed" and not path.exists()

    res = F.fetch_one(URL, str(path), 10, quiet=True,
                      fetch=FakeNet(blob=F.JPEG_MAGIC + b"\x00" * 100), sleep=Sleeper())
    assert res["status"] == "failed" and not path.exists()       # 是 JPEG 但太小
    assert not (tmp_path / "c1.jpg.part").exists()               # 半成品也不留


def test_good_jpeg_is_written_atomically_with_sha256(tmp_path: Path) -> None:
    path = tmp_path / "c1.jpg"
    res = F.fetch_one(URL, str(path), 10, quiet=True, fetch=FakeNet(), sleep=Sleeper())
    assert res["status"] == "ok" and res["bytes"] == len(GOOD_JPEG)
    assert path.read_bytes() == GOOD_JPEG
    assert res["sha256"] == F.sha256_of(str(path))
    assert not (tmp_path / "c1.jpg.part").exists()               # tmp + rename，不留 .part


def test_network_exception_is_recorded_not_raised(tmp_path: Path) -> None:
    path = tmp_path / "c1.jpg"
    res = F.fetch_one(URL, str(path), 10, quiet=True,
                      fetch=FakeNet(script=[urllib.error.URLError("dns")]), sleep=Sleeper())
    assert res["status"] == "failed" and "URLError" in res["reason"] and not path.exists()


# ---------------------------------------------------------------------------
# ⑤ --dry-run 一個請求都不准發
# ---------------------------------------------------------------------------

def test_dry_run_makes_no_request(monkeypatch: pytest.MonkeyPatch,
                                  capsys: pytest.CaptureFixture, tmp_path: Path) -> None:
    """注入一個會 raise 的假抓取器（外加把 http_get／urlopen 都換成同一個）來證明它沒被呼叫。"""
    monkeypatch.setattr(F, "http_get", _boom)
    monkeypatch.setattr(F.urllib.request, "urlopen", _boom)
    out = tmp_path / "out"
    rc = F.main(["--dry-run", "--limit", "5", "--manifest", str(MANIFEST), "--dir", str(out)],
                fetch=_boom, sleep=_boom)
    out_text = capsys.readouterr().out
    assert rc == 0
    assert not out.exists()                    # 連輸出目錄都不建
    assert "待抓 227" in out_text and f"{F.DEFAULT_THUMB_WIDTH}px-" in out_text
    assert "一個請求都不會發出" in out_text


def test_dry_run_lists_what_the_real_run_would_fetch(capsys: pytest.CaptureFixture,
                                                     tmp_path: Path) -> None:
    """--dry-run 印出來的網址要與真的會送出去的一模一樣，否則「先看再跑」沒有意義。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2, model="Enercon E-126")])
    assert F.main(["--dry-run", "--manifest", m, "--dir", str(tmp_path / "out"),
                   "--order", "manifest"], fetch=_boom, sleep=_boom) == 0
    listed = re.findall(r"https://\S+", capsys.readouterr().out)
    net = FakeNet()
    F.main(["--manifest", m, "--dir", str(tmp_path / "out"), "--order", "manifest"],
           fetch=net, sleep=Sleeper())
    assert [u for u in listed if "px-" in u] == net.urls


def test_missing_manifest_exits_without_touching_the_network(tmp_path: Path) -> None:
    assert F.main(["--manifest", str(tmp_path / "nope.json"), "--dir", str(tmp_path / "out")],
                  fetch=_boom, sleep=_boom) == 2


# ---------------------------------------------------------------------------
# ⑥ 檔名 pattern 與 pending 判斷
# ---------------------------------------------------------------------------

def test_filename_is_the_join_key(doc: dict) -> None:
    """檔名是驗證端唯一的對應鍵；manifest 裡 86 筆已下載的紀錄 100% 是這個形狀。"""
    assert F.candidate_filename({"pageid": 12345}) == "c12345.jpg"
    assert F.candidate_filename({"pageid": 7}) == "c7.jpg"          # 不補零
    done = [c for c in doc["candidates"] if c.get("file")]
    assert len(done) == 86
    assert all(c["file"] == F.candidate_filename(c) for c in done)
    assert all(FILENAME_RE.match(F.candidate_filename(c))
               for c in doc["candidates"] if c.get("selected"))


def test_filename_matches_the_validator_fallback() -> None:
    """`real_pose_validation.py` 找不到 manifest 的 `file` 欄位時就是用這個規則 fallback——
    兩邊漂開的話，抓回來的 229 張會在驗證階段靜默對不上。"""
    rpv = (ROOT / "scripts" / "real_pose_validation.py").read_text(encoding="utf-8")
    assert re.search(r"c\{c\['pageid'\]\}\.jpg", rpv), "驗證端的 fallback 命名規則變了"


def test_pending_is_selected_without_a_file(doc: dict) -> None:
    sel = [c for c in doc["candidates"] if c.get("selected")]
    pend = F.pending_candidates(doc)
    assert len(sel) == 313 and len(pend) == 227          # 313 入選、86 已抓、229−2 …
    assert all(c.get("selected") and not c.get("file") for c in pend)
    assert len(F.pending_candidates(doc, include_fetched=True)) == 313


def test_pending_is_the_manifest_view_only(doc: dict) -> None:
    """`pending_candidates` 是**純 manifest 視角**（只給 --dry-run 的報表用），刻意不碰磁碟；
    真正的待抓清單在 `build_plan`，依據是磁碟實際狀態。兩個視角都要在，
    因為 --dry-run 要同時印出「manifest 待抓 227」與「實際待抓 313」才看得出落差。"""
    assert "existing_file_ok" not in _source_of(F.pending_candidates)
    assert "existing_file_ok" in _source_of(F.build_plan)


def test_limit_is_applied_after_the_disk_filter(tmp_path: Path) -> None:
    """反向有兩個方向：①先切 limit 再濾（既有 cmd_download 的順序）會一張都不剩；
    ②只看 manifest 的 `file` 欄位濾，`file` 有值但檔案不在磁碟上的那 86 張就永遠補不回來。
    名額一定要從**磁碟上還沒有的**那些裡切。"""
    out = tmp_path / "out"
    out.mkdir()
    for i in (0, 1):
        (out / f"c{i}.jpg").write_bytes(GOOD_JPEG)          # 真的抓到了
    fetched = [{"selected": True, "pageid": i, "file": f"c{i}.jpg", "model": "M"} for i in range(5)]
    todo = [{"selected": True, "pageid": 100 + i, "model": "M"} for i in range(5)]
    (tmp_path / "m.json").write_text(json.dumps({"candidates": fetched + todo}), encoding="utf-8")
    _, plan = F.build_plan(_args(limit=3, order="manifest", dir=str(out),
                                 manifest=str(tmp_path / "m.json")))
    # 0/1 真的在磁碟上 → 跳過；2/3/4 manifest 說抓過但檔案不在 → 照抓
    assert [c["pageid"] for c in plan] == [2, 3, 4]


def test_unselected_candidates_are_never_fetched(doc: dict) -> None:
    """1897 筆候選裡只有 313 筆入選；沒入選的（授權不符／沒有焦距／沒有型錄尺寸）不准被抓。"""
    assert len(doc["candidates"]) > 1000
    ids = {c["pageid"] for c in F.pending_candidates(doc, include_fetched=True)}
    assert all(c["pageid"] not in ids for c in doc["candidates"] if not c.get("selected"))


def test_per_model_cap_counts_pending_only() -> None:
    cands = [{"pageid": i, "model": "A"} for i in range(4)] + [{"pageid": 9, "model": "B"}]
    assert [c["pageid"] for c in F.per_model_cap(cands, 2)] == [0, 1, 9]
    assert F.per_model_cap(cands, 0) == cands          # 0 = 不限


def test_interleave_keeps_model_diversity() -> None:
    cands = [{"model": "A"}] * 3 + [{"model": "B"}] * 2
    assert [c["model"] for c in F.interleave_by_model(cands)] == ["A", "B", "A", "B", "A"]


def test_interleave_is_the_default_order(doc: dict) -> None:
    """被擋停時仍保有機型多樣性——pending 高度集中在 E-82／E-126，照原順序只會拿到一兩個機型。"""
    _, plan = F.build_plan(_args(dry_run=True, order="interleave", limit=4))
    assert len({c.get("model") for c in plan}) == 4


def _source_of(fn) -> str:
    import inspect
    return inspect.getsource(fn)


# ---------------------------------------------------------------------------
# ⑦ 全域 429 預算、自適應減速、被擋當下的實證
# ---------------------------------------------------------------------------

def test_every_image_throttled_slows_down_and_aborts(tmp_path: Path,
                                                     capsys: pytest.CaptureFixture) -> None:
    """**最危險的那一條路徑**：每張都先 429、重試就過。

    只防「連續兩次 429」的話，這個形狀下每張各自重試一次都會成功、`consecutive_failures` 一直歸零、
    步調一成不變，於是整趟會 rc=0、aborted=None 跑完——40 張就是 80 次請求、40 次 429，
    放到 227 張是 454 次請求、227 次 429、累計等待約 38 小時。原本那個 IP 的懲罰
    （Retry-After 300 → 600）就是這樣被墊高的，而且會害使用者的新 IP 也被封。

    修好之後要看到三件事：收到 429 就**減速**、累計到預算就**中止整趟**、實證留在 log 裡。
    """
    net, nap = ThrottlingNet(), Sleeper()
    out = tmp_path / "out"
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 41)]),
                 "--dir", str(out), "--order", "manifest", "--pace", "15"],
                fetch=net, sleep=nap)
    err = capsys.readouterr().err

    assert rc == 1                                   # 不是 0：這一趟**失敗了**，不是抓完了
    assert len(net.urls) <= 12, len(net.urls)        # 不是 80
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["total_429"] == F.MAX_TOTAL_429
    assert len(log["events_429"]) == F.MAX_TOTAL_429
    assert log["aborted"] and "429" in log["aborted"]
    assert "bot-traffic@wikimedia.org" in log["aborted"]
    # 自適應減速：步調真的被加倍了（15 → … → 上限），而且有印出來讓使用者看得到
    assert log["pace_s"] > 15.0 and log["pace_s"] <= F.PACE_MAX_S
    assert "步調" in err
    assert nap.waits.count(600.0) == F.MAX_TOTAL_429   # 每一次 429 都全額等了 Retry-After
    # 實證要指得出**被擋的是哪一個網址**。少了 url，events_429 只剩一串時刻與秒數，
    # 寄給 bot-traffic@wikimedia.org 時對方無從查起（他們要比對的是 CDN 上那條規則命中了什麼）。
    # 這裡走的是「撐過去的 429」那條路徑（`res["events"]`），與被擋中止那條是兩段不同的程式碼。
    assert all(e["url"] in net.urls for e in log["events_429"])
    assert all("/thumb/" in e["url"] and f"{F.DEFAULT_THUMB_WIDTH}px-" in e["url"]
               for e in log["events_429"])


def test_the_slowdown_is_a_real_doubling_not_a_token_nudge(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """**「有變慢」不等於「夠慢」**：把 `a.pace * 2` 寫成 `a.pace + 1`，上一條測試照樣綠
    （`pace_s > 15` 仍成立），但 15 → 20 s 對一個已經在限流的 CDN 等於沒減速——
    313 張照樣打完、照樣把懲罰從 300 墊到 600，而付代價的是**使用者的新 IP**。
    所以把階梯釘死：每收到一次 429 步調就**加倍**，直到 `PACE_MAX_S` 封頂。

    釘兩層：①印給使用者看的那一行（old → new）；②**真的傳給 `sleep` 的秒數**——
    只印不等更糟，使用者以為變慢了、實際沒有，而且只有被封之後才會發現。
    """
    net, nap = ThrottlingNet(), Sleeper()
    out = tmp_path / "out"
    F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 41)]),
            "--dir", str(out), "--order", "manifest", "--pace", "15"], fetch=net, sleep=nap)
    err = capsys.readouterr().err

    ladder, pace = [], 15.0
    for _ in range(F.MAX_TOTAL_429):
        nxt = min(pace * 2, F.PACE_MAX_S)
        ladder.append((pace, nxt))
        pace = nxt
    printed = [(float(a), float(b)) for a, b in re.findall(r"步調 (\d+) s 改成 (\d+) s", err)]
    assert printed == ladder, printed          # 15→30→60→120→240→300（封頂），不是 15→16→17…

    # 真的等了：`sleep` 收到的非 Retry-After 秒數就是加倍後的新步調
    # （第一張沒有前一次請求可等，最後一次加倍之後直接中止，所以少頭也少尾）
    paced = [w for w in nap.waits if w != 600.0]
    assert paced == pytest.approx([b for _, b in ladder[:-1]], abs=1.0), paced
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["pace_s"] == F.PACE_MAX_S       # 收尾留下的是最後的步調，不是 --pace 給的 15


def test_pace_never_grows_past_the_cap() -> None:
    """減速是要變禮貌，不是要卡死整趟：加倍有上限。"""
    assert 15.0 < F.PACE_MAX_S <= 300.0
    assert F.MAX_TOTAL_429 <= 10          # 預算要小；429 是「已經太快了」不是「再試幾次看看」


def test_403_aborts_the_whole_run_like_429(tmp_path: Path) -> None:
    """Wikimedia 的 requestctl 規則不只回 429，也會回 403。落進一般失敗分支的話會再打 4 張才停，
    而且停下來時印的是「多半是網路本身的問題」——把人引導去檢查 wifi、然後對一個剛剛
    明確拒絕他的 CDN 再打五次。"""
    for code in F.BLOCKED_STATUS:
        net = FakeNet(script=[_http_error(code)])
        with pytest.raises(F.Blocked) as ei:
            F.fetch_one(URL, str(tmp_path / "c1.jpg"), 10, quiet=True, fetch=net, sleep=Sleeper())
        assert str(code) in str(ei.value)
        assert ei.value.http_status == code and ei.value.url == URL
        assert len(net.urls) == 1          # 不重試：它說的是「這個客戶端不受歡迎」

    out = tmp_path / "out"
    net = FakeNet(script=[_http_error(403)])
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 6)]),
                 "--dir", str(out), "--order", "manifest"], fetch=net, sleep=Sleeper())
    assert rc == 1 and len(net.urls) == 1              # 第一張就停，不是打滿 5 張
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert "CDN 直接拒絕" in log["aborted"]


def test_blocked_exception_carries_the_evidence() -> None:
    """`Blocked` 的簽名本身就是約定：訊息、events、url、http_status 四樣都要帶得走。"""
    e = F.Blocked("boom", [{"http_status": 429}], URL, 429)
    assert e.events and e.url == URL and e.http_status == 429
    assert F.Blocked("boom").events == [] and F.Blocked("boom").url is None


# ---------------------------------------------------------------------------
# ② 續傳：名額要從「磁碟上還沒有的」那些裡切
# ---------------------------------------------------------------------------

def test_two_limited_runs_fetch_different_images(tmp_path: Path) -> None:
    """反向：第二趟抓到的若是同一批，`--limit` 分批跑就永遠停在前 N 張——
    而 `--limit` 存在的理由正是「在別的網路上分批跑」。實測舊行為是 RUN2 {ok:0, skipped:5}。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 11)])
    out = tmp_path / "out"
    run1, run2 = FakeNet(), FakeNet()
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--limit", "5"],
                  fetch=run1, sleep=Sleeper()) == 0
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--limit", "5"],
                  fetch=run2, sleep=Sleeper()) == 0

    assert len(run1.urls) == 5 and len(run2.urls) == 5
    assert set(run1.urls).isdisjoint(run2.urls)                      # 不是同一批
    assert len(list(out.glob("c*.jpg"))) == 10                       # 磁碟上真的有 10 張
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["summary"]["ok"] + log["summary"]["skipped_existing"] == 10
    assert log["summary"]["bytes_this_run"] == 5 * len(GOOD_JPEG)    # 只算這一趟


def test_a_manifest_file_entry_does_not_protect_a_missing_file(tmp_path: Path) -> None:
    """manifest 有 `file` 但磁碟上沒有 → 照抓。那 86 張已隨 scratchpad 清空消失，
    照 `file` 欄位濾的話帶回來的目錄永遠只有 227 張，而重產的報告會與版控裡那份對不上。"""
    cands = [dict(_cand(i), file=f"c{i}.jpg") for i in range(1, 4)]
    net = FakeNet()
    out = tmp_path / "out"
    assert F.main(["--manifest", _manifest(tmp_path, cands), "--dir", str(out),
                   "--order", "manifest"], fetch=net, sleep=Sleeper()) == 0
    assert len(net.urls) == 3 and len(list(out.glob("c*.jpg"))) == 3


def test_skip_resets_the_consecutive_failure_counter(tmp_path: Path) -> None:
    """反向：「失敗 4 次 → 跳過一堆已有的 → 再失敗 1 次」不該算成連續 5 次——
    中間夾了確定沒問題的處理就不是「連續」。這裡用 `--include-fetched` 把已有的也排進計畫。"""
    out = tmp_path / "out"
    out.mkdir()
    for i in range(5, 11):
        (out / f"c{i}.jpg").write_bytes(GOOD_JPEG)       # 中間這 6 張會走 skip 分支
    cands = [_cand(i) for i in range(1, 5)] + [_cand(i) for i in range(5, 11)] + [_cand(11)]
    # 前 4 張與最後 1 張都拿到錯誤頁 → 失敗；中間 6 張已存在 → skip
    net = FakeNet(blob=HTML_ERROR_PAGE)
    rc = F.main(["--manifest", _manifest(tmp_path, cands), "--dir", str(out),
                 "--order", "manifest", "--include-fetched"], fetch=net, sleep=Sleeper())
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert rc == 0 and log["aborted"] is None        # 沒有被誤判成「連續 5 次」
    assert len(net.urls) == 5                        # 5 次失敗的請求，中間 6 張連請求都沒發


# ---------------------------------------------------------------------------
# 落地與紀錄：磁碟出事要記錄後繼續，不是帶著 traceback 掛掉
# ---------------------------------------------------------------------------

def test_write_failure_is_recorded_not_raised(tmp_path: Path) -> None:
    """反向：`open(tmp, "wb")` 原本在 try 之外，ENOSPC/EACCES 會穿過整支腳本，
    連 `fetch_log.json` 都來不及寫——使用者在別人的機器上跑到一半磁碟滿，
    拿到的是一堆 jpg 加一個 traceback，對不出帳。（這裡用「落地路徑是個目錄」製造 OSError。）"""
    out = tmp_path / "out"
    out.mkdir()
    (out / "c1.jpg.part").mkdir()                     # open(..., "wb") → IsADirectoryError
    net = FakeNet()
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(1)]), "--dir", str(out),
                 "--order", "manifest"], fetch=net, sleep=Sleeper())
    assert rc == 0                                    # 只有 1 張失敗，還沒到中止門檻
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["files"]["1"]["status"] == "failed"
    assert "寫檔失敗" in log["files"]["1"]["reason"]
    assert not (out / "c1.jpg").exists()


def test_log_write_failure_does_not_kill_the_images(tmp_path: Path,
                                                    capsys: pytest.CaptureFixture) -> None:
    """log 寫不出來不該毀掉已經抓到的影像——印警告，繼續抓。"""
    out = tmp_path / "out"
    out.mkdir()
    (out / F.LOG_NAME).mkdir()                        # os.replace(tmp, path) → OSError
    net = FakeNet()
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(1), _cand(2)]), "--dir", str(out),
                 "--order", "manifest"], fetch=net, sleep=Sleeper())
    err = capsys.readouterr().err
    assert rc == 0 and "警告：寫不出" in err
    assert (out / "c1.jpg").read_bytes() == GOOD_JPEG and (out / "c2.jpg").exists()


def test_part_files_are_cleaned_up_and_excluded_from_the_tarball(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """被 SIGKILL／斷電留下的 `.part` 會被收尾那行 tar 一起打包帶回去，
    讓「帶回來的目錄 = 權威快照」變模糊。開跑前清掉，而且 tar 指令本身也要排除。"""
    out = tmp_path / "out"
    out.mkdir()
    (out / "c9.jpg.part").write_bytes(b"half")
    (out / "fetch_log.json.part").write_bytes(b"{")
    F.main(["--manifest", _manifest(tmp_path, [_cand(1)]), "--dir", str(out),
            "--order", "manifest"], fetch=FakeNet(), sleep=Sleeper())
    err = capsys.readouterr().err
    assert not list(out.glob("*.part"))
    assert "清掉 2 個" in err
    assert "--exclude='*.part'" in err                # 收尾印的打包指令
    assert "--exclude='*.part'" in SOURCE             # 說明檔裡那一行也要一致


# ---------------------------------------------------------------------------
# manifest 壞掉／欄位缺漏：記錄後繼續，不是 KeyError／JSONDecodeError
# ---------------------------------------------------------------------------

def test_candidate_without_pageid_is_skipped_not_crashed(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """`pageid` 是檔名與 log 的鍵。這個腳本的前提就是「拿到別人的 checkout 上跑」，
    缺欄位要記錄後繼續——連 `--dry-run` 都會 KeyError 的話，使用者連看都看不到。"""
    broken = {"selected": True, "model": "M", "title": "File:NoPageid.jpg",
              "url": "https://upload.wikimedia.org/wikipedia/commons/0/0c/N.jpg"}
    m = _manifest(tmp_path, [broken, _cand(7)])
    out = tmp_path / "out"
    assert F.main(["--dry-run", "--manifest", m, "--dir", str(out),
                   "--order", "manifest"], fetch=_boom, sleep=_boom) == 0
    assert "略過 1 筆沒有 pageid" in capsys.readouterr().err

    net = FakeNet()
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=net, sleep=Sleeper()) == 0
    assert len(net.urls) == 1 and (out / "c7.jpg").exists()

    with pytest.raises(ValueError):                  # KeyError 的話呼叫端接不住
        F.candidate_filename({"title": "x"})


def test_broken_manifest_json_has_a_readable_message(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """反向：只接 FileNotFoundError 的話，manifest 被編輯壞／傳輸截斷時噴的是 traceback。"""
    p = tmp_path / "m.json"
    p.write_text('{"candidates": [', encoding="utf-8")
    rc = F.main(["--manifest", str(p), "--dir", str(tmp_path / "out")], fetch=_boom, sleep=_boom)
    err = capsys.readouterr().err
    assert rc == 2 and "不是合法的 JSON" in err
    assert not (tmp_path / "out").exists()


# ---------------------------------------------------------------------------
# 「絕不抓原圖」的回應端防線
# ---------------------------------------------------------------------------

def test_thumb_width_is_clamped_to_the_source_width() -> None:
    """MediaWiki 的縮圖處理器不放大：要求的寬度 ≥ 原圖寬度時不是 404 就是**導回原圖**。
    selected 裡有 4 張寬度 < 1920，而說明檔明寫「1920 也可以」——照著做就會踩到。"""
    assert F.clamp_thumb_width(1920, 1726) == 1600
    assert F.clamp_thumb_width(2560, 1704) == 1600
    assert F.clamp_thumb_width(1920, 1279) == F.MIN_THUMB_WIDTH   # 下限不讓步（只縮不放）
    assert F.clamp_thumb_width(1280, 4000) == 1280                # 夠寬就不動
    assert F.clamp_thumb_width(1920, None) == 1920                # 不知道原圖寬度就不猜

    url, _ = F.thumb_url_for(_cand(1, width=1726, height=2600), 1920)
    assert F.thumb_width_of(url) == 1600


def test_no_selected_candidate_is_asked_for_more_than_its_own_width(doc: dict) -> None:
    """全 313 張逐張驗：送出去的寬度一律 ≤ 原圖寬度（否則拿到的是多 MB 的原圖）。"""
    narrow = 0
    for c in doc["candidates"]:
        if not c.get("selected"):
            continue
        url, _ = F.thumb_url_for(c, 1920)
        w = F.thumb_width_of(url)
        assert 0 < w <= (c.get("width") or w), (c["pageid"], w, c.get("width"))
        narrow += w < 1920
    assert narrow == 4          # 實測就是這 4 張（1704／1704／1726／1872）


def test_a_redirect_away_from_thumb_is_refused(tmp_path: Path) -> None:
    """組 URL 時檢查不夠——真的被導回原圖時要在落地之前擋下來，而且不能靜默記成 ok。"""
    def redirected(url: str, timeout: float):
        return GOOD_JPEG, 200, ORIGINAL

    path = tmp_path / "c1.jpg"
    res = F.fetch_one(URL, str(path), 10, quiet=True, fetch=redirected, sleep=Sleeper())
    assert res["status"] == "failed" and "原圖" in res["reason"]
    assert not path.exists()


def test_an_oversized_response_is_refused(tmp_path: Path) -> None:
    """1280 px 的縮圖不可能到 8 MB；會超過的只有「被導回原圖」這一種情況。"""
    huge = F.JPEG_MAGIC + b"\x00" * (F.MAX_RESPONSE_BYTES + 10) + F.JPEG_EOI
    path = tmp_path / "c1.jpg"
    res = F.fetch_one(URL, str(path), 10, quiet=True, fetch=FakeNet(blob=huge), sleep=Sleeper())
    assert res["status"] == "failed" and "上限" in res["reason"]
    assert not path.exists()


def test_a_truncated_download_never_lands(tmp_path: Path) -> None:
    """落地的檔案要與 `existing_file_ok` 同一套標準，否則截斷檔會被寫進去、
    下一趟又判定「沒抓完」而重抓，永遠收斂不了。"""
    path = tmp_path / "c1.jpg"
    res = F.fetch_one(URL, str(path), 10, quiet=True,
                      fetch=FakeNet(blob=TRUNCATED_JPEG), sleep=Sleeper())
    assert res["status"] == "failed" and "結尾標記" in res["reason"]
    assert not path.exists() and not (tmp_path / "c1.jpg.part").exists()


def test_thumb_host_help_tells_the_truth() -> None:
    """舊的 help 說反了（「預設沿用 manifest」，實際上預設一律改寫成 thumb.wikimedia.org），
    而它同時是**唯一的逃生口**卻沒被寫進文件。"""
    assert "預設沿用 manifest" not in SOURCE
    assert "--thumb-host upload.wikimedia.org 重試" in SOURCE
    assert SOURCE.count("--thumb-host upload.wikimedia.org") >= 2   # help + 說明檔各一


# ---------------------------------------------------------------------------
# --verify：不碰網路的完整性驗證
# ---------------------------------------------------------------------------

def test_verify_recomputes_sha256_and_touches_no_network(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """文件承諾「帶回去用 sha256 驗完整性」，在此之前沒有任何模式做這件事。
    跨網路 tar／scp 會截斷檔案，而截斷的 JPEG 前幾個 byte 與完整檔一模一樣。"""
    out = tmp_path / "out"
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=FakeNet(), sleep=Sleeper()) == 0
    capsys.readouterr()

    assert F.main(["--dir", str(out), "--verify"], fetch=_boom, sleep=_boom) == 0
    assert "通過 2" in capsys.readouterr().out

    (out / "c2.jpg").write_bytes(GOOD_JPEG[:-500])          # 模擬傳輸截斷
    rc = F.main(["--dir", str(out), "--verify"], fetch=_boom, sleep=_boom)
    text = capsys.readouterr().out
    assert rc == 1 and "c2.jpg" in text and "sha256 不符" in text

    (out / "c2.jpg").unlink()
    rc = F.main(["--dir", str(out), "--verify"], fetch=_boom, sleep=_boom)
    assert rc == 1 and "log 記了但磁碟上沒有" in capsys.readouterr().out


def test_verify_without_a_log_says_so(tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    assert F.main(["--dir", str(tmp_path), "--verify"], fetch=_boom, sleep=_boom) == 2
    assert "找不到" in capsys.readouterr().err


# ---------------------------------------------------------------------------
# 收尾統計
# ---------------------------------------------------------------------------

def test_summary_separates_this_run_from_the_directory(tmp_path: Path) -> None:
    """反向：`bytes_downloaded` 把 log 裡**所有** status=ok 加總，續傳時必然灌水
    （「這一趟下載 X」會把上一趟的算進來）。這一趟真的下載了多少只有 `bytes_this_run` 說得準。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 5)])
    out = tmp_path / "out"
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--limit", "2"],
           fetch=FakeNet(), sleep=Sleeper())
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--limit", "2"],
           fetch=FakeNet(), sleep=Sleeper())
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    s = log["summary"]
    assert s["bytes_this_run"] == 2 * len(GOOD_JPEG)         # 這一趟只抓了 2 張
    assert s["bytes"] == 4 * len(GOOD_JPEG)                  # 目錄裡有 4 張
    assert "attempted_ok" not in SOURCE                      # 死變數刪掉了


# ---------------------------------------------------------------------------
# ⑧ 429 預算要**跨趟**、減速要能**回復**、名額不准被永久失敗的圖佔住
#
# 這一節守的是第二輪審查的六項。共同的主題只有一個：**不要害使用者的新 IP 也被封**。
# 單趟的煞車做對了不代表有煞車——使用者拿到的 UX 是「中斷後重跑同一行就是續傳」，
# 而畫面停在「抓到 5/313」時，把它包進 `while ! cmd; do sleep 60; done` 是長下載最自然的寫法。
# ---------------------------------------------------------------------------

class SometimesThrottlingNet:
    """指定的那幾張**第一次 429、重試就過**，其餘一律成功。

    這是「暫時性限流」的形狀（不是每張都 429），低於中止門檻，所以整趟會跑完——
    正因為跑得完，只加倍不衰減的步調才會在使用者看不見的地方把 78 分鐘變成 20 小時。
    """

    def __init__(self, throttle_pageids, retry_after: str = "600") -> None:
        self.urls: list[str] = []
        self.throttle = set(throttle_pageids)
        self.retry_after = retry_after
        self._seen: dict[str, int] = {}

    def __call__(self, url: str, timeout: float):
        self.urls.append(url)
        n = self._seen.get(url, 0)
        self._seen[url] = n + 1
        pid = int(re.search(r"T(\d+)\.jpg", url).group(1))
        if pid in self.throttle and n == 0:
            raise _http_error(429, {"Retry-After": self.retry_after})
        return GOOD_JPEG, 200


class AlwaysNotFoundNet:
    """指定的那幾張永遠 404（縮圖路徑是推導出來的，從沒對 Wikimedia 驗證過，所以這不是假想）。"""

    def __init__(self, missing_pageids) -> None:
        self.urls: list[str] = []
        self.missing = set(missing_pageids)

    def __call__(self, url: str, timeout: float):
        self.urls.append(url)
        pid = int(re.search(r"T(\d+)\.jpg", url).group(1))
        if pid in self.missing:
            raise _http_error(404)
        return GOOD_JPEG, 200


def _pageids(urls) -> list[int]:
    return [int(re.search(r"T(\d+)\.jpg", u).group(1)) for u in urls]


def _seed_log(out: Path, **fields) -> None:
    out.mkdir(parents=True, exist_ok=True)
    base = {"tool": "commons_portable_fetch.py", "files": {}, "events_429": []}
    base.update(fields)
    (out / F.LOG_NAME).write_text(json.dumps(base, ensure_ascii=False), encoding="utf-8")


# --- high：全域 429 預算不跨趟 -------------------------------------------------

def test_a_throttled_abort_refuses_the_next_run_in_the_same_directory(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """**第二輪最重要的那一項**：RUN1 吃滿 5 次 429 中止、印「換一個網路」，
    RUN2 用**完全相同的那一行指令**跑又從 0 起算、又吃 5 次 429，全程沒有任何提醒——
    那正是把懲罰從 300 墊到 600 的「反覆試探」形狀，而 header 自己教使用者「重跑同一行就是續傳」。

    修好之後 RUN2 要**拒跑**（rc=2）而且**一個請求都不准發**。
    """
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 41)])
    out = tmp_path / "out"

    run1 = ThrottlingNet()
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--pace", "15"],
                  fetch=run1, sleep=Sleeper()) == 1
    assert len(run1.urls) > 0
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["aborted_kind"] == "throttled"

    capsys.readouterr()
    run2 = ThrottlingNet()
    rc = F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--pace", "15"],
                fetch=run2, sleep=Sleeper())
    err = capsys.readouterr().err
    assert rc == 2                       # 不是 0、也不是 1：這一趟**不准開始**
    assert len(run2.urls) == 0           # 一個請求都沒發（RUN2 舊行為是 10 個）
    assert "拒跑" in err and "--new-network" in err
    assert "bot-traffic@wikimedia.org" in err


def test_new_network_is_the_only_way_to_resume_after_a_throttled_abort(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """`--new-network` 是唯一的解除方式，而且它**只標記不刪除**——events_429 是要寄給
    bot-traffic@wikimedia.org 的實證，刪掉等於把證據銷毀。標記過的不併進這一趟的預算。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 41)])
    out = tmp_path / "out"
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=ThrottlingNet(), sleep=Sleeper()) == 1
    before = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))["events_429"]
    assert len(before) == F.MAX_TOTAL_429
    assert all("network_generation" not in e for e in before)

    capsys.readouterr()
    net = FakeNet()                      # 新網路上一切正常
    rc = F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--new-network"],
                fetch=net, sleep=Sleeper())
    err = capsys.readouterr().err
    # RUN1 在中止之前已經成功落地 5 張（每張 429 一次、重試就過），所以續傳的是剩下的 35 張
    assert rc == 0 and len(net.urls) == 35
    assert len(list(out.glob("c*.jpg"))) == 40
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    old = [e for e in log["events_429"] if e.get("network_generation") == "previous"]
    assert len(old) == F.MAX_TOTAL_429            # 實證還在，只是標成上一個網路的
    assert F.recent_429_count(log["events_429"]) == 0
    assert "標記成上一個網路的" in err


def test_the_429_budget_starts_from_the_last_24_hours_not_from_zero(tmp_path: Path) -> None:
    """預算的起算值＝最近 24 小時內的 events_429 筆數。反向：從 0 起算的話，
    一個「跑 4 次 429 → Ctrl-C → 重跑」的循環可以無限次把 429 打在同一個 IP 上。"""
    now = datetime.now(timezone.utc)
    fresh = F.utcnow()
    stale = (now - timedelta(hours=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert F.recent_429_count([{"at": fresh}] * 3) == 3
    assert F.recent_429_count([{"at": stale}] * 3) == 0          # 24 小時前的不算
    assert F.recent_429_count([{"at": fresh}, {"at": stale}]) == 1
    assert F.recent_429_count([{"at": fresh, "network_generation": "previous"}]) == 0
    assert F.recent_429_count([{"at": "壞掉的字串"}]) == 1        # 讀不出時刻 → 保守算進來

    # 整合：上一趟 Ctrl-C（aborted_kind 不是 throttled，所以不拒跑），但已經吃了 4 次 429
    out = tmp_path / "out"
    _seed_log(out, aborted="使用者中斷（Ctrl-C）", aborted_kind="interrupt",
              events_429=[{"at": fresh, "http_status": 429}] * 4)
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 11)])
    net = ThrottlingNet()
    rc = F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                fetch=net, sleep=Sleeper())
    assert rc == 1                                    # 預算只剩 1 → 第一張就用完、立刻中止
    assert len(net.urls) == 2                         # 429 + 重試，不是打滿 10 張
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["total_429"] == 5 and log["run_429"] == 1
    assert log["aborted_kind"] == "throttled"


def test_an_exhausted_budget_refuses_to_start_at_all(tmp_path: Path,
                                                     capsys: pytest.CaptureFixture) -> None:
    """預算已經吃完（但上一趟不是被限流中止，例如當機）時，下一趟連開始都不該開始。"""
    out = tmp_path / "out"
    _seed_log(out, events_429=[{"at": F.utcnow(), "http_status": 429}] * F.MAX_TOTAL_429)
    net = FakeNet()
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(1)]), "--dir", str(out),
                 "--order", "manifest"], fetch=net, sleep=Sleeper())
    assert rc == 2 and len(net.urls) == 0
    assert "--new-network" in capsys.readouterr().err


def test_classify_abort_does_not_confuse_a_dead_wifi_with_a_block() -> None:
    """跨趟煞車**不可以拿中止訊息的字面去比對**：「連續 N 張失敗（網路中斷，或 CDN 改用
    403/404 擋人）」裡也有 CDN 兩個字，字面比對會把單純的斷網誤判成被擋、而斷網重跑是對的。"""
    assert F.classify_abort("這一趟累計 5 次 429（上限 5）") == "throttled"
    assert F.classify_abort("連續兩次 429——這個出口 IP 已被 Wikimedia 的圖片 CDN 擋住。") == "throttled"
    assert F.classify_abort("HTTP 403——CDN 直接拒絕（IP／UA 層的規則）") == "blocked"
    assert F.classify_abort("連續 5 張失敗（網路中斷，或 CDN 改用 403/404 擋人）") == "failures"
    assert F.classify_abort("使用者中斷（Ctrl-C）") == "interrupt"
    assert F.classify_abort("磁碟錯誤：OSError: No space left on device") == "disk"
    assert F.classify_abort(None) is None


def test_a_plain_network_failure_still_resumes(tmp_path: Path) -> None:
    """反向的另一半：跨趟煞車**只**擋被限流／被擋的那兩類。斷網、磁碟滿、Ctrl-C 重跑是對的，
    擋掉的話使用者就沒有任何方式把剩下的抓完。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 11)])
    out = tmp_path / "out"
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=FakeNet(blob=HTML_ERROR_PAGE), sleep=Sleeper()) == 1
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["aborted_kind"] == "failures"
    net = FakeNet()
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=net, sleep=Sleeper()) == 0          # 照樣續傳
    assert len(net.urls) == 10


def test_dry_run_warns_about_a_throttled_abort_without_asking_for_anything(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """`--dry-run` 不發請求所以不必擋，但要**先講**：使用者多半會先 dry-run 看還差多少。"""
    out = tmp_path / "out"
    _seed_log(out, aborted="這一趟累計 5 次 429（上限 5）", aborted_kind="throttled",
              events_429=[{"at": F.utcnow(), "http_status": 429}] * 5)
    rc = F.main(["--dry-run", "--manifest", _manifest(tmp_path, [_cand(1)]),
                 "--dir", str(out), "--order", "manifest"], fetch=_boom, sleep=_boom)
    outp = capsys.readouterr().out
    assert rc == 0
    assert "--new-network" in outp and "5 次 429" in outp


# --- medium：自適應減速要能回復 ------------------------------------------------

def test_the_slowdown_recovers_after_a_run_of_clean_images(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """**只加倍、永不衰減**的話，「沒有多到中止、但不只一次」的暫時性 429 會把 78 分鐘的活
    變成 20 小時：實測 4 次分散的 429（剛好低於門檻 5）之後步調卡在 240 s 直到最後一張。
    使用者在別人的筆電上看不到總進度，最可能的結局是以為當掉了而 Ctrl-C。

    修好之後：連續 N 張乾淨就把步調減半回 `--pace` 的原值，而且每次步調變動都重印剩餘 ETA。
    """
    cands = [_cand(i) for i in range(1, 55)]          # 1–4 會 429，5–54 共 50 張乾淨
    out = tmp_path / "out"
    net = SometimesThrottlingNet({1, 2, 3, 4})
    nap = Sleeper()
    rc = F.main(["--manifest", _manifest(tmp_path, cands), "--dir", str(out),
                 "--order", "manifest", "--pace", "15"], fetch=net, sleep=nap)
    err = capsys.readouterr().err

    assert rc == 0                                     # 4 < 5，這一趟跑得完
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["total_429"] == 4 and log["summary"]["ok"] == 54
    assert log["pace_s"] == 15.0, log["pace_s"]        # 舊行為卡在 240.0
    # 階梯：15→30→60→120→240（四次 429），再 10 張乾淨減半一次 → 120→60→30→15
    assert re.findall(r"步調 (\d+) s 改成 (\d+) s", err) == \
        [("15", "30"), ("30", "60"), ("60", "120"), ("120", "240")]
    assert re.findall(r"步調 (\d+) s 減半回 (\d+) s", err) == \
        [("240", "120"), ("120", "60"), ("60", "30"), ("30", "15")]
    # 每次步調變動都要重印剩餘 ETA——否則使用者無從判斷該等還是該重跑
    assert err.count("剩 ") == 8
    assert "約" in err and "分鐘" in err
    # **真的變快了**：只印不等更糟——使用者以為變慢／變快了、實際沒有，而且只有被封之後才會發現。
    # （假 sleep 收到的是「步調減掉上一次請求以來已經過的時間」，所以是 29.99… 不是整數。）
    paced = [w for w in nap.waits if w != 600.0]
    assert max(paced) == pytest.approx(240.0, abs=1.0)        # 減速真的到過 240
    assert paced[-1] == pytest.approx(15.0, abs=1.0)          # 最後已經回到原步調
    assert sum(1 for w in paced if w < 16.0) >= 9             # 回復之後真的用 15 s 在跑


def test_recovery_never_goes_below_the_pace_the_user_asked_for(tmp_path: Path) -> None:
    """回復的下限是使用者給的 `--pace`，不是 0：減速是要變禮貌，回復不該變成加速。"""
    cands = [_cand(i) for i in range(1, 40)]
    out = tmp_path / "out"
    nap = Sleeper()
    F.main(["--manifest", _manifest(tmp_path, cands), "--dir", str(out),
            "--order", "manifest", "--pace", "20"],
           fetch=SometimesThrottlingNet({1}), sleep=nap)
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["pace_s"] == 20.0                       # 回到 20，不是 10
    assert all(w >= 19.0 for w in nap.waits), nap.waits     # 沒有任何一次比使用者要求的還快


# --- medium：--pace 的地板是腳本自己推導的 7.2 s ------------------------------

def test_pace_below_the_derived_floor_is_refused(tmp_path: Path,
                                                 capsys: pytest.CaptureFixture) -> None:
    """常數註解白紙黑字寫著「未認證每 IP 每小時 500 次的公布上限換算是 7.2 s／次」，
    而舊的檢查只拒絕 < 1.0——`--pace 1` 是 3600 次/小時，是腳本自己引用的上限的 7.2 倍。
    情境很具體：使用者看到「78 分鐘」覺得太久就把它調到 2 或 3。全域 429 預算會在 5 次之後
    停手沒錯，但那 5 次已經打在**他的**出口 IP 上了，而那種懲罰不會隨時間衰減。"""
    assert F.SAFE_PACE_FLOOR_S == pytest.approx(7.2)
    assert F.DEFAULT_PACE_S >= 2 * F.SAFE_PACE_FLOOR_S          # 預設留了一半餘裕
    for bad in ("1", "3", "7.1"):
        net = FakeNet()
        rc = F.main(["--manifest", _manifest(tmp_path, [_cand(1)]),
                     "--dir", str(tmp_path / "out"), "--pace", bad], fetch=net, sleep=_boom)
        assert rc == 2 and len(net.urls) == 0, bad
    err = capsys.readouterr().err
    assert "每 IP 每小時 500 次" in err and "bot-traffic@wikimedia.org" in err
    assert "7.2" in err
    # 地板之上照跑（不是把所有非預設值都擋掉）
    net = FakeNet()
    assert F.main(["--manifest", _manifest(tmp_path, [_cand(1)]), "--dir", str(tmp_path / "ok"),
                   "--order", "manifest", "--pace", "7.2"], fetch=net, sleep=Sleeper()) == 0
    assert len(net.urls) == 1


def test_the_floor_is_the_number_the_source_itself_derives() -> None:
    """地板不是憑感覺挑的：3600 s ÷ 500 次 = 7.2 s。推導與常數放在一起，改一個要改兩個。"""
    assert F.SAFE_PACE_FLOOR_S == pytest.approx(3600.0 / 500.0)
    assert "500" in SOURCE and "7.2" in SOURCE


# --- low：永久失敗的圖不要佔住 --limit 名額 -----------------------------------

def test_repeatedly_failing_images_stop_hogging_the_limit(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """`--limit` 的名額會被**永久失敗**的圖整碗佔住，續傳原地空轉——只是換了一種空轉。
    磁碟濾只拿掉「已經成功落地」的，拿不掉「每次都失敗」的，而 `interleave_by_model`
    是決定性的，所以那幾張永遠排在名額最前面。實測舊行為：3 張固定 404 + `--limit 3`
    連跑三趟，各發 3 個請求、磁碟上始終 0 張，而收尾只印「失敗的可以直接重跑同一行指令續傳」。

    修法是**排到尾端而不是刪掉**（「上一趟失敗」≠「永遠失敗」），所以前兩趟仍然重試，
    第三趟名額才落到真的抓得到的那些上。
    """
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 21)])
    out = tmp_path / "out"
    runs = []
    for _ in range(3):
        net = AlwaysNotFoundNet({1, 2, 3})
        assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--limit", "3"],
                      fetch=net, sleep=Sleeper()) == 0
        runs.append(_pageids(net.urls))
    err = capsys.readouterr().err

    assert runs[0] == [1, 2, 3]            # 第一趟：沒有歷史，照原順序
    assert runs[1] == [1, 2, 3]            # 第二趟：streak 還只有 1，給最後一次機會
    assert runs[2] == [4, 5, 6]            # 第三趟：streak 到 2 → 排到尾端，名額給抓得到的
    assert sorted(p.name for p in out.glob("c*.jpg")) == ["c4.jpg", "c5.jpg", "c6.jpg"]
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["files"]["1"]["fail_streak"] == 2
    assert log["files"]["4"]["fail_streak"] == 0
    assert "排到清單尾端" in err and "已連續失敗" in err


def test_a_success_clears_the_fail_streak(tmp_path: Path) -> None:
    """反向：只加不減的話，一次暫時的失敗（新網路 DNS 還沒通）會讓那張永遠排在最後。"""
    m = _manifest(tmp_path, [_cand(1)])
    out = tmp_path / "out"
    for _ in range(2):
        F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
               fetch=AlwaysNotFoundNet({1}), sleep=Sleeper())
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["files"]["1"]["fail_streak"] == 2
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
           fetch=FakeNet(), sleep=Sleeper())
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["files"]["1"]["fail_streak"] == 0 and log["files"]["1"]["status"] == "ok"


def test_demotion_keeps_the_order_otherwise_untouched() -> None:
    """純函式：降級只把 streak 夠高的搬到尾端，其餘順序（機型輪流取的結果）不動。"""
    plan = [_cand(i) for i in (1, 2, 3, 4, 5)]
    log = {"files": {"2": {"fail_streak": 3}, "4": {"fail_streak": 2}, "5": {"fail_streak": 1}}}
    got, n = F.demote_repeat_failures(plan, log)
    assert [c["pageid"] for c in got] == [1, 3, 5, 2, 4] and n == 2
    assert F.demote_repeat_failures(plan, {})[1] == 0


# --- low：結尾標記從尾端 4 KB 往前找 ------------------------------------------

PADDED_JPEG = F.JPEG_MAGIC + b"\x00" * 30_000 + F.JPEG_EOI + b"\x00" * 200
PADDED_PNG = F.PNG_MAGIC + b"\x00" * 30_000 + F.PNG_IEND + b"\x00" * 200


def test_a_legal_jpeg_with_trailing_padding_is_not_called_truncated(tmp_path: Path) -> None:
    """只在最後 32 bytes 裡找結尾標記，尾端填充超過 32 bytes 的**合法** JPEG 會被永久判成截斷，
    而且形成閉環：判截斷 → 不落地 → 下一趟磁碟上沒有 → 再抓一次，每趟白打一個請求，
    錯誤訊息還指向一個不存在的原因。"""
    assert F.TAIL_PROBE_BYTES >= 4096
    assert F.image_bytes_complete(PADDED_JPEG)
    assert F.image_bytes_complete(PADDED_PNG)
    assert not F.image_bytes_complete(TRUNCATED_JPEG)          # 真的截斷還是要擋
    assert not F.image_bytes_complete(HTML_ERROR_PAGE)

    p = tmp_path / "c1.jpg"
    p.write_bytes(PADDED_JPEG)
    assert F.existing_file_ok(str(p))                          # 續傳判斷兩邊要一致


def test_padded_image_lands_once_and_is_not_refetched(tmp_path: Path) -> None:
    """閉環的行為面證據：舊行為是兩趟都 rc=0、磁碟 0 張、同一張被抓了 2 次。"""
    m = _manifest(tmp_path, [_cand(1)])
    out = tmp_path / "out"
    run1 = FakeNet(blob=PADDED_JPEG)
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=run1, sleep=Sleeper()) == 0
    assert (out / "c1.jpg").read_bytes() == PADDED_JPEG
    run2 = FakeNet(blob=PADDED_JPEG)
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=run2, sleep=Sleeper()) == 0
    assert len(run1.urls) == 1 and len(run2.urls) == 0         # 第二趟不再白打一個請求


def test_the_truncation_reason_says_what_was_actually_checked(tmp_path: Path) -> None:
    """超過 4 KB 的尾端填充仍然會被擋（那不是正常縮圖），但**理由要說對**——
    「截斷」指向一個不存在的原因，使用者查不出來。"""
    blob = F.JPEG_MAGIC + b"\x00" * 30_000 + F.JPEG_EOI + b"\x00" * 5000
    assert not F.image_bytes_complete(blob)
    res = F.fetch_one(URL, str(tmp_path / "c1.jpg"), 10, quiet=True,
                      fetch=FakeNet(blob=blob), sleep=Sleeper())
    assert res["status"] == "failed"
    assert "找不到結尾標記" in res["reason"] and "4 KB" in res["reason"]
    assert not (tmp_path / "c1.jpg").exists()


# --- low：中止那一趟的收尾要對得上帳 -------------------------------------------

def test_a_blocked_image_counts_as_a_failure_in_the_run_summary(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """被 `Blocked` 擋掉的那一張原本沒有計入 `run_failed`，於是全 429 的一趟印的是
    「成功 0 張／失敗 0 張／下載 0.0 B」——讀起來像「什麼都沒發生」，
    而實際上發了 2 個請求、吃了 2 次 429。"""
    net = FakeNet(script=[_http_error(429, {"Retry-After": "600"})] * 2)
    out = tmp_path / "out"
    assert F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 6)]),
                   "--dir", str(out), "--order", "manifest"], fetch=net, sleep=Sleeper()) == 1
    err = capsys.readouterr().err
    assert "成功 0 張／失敗 1 張" in err
    assert len(net.urls) == 2


def test_an_aborted_incomplete_run_does_not_print_the_tarball_line(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """抓到 5/313 就被擋停的那一趟照樣印「下一步——把整個目錄打包帶回去」與 tar 指令，
    暗示可以收工了。中止且沒抓完時要改印「不要現在打包」，而且要說清楚怎麼續傳。"""
    out = tmp_path / "out"
    assert F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 41)]),
                   "--dir", str(out), "--order", "manifest"],
                  fetch=ThrottlingNet(), sleep=Sleeper()) == 1
    err = capsys.readouterr().err
    assert "tar czf" not in err
    assert "不要現在打包" in err and "--new-network" in err

    # 對照組：跑完了就照印
    out2 = tmp_path / "out2"
    F.main(["--manifest", _manifest(tmp_path, [_cand(1)]), "--dir", str(out2),
            "--order", "manifest"], fetch=FakeNet(), sleep=Sleeper())
    assert "tar czf" in capsys.readouterr().err


def test_a_disk_error_abort_does_not_blame_the_network(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """同一個「連續 N 張失敗」計數器也會被**磁碟錯誤**觸發，而原本的訊息寫死成
    「網路中斷，或 CDN 改用 403/404 擋人；請先看 http_status」——那些紀錄根本沒有 HTTP 錯誤，
    reason 是「寫檔失敗 OSError: [Errno 28] No space left on device」。
    （寫檔失敗那一路的 `http_status` 是 200，所以**不能照 http_status 分類**。）"""
    out = tmp_path / "out"
    out.mkdir()
    for i in range(1, 7):
        (out / f"c{i}.jpg.part").mkdir()              # open(..., "wb") → IsADirectoryError
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 7)]),
                 "--dir", str(out), "--order", "manifest"], fetch=FakeNet(), sleep=Sleeper())
    err = capsys.readouterr().err
    assert rc == 1
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["aborted_kind"] == "failures"
    assert "都不是 HTTP 錯誤" in log["aborted"] and "磁碟" in log["aborted"]
    assert "http_status" not in log["aborted"].replace("沒有 http_status 可看", "")
    assert all(r.get("failure_kind") == "local"
               for r in log["files"].values() if r["status"] == "failed")
    assert "都不是 HTTP 錯誤" in err

    # 對照組一：真的是 HTTP 錯誤時，仍然指向 http_status
    out2 = tmp_path / "out2"
    F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 7)]),
            "--dir", str(out2), "--order", "manifest"],
           fetch=AlwaysNotFoundNet(range(1, 7)), sleep=Sleeper())
    log2 = json.loads((out2 / F.LOG_NAME).read_text(encoding="utf-8"))
    assert "http_status" in log2["aborted"] and "都不是 HTTP 錯誤" not in log2["aborted"]
    assert F.FAILURE_KIND_LABEL["http"] in log2["aborted"]

    # 對照組二：伺服器每次都回 200 但內容不是縮圖（攔截頁／企業 proxy）——那也不是
    # 「網路中斷或 CDN 擋人」，訊息同樣不該把人指向 http_status（那一欄是 200）
    out3 = tmp_path / "out3"
    F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 7)]),
            "--dir", str(out3), "--order", "manifest"],
           fetch=FakeNet(blob=HTML_ERROR_PAGE), sleep=Sleeper())
    log3 = json.loads((out3 / F.LOG_NAME).read_text(encoding="utf-8"))
    assert "伺服器每次都回 200" in log3["aborted"]
    assert "http_status" not in log3["aborted"]


def test_not_attempted_is_written_so_the_summary_adds_up(tmp_path: Path,
                                                         capsys: pytest.CaptureFixture) -> None:
    """`summarise` 的 `not_attempted` 原本沒有任何寫入端（死鍵，永遠是 0）。
    中止時把計畫裡還沒輪到的補記成該狀態，`--verify` 才看得出「這一趟還差哪些」。"""
    out = tmp_path / "out"
    assert F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 41)]),
                   "--dir", str(out), "--order", "manifest"],
                  fetch=ThrottlingNet(), sleep=Sleeper()) == 1
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    s = log["summary"]
    assert s["not_attempted"] > 0
    # 帳要對得起來：計畫 40 張 = 成功 + 失敗 + 沒輪到
    assert s["ok"] + s["failed"] + s["not_attempted"] == 40
    assert f"沒輪到 {s['not_attempted']} 張" in capsys.readouterr().err
    # 已經成功落地的不會被改寫成 not_attempted
    assert all(r["status"] != "not_attempted"
               for r in log["files"].values() if r.get("sha256"))


def test_not_attempted_does_not_overwrite_a_finished_run(tmp_path: Path) -> None:
    """反向：沒有中止時一筆 not_attempted 都不該出現（否則續傳的 skip 分支會被蓋掉）。"""
    out = tmp_path / "out"
    F.main(["--manifest", _manifest(tmp_path, [_cand(i) for i in range(1, 4)]),
            "--dir", str(out), "--order", "manifest"], fetch=FakeNet(), sleep=Sleeper())
    log = json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))
    assert log["summary"]["not_attempted"] == 0
    assert log["summary"]["ok"] == 3


# ---------------------------------------------------------------------------
# ⑨ 鏡像先行（ftpmirror.your.org）
#
# 這一節守的東西與前面八條是同一件事的另一面：**把 Wikimedia 的請求量砍掉**。
# 鏡像不是 Wikimedia 的 IP、不限流、也沒有懲罰可以被墊高，所以它的規則刻意與 Wikimedia 那條不同
# （步調 1 s、不計入 429 預算、抓的是原圖）。正因為不同，每一條「為什麼這裡可以」都要有測試守著，
# 否則下一個人會順手把那些放寬套回 Wikimedia 那條路徑上——那正是這支腳本存在的理由的反面。
#
# **測試一樣不碰網路**：鏡像也有自己的注入縫（`main(mirror_fetch=)`／`fetch_mirror_one(fetch=)`）。
# 而且「注入了 fetch= 卻沒注入 mirror_fetch=」一律把鏡像關掉——測試的縫不可以變成偷偷連外的洞。
# ---------------------------------------------------------------------------

# 鏡像給的是**原圖**：比縮圖大一個量級（實測 1.5–5.8 MB）。
MIRROR_ORIGINAL = F.JPEG_MAGIC + b"\x00" * 200_000 + F.JPEG_EOI
MIRROR_PATH_RE = re.compile(r"^https://ftpmirror\.your\.org/pub/wikimedia/images/wikipedia/commons/")


class FakeMirrorNet:
    """假鏡像：`hits` 裡的 pageid 回一張原圖大小的合法 JPEG，其餘 404（2013-03 之後上傳的那些）。

    `raises` 給「鏡像自己說不」與「這個網路連不到鏡像」兩種情境用。一個 socket 都不會開。
    """

    def __init__(self, hits=(), blob: bytes = MIRROR_ORIGINAL, raises=None) -> None:
        self.urls: list[str] = []
        self.hits = set(hits)
        self.blob = blob
        self.raises = raises

    def __call__(self, url: str, timeout: float):
        self.urls.append(url)
        assert "wikimedia.org" not in urllib.parse.urlsplit(url).netloc, url
        if self.raises is not None:
            raise self.raises
        pid = int(re.search(r"T(\d+)\.jpg", url).group(1))
        if pid in self.hits:
            return self.blob, 200, url
        raise _http_error(404)


def _log_of(out: Path) -> dict:
    return json.loads((out / F.LOG_NAME).read_text(encoding="utf-8"))


# --- 路徑推導：對真實鏡像驗證過的那條規則 --------------------------------------

def test_mirror_url_is_the_commons_path_appended_to_the_base() -> None:
    """規則（2026-09-26 對真實鏡像發 16 次 HEAD 驗過）：`url` 去掉 query、取 `/commons/` 之後那一段，
    **原樣**接在 base 後面。實測 `b/b5/Windkraftanlage_Gr%C3%BCner_Heiner.jpg` → 200 image/jpeg、
    沒有任何重導向；2013-03 之後上傳的一律 404（146 bytes 的 HTML）。"""
    assert F.commons_path_of(ORIGINAL) == "0/0c/X.jpg"
    assert F.commons_path_of(ORIGINAL + "?utm_source=commons") == "0/0c/X.jpg"
    # **percent-encoding 原樣保留**：先 unquote 再 quote 會把檔名裡本來就有的 %2C 改寫掉
    enc = "https://upload.wikimedia.org/wikipedia/commons/b/b5/Windkraftanlage_Gr%C3%BCner_Heiner.jpg"
    assert F.commons_path_of(enc) == "b/b5/Windkraftanlage_Gr%C3%BCner_Heiner.jpg"
    assert F.mirror_url_for({"url": enc}) == (
        "https://ftpmirror.your.org/pub/wikimedia/images/wikipedia/commons/"
        "b/b5/Windkraftanlage_Gr%C3%BCner_Heiner.jpg")
    # 推不出來的一律 None（呼叫端直接走 Wikimedia，不是猜一個網址出來）
    assert F.commons_path_of(THUMB) is None              # 鏡像只鏡原始 media 樹，沒有 /thumb/
    assert F.commons_path_of("https://example.org/a.jpg") is None
    assert F.commons_path_of("https://upload.wikimedia.org/wikipedia/commons/") is None
    assert F.commons_path_of("https://upload.wikimedia.org/wikipedia/commons/../etc/passwd") is None
    assert F.commons_path_of(None) is None
    assert F.mirror_url_for({"url": None}) is None


def test_every_selected_candidate_resolves_to_a_mirror_url(doc: dict) -> None:
    """全 313 張逐張：推得出鏡像網址、而且一定在 base 底下（推不出來就是白白少一條省流量的路）。"""
    n = 0
    for c in doc["candidates"]:
        if not c.get("selected"):
            continue
        url = F.mirror_url_for(c)
        assert url and MIRROR_PATH_RE.match(url), (c["pageid"], url)
        assert "?" not in url and "wikimedia.org" not in urllib.parse.urlsplit(url).netloc
        n += 1
    assert n == 313


# --- 命中就完全不碰 Wikimedia ---------------------------------------------------

def test_a_mirror_hit_never_asks_wikimedia_for_anything(tmp_path: Path) -> None:
    """**這條是整個功能的重點**：鏡像拿得到的那 66 張，對 Wikimedia 的請求量直接歸零（約 21%）。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    out = tmp_path / "out"
    wm, mir = FakeNet(), FakeMirrorNet(hits={1, 2})
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=wm, sleep=Sleeper(), mirror_fetch=mir) == 0
    assert wm.urls == []                                   # 一個請求都沒打到 Wikimedia
    assert len(mir.urls) == 2 and all(MIRROR_PATH_RE.match(u) for u in mir.urls)
    assert (out / "c1.jpg").read_bytes() == MIRROR_ORIGINAL
    rec = _log_of(out)["files"]["1"]
    assert rec["status"] == "ok" and rec["source"] == "mirror" and rec["mirror_status"] == "hit"
    assert rec["sha256"] and rec["bytes"] == len(MIRROR_ORIGINAL)


def test_a_mirror_404_falls_back_to_the_wikimedia_thumbnail(tmp_path: Path) -> None:
    """鏡像的媒體檔凍結在 2013-03，之後上傳的一律 404——那**不是失敗**，是「這張要走 Wikimedia」。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    out = tmp_path / "out"
    wm, mir = FakeNet(), FakeMirrorNet(hits={1})
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=wm, sleep=Sleeper(), mirror_fetch=mir) == 0
    assert _pageids(mir.urls) == [1, 2] and _pageids(wm.urls) == [2]
    files = _log_of(out)["files"]
    assert files["1"]["source"] == "mirror" and files["1"]["mirror_status"] == "hit"
    assert files["2"]["source"] == "wikimedia" and files["2"]["mirror_status"] == "miss"
    assert files["2"]["status"] == "ok"
    # 404 不算失敗：不加 fail_streak，也不會讓「連續 N 張失敗」的煞車誤觸
    assert files["2"]["fail_streak"] == 0
    assert (out / "c2.jpg").read_bytes() == GOOD_JPEG


def test_a_known_mirror_404_is_not_probed_twice(tmp_path: Path) -> None:
    """鏡像凍結，所以 404 是**永久**的。每趟再問一次是純浪費（247 張 × 每趟一個請求）。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    out = tmp_path / "out"
    mir1 = FakeMirrorNet(hits={1})
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
           fetch=FakeNet(blob=HTML_ERROR_PAGE), sleep=Sleeper(), mirror_fetch=mir1)
    assert _pageids(mir1.urls) == [1, 2]
    assert _log_of(out)["files"]["2"]["mirror_status"] == "miss"

    mir2 = FakeMirrorNet(hits={1})            # c1 已經在磁碟上；c2 已知 404
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
           fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=mir2)
    assert mir2.urls == []                     # 不再問鏡像任何一張


# --- 鏡像不計入 429 預算、也有自己的步調 ----------------------------------------

def test_mirror_requests_never_touch_the_429_budget(tmp_path: Path) -> None:
    """鏡像若自己回 429，那是**鏡像**在限流，與「使用者的出口 IP 在 Wikimedia 眼中的處境」無關。
    把它併進 `events_429` 會讓那份證據（要寄給 bot-traffic@wikimedia.org 的）變成假的，
    也會讓煞車因為一個不相干的主機而提早鎖死整趟。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 4)])
    out = tmp_path / "out"
    wm = FakeNet()
    mir = FakeMirrorNet(raises=_http_error(429, {"Retry-After": "600"}))
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=wm, sleep=Sleeper(), mirror_fetch=mir) == 0
    log = _log_of(out)
    assert log["events_429"] == [] and log["total_429"] == 0 and log["run_429"] == 0
    assert len(log["events_mirror"]) == 1                  # 鏡像的事件記在自己那一格
    # 鏡像說不 → 這一趟不再問它，剩下的照走 Wikimedia（不是中止整趟）
    assert len(mir.urls) == 1 and _pageids(wm.urls) == [1, 2, 3]
    assert log["mirror_disabled_reason"] and "429" in log["mirror_disabled_reason"]
    assert len(list(out.glob("c*.jpg"))) == 3


def test_mirror_has_its_own_clock_and_does_not_slow_wikimedia(tmp_path: Path) -> None:
    """鏡像 1 s、Wikimedia 15 s，**兩個時鐘分開**。共用一個的話不是鏡像被拖慢 15 倍，
    就是 Wikimedia 被加速到 1 s——後者正是這支腳本存在理由的反面。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2), _cand(3)])
    out = tmp_path / "out"
    nap = Sleeper()
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest",
            "--pace", "15", "--mirror-pace", "1"],
           fetch=FakeNet(), sleep=nap, mirror_fetch=FakeMirrorNet(hits={1}))
    short = [w for w in nap.waits if 0.5 < w <= 1.0]
    long_ = [w for w in nap.waits if 13.0 < w <= 15.0]
    assert len(short) == 2, nap.waits          # 第 2、3 張的鏡像探測各等 1 s
    assert len(long_) == 1, nap.waits          # Wikimedia 只有第 3 張要等（第 2 張是這趟第一個）
    assert not [w for w in nap.waits if 1.0 < w <= 13.0], nap.waits


def test_mirror_pace_has_a_floor_of_its_own(tmp_path: Path,
                                            capsys: pytest.CaptureFixture) -> None:
    """鏡像不限流不代表可以無限快——那是別人出錢的頻寬，地板是 Robot policy 的官方值 1 s。"""
    assert F.MIRROR_PACE_FLOOR_S == 1.0 and F.DEFAULT_MIRROR_PACE_S == 1.0
    mir = FakeMirrorNet(hits={1})
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(1)]), "--dir", str(tmp_path / "o"),
                 "--mirror-pace", "0.05"], fetch=FakeNet(), sleep=_boom, mirror_fetch=mir)
    assert rc == 2 and mir.urls == []
    assert "Robot policy" in capsys.readouterr().err


# --- --mirror-only：被封的那台機器上唯一跑得動的模式 ----------------------------

def test_mirror_only_never_sends_a_single_request_to_wikimedia(tmp_path: Path) -> None:
    """`--mirror-only` 是承諾，不是偏好：鏡像沒有的那些**不准**回退。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 5)])
    out = tmp_path / "out"
    wm, mir = FakeNet(), FakeMirrorNet(hits={1, 3})
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--mirror-only"],
                  fetch=wm, sleep=Sleeper(), mirror_fetch=mir) == 0
    assert wm.urls == []
    assert _pageids(mir.urls) == [1, 2, 3, 4]
    assert sorted(p.name for p in out.glob("c*.jpg")) == ["c1.jpg", "c3.jpg"]
    files = _log_of(out)["files"]
    assert files["2"]["status"] == "mirror_miss" and files["2"]["mirror_status"] == "miss"
    assert files["2"]["fail_streak"] == 0          # 鏡像上沒有 ≠ 這張抓不到
    assert _log_of(out)["summary"]["mirror_miss"] == 2


def test_mirror_only_drops_known_misses_so_limit_means_something(tmp_path: Path) -> None:
    """`--limit` 的名額不該被「這個模式裡永遠抓不到」的佔住——那是 `--limit` 空轉的另一種形狀。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 7)])
    out = tmp_path / "out"
    mir1 = FakeMirrorNet(hits=())
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest",
            "--mirror-only", "--limit", "3"], fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=mir1)
    assert _pageids(mir1.urls) == [1, 2, 3]
    mir2 = FakeMirrorNet(hits={4})
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest",
            "--mirror-only", "--limit", "3"], fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=mir2)
    assert _pageids(mir2.urls) == [4, 5, 6]        # 名額給沒探過的，不是再敲一次同樣的 404
    assert (out / "c4.jpg").exists()


def test_mirror_only_runs_on_a_machine_wikimedia_has_already_blocked(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """**這個功能存在的理由**：出口 IP 被擋住的機器上，跨趟煞車會讓一般模式 rc=2 拒跑，
    而 `--mirror-only` 不碰 Wikimedia，所以照跑。"""
    out = tmp_path / "out"
    _seed_log(out, aborted="這一趟累計 5 次 429（上限 5）", aborted_kind="throttled",
              events_429=[{"at": F.utcnow(), "http_status": 429}] * 5)
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    wm, mir = FakeNet(), FakeMirrorNet(hits={1})
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--mirror-only"],
                  fetch=wm, sleep=Sleeper(), mirror_fetch=mir) == 0
    err = capsys.readouterr().err
    assert wm.urls == [] and (out / "c1.jpg").exists()
    assert "不碰 Wikimedia" in err and "--new-network" in err


def test_a_mirror_only_run_does_not_clear_the_cross_run_brake(tmp_path: Path) -> None:
    """**ship blocker 等級的反向**：`--mirror-only` 跑完會把 `aborted` 覆寫成 None，
    而舊的跨趟煞車就是讀那一欄——於是「先跑一次 --mirror-only」變成解除封鎖的後門，
    下一趟就直接打回那個已經被封的 IP。封鎖狀態要自己有一格（`wikimedia_block`），
    只有 `--new-network` 清得掉。"""
    out = tmp_path / "out"
    _seed_log(out, aborted="這一趟累計 5 次 429（上限 5）", aborted_kind="throttled",
              events_429=[{"at": F.utcnow(), "http_status": 429}] * 5)
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--mirror-only"],
           fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=FakeMirrorNet(hits={1}))
    log = _log_of(out)
    assert log["aborted"] is None                      # 這一趟本身沒有中止
    assert log["wikimedia_block"]["kind"] == "throttled"   # 但封鎖還在

    wm = FakeNet()                                     # 一般模式：仍然拒跑、零請求
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=wm, sleep=Sleeper()) == 2
    assert wm.urls == []
    # 換網路之後才解除
    wm2 = FakeNet()
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--new-network"],
                  fetch=wm2, sleep=Sleeper()) == 0
    assert _pageids(wm2.urls) == [2]                   # c1 已由鏡像抓到，只補 c2
    assert _log_of(out)["wikimedia_block"] is None


def test_a_mirror_only_run_does_not_refill_the_429_budget(tmp_path: Path) -> None:
    """另一半：預算吃完（但上一趟不是被限流中止）時，`--mirror-only` 照跑但**不重設預算**。"""
    out = tmp_path / "out"
    _seed_log(out, events_429=[{"at": F.utcnow(), "http_status": 429}] * F.MAX_TOTAL_429)
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--mirror-only"],
                  fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=FakeMirrorNet(hits={1})) == 0
    assert F.recent_429_count(_log_of(out)["events_429"]) == F.MAX_TOTAL_429
    wm = FakeNet()
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=wm, sleep=Sleeper()) == 2 and wm.urls == []


def test_mirror_only_stops_instead_of_marking_everything_as_missing(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """鏡像連不上（這個網路到不了它）時，**不可以**把剩下的全部記成「鏡像上沒有」——
    那個標記是永久的（下一趟整批被略過），於是一次 DNS 故障會讓那些照片再也不會被嘗試。
    只有真的收到 404 才算 miss；連不上就是停手。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 9)])
    out = tmp_path / "out"
    mir = FakeMirrorNet(raises=urllib.error.URLError("dns"))
    rc = F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--mirror-only"],
                fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=mir)
    assert rc == 1 and len(mir.urls) == F.MIRROR_MAX_FAILURES
    log = _log_of(out)
    assert log["aborted_kind"] == "failures" and "不回退到 Wikimedia" in log["aborted"]
    assert all(r.get("mirror_status") != "miss" for r in log["files"].values())
    assert "鏡像關閉" in capsys.readouterr().err


def test_an_unreachable_mirror_falls_back_instead_of_failing_the_run(tmp_path: Path) -> None:
    """一般模式的對照：鏡像連不上只是少一條捷徑，整趟照走 Wikimedia 跑完。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 7)])
    out = tmp_path / "out"
    wm = FakeNet()
    mir = FakeMirrorNet(raises=urllib.error.URLError("dns"))
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=wm, sleep=Sleeper(), mirror_fetch=mir) == 0
    assert len(mir.urls) == F.MIRROR_MAX_FAILURES        # 試 3 次就關掉，不是每張各賠一個請求
    assert _pageids(wm.urls) == [1, 2, 3, 4, 5, 6]
    log = _log_of(out)
    assert log["mirror_disabled_reason"] and log["events_429"] == []
    assert all(r.get("mirror_status") != "miss" for r in log["files"].values())


def test_mirror_only_and_no_mirror_are_mutually_exclusive(tmp_path: Path,
                                                          capsys: pytest.CaptureFixture) -> None:
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(1)]), "--dir", str(tmp_path / "o"),
                 "--mirror-only", "--no-mirror"], fetch=_boom, sleep=_boom, mirror_fetch=_boom)
    assert rc == 2 and "互斥" in capsys.readouterr().err


def test_no_mirror_restores_the_old_behaviour(tmp_path: Path) -> None:
    """`--no-mirror` 是逃生口：鏡像出了任何意外，使用者要能一鍵回到加鏡像之前的行為。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    out = tmp_path / "out"
    wm, mir = FakeNet(), FakeMirrorNet(hits={1, 2})
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--no-mirror"],
                  fetch=wm, sleep=Sleeper(), mirror_fetch=mir) == 0
    assert mir.urls == [] and _pageids(wm.urls) == [1, 2]
    assert _log_of(out)["files"]["1"]["source"] == "wikimedia"


# --- 「絕不抓原圖」只適用於 Wikimedia 那條路徑 ---------------------------------

def test_the_mirror_original_is_allowed_but_wikimedia_still_may_not_serve_one(
        tmp_path: Path) -> None:
    """**這是最容易被下一個人改壞的一條。** 「絕不抓原圖」的兩個理由（原圖是多 MB、
    而且原圖同樣在 429 名單上）在鏡像上**都不成立**：鏡像上只有原圖、沒有縮圖可選，而且鏡像不限流。
    所以鏡像那條路徑 `require_thumb=False`、上限放寬到 64 MB；Wikimedia 那條**一個字都沒放寬**。
    """
    assert F.MAX_MIRROR_RESPONSE_BYTES > F.MAX_RESPONSE_BYTES
    big = F.JPEG_MAGIC + b"\x00" * (F.MAX_RESPONSE_BYTES + 10) + F.JPEG_EOI

    # 鏡像：非 /thumb/ 路徑、超過 8 MB —— 照樣落地
    p1 = tmp_path / "m.jpg"
    res = F.fetch_mirror_one("https://ftpmirror.your.org/pub/wikimedia/images/wikipedia/"
                             "commons/0/0c/T1.jpg", str(p1), 10,
                             fetch=FakeMirrorNet(hits={1}, blob=big))
    assert res["status"] == "ok" and p1.read_bytes() == big

    # Wikimedia：同一份位元組一律拒收（兩條路徑不共用放寬）
    p2 = tmp_path / "w.jpg"
    res2 = F.fetch_one(URL, str(p2), 10, quiet=True, fetch=FakeNet(blob=big), sleep=Sleeper())
    assert res2["status"] == "failed" and "上限" in res2["reason"] and not p2.exists()
    res3 = F.fetch_one(URL, str(p2), 10, quiet=True,
                       fetch=lambda u, t: (GOOD_JPEG, 200, ORIGINAL), sleep=Sleeper())
    assert res3["status"] == "failed" and "原圖" in res3["reason"]


def test_the_mirror_still_checks_magic_size_and_the_end_marker(tmp_path: Path) -> None:
    """放寬的只有「原圖」與「大小上限」兩條，內容檢查一條都沒少——
    鏡像的 404 頁也是 HTML，而截斷的 JPEG 前 3 個 byte 與完整檔一模一樣。"""
    for blob, why in ((HTML_ERROR_PAGE, "不是影像"), (TRUNCATED_JPEG, "結尾標記"),
                      (F.JPEG_MAGIC + b"\x00" * 10 + F.JPEG_EOI, "太小")):
        p = tmp_path / "x.jpg"
        res = F.fetch_mirror_one("https://ftpmirror.your.org/pub/wikimedia/images/wikipedia/"
                                 "commons/0/0c/T1.jpg", str(p), 10,
                                 fetch=FakeMirrorNet(hits={1}, blob=blob))
        assert res["status"] == "failed" and why in res["reason"]
        assert not p.exists() and not (tmp_path / "x.jpg.part").exists()


# --- 鏡像那條路徑不准滑回 Wikimedia --------------------------------------------

def test_the_mirror_base_may_not_point_at_wikimedia(tmp_path: Path,
                                                    capsys: pytest.CaptureFixture) -> None:
    """把 base 指回 Wikimedia 等於拿掉全部煞車：那條路徑不計入 429 預算、步調只有 1 s，
    於是變成對著已經封鎖我們的 CDN 每秒敲一次。這是這支腳本最貴的一種 bug，要在發出去之前死掉。"""
    for bad in ("https://upload.wikimedia.org/wikipedia/commons",
                "https://thumb.wikimedia.org/x", "https://commons.wikimedia.org/x",
                "https://WIKIMEDIA.ORG/x"):
        mir = FakeMirrorNet(hits={1})
        rc = F.main(["--manifest", _manifest(tmp_path, [_cand(1)]), "--dir", str(tmp_path / "o"),
                     "--mirror-base", bad], fetch=FakeNet(), sleep=_boom, mirror_fetch=mir)
        assert rc == 2 and mir.urls == [], bad
    assert "不得指向 Wikimedia" in capsys.readouterr().err
    assert F.is_wikimedia_host("https://upload.wikimedia.org/a") is True
    assert F.is_wikimedia_host("https://ftpmirror.your.org/a") is False
    assert F.is_wikimedia_host("https://notwikimedia.org/a") is False   # 後綴比對不能只用 in
    with pytest.raises(ValueError):
        F.http_get_mirror("https://upload.wikimedia.org/wikipedia/commons/0/0c/X.jpg", 1)


def test_the_mirror_never_follows_a_redirect_off_the_mirror() -> None:
    """鏡像回 302 指向 upload.wikimedia.org 的話，urllib 預設會乖乖跟過去——
    `--mirror-only` 的承諾當場破功，而且那一發請求打在已經被封的 IP 上。兩層都要擋：
    重導向處理器不跟隨，回應端再驗一次 final_url 的主機。"""
    guard = F._SameHostRedirect("ftpmirror.your.org")
    with pytest.raises(urllib.error.HTTPError):
        guard.redirect_request(None, None, 302, "Found", {},
                               "https://upload.wikimedia.org/wikipedia/commons/0/0c/X.jpg")
    bad = F.validate_blob(GOOD_JPEG, 200, ORIGINAL, require_thumb=False,
                          max_bytes=F.MAX_MIRROR_RESPONSE_BYTES, same_host="ftpmirror.your.org")
    assert bad and "別的主機" in bad["reason"]
    ok = F.validate_blob(GOOD_JPEG, 200,
                         "https://ftpmirror.your.org/pub/wikimedia/images/wikipedia/commons/0/0c/X.jpg",
                         require_thumb=False, max_bytes=F.MAX_MIRROR_RESPONSE_BYTES,
                         same_host="ftpmirror.your.org")
    assert ok is None


def test_injecting_a_fake_wikimedia_fetcher_never_lets_the_real_mirror_out(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """測試的縫不可以變成偷偷連外的洞：只注入 `fetch=` 的測試（這份檔案裡有 85 支）
    如果讓鏡像走真的 `http_get_mirror`，它們會在 CI 上對外連線而且沒有人會發現。"""
    m = _manifest(tmp_path, [_cand(1)])
    wm = FakeNet()
    assert F.main(["--manifest", m, "--dir", str(tmp_path / "o"), "--order", "manifest"],
                  fetch=wm, sleep=Sleeper()) == 0
    assert _pageids(wm.urls) == [1]                     # 全部走 Wikimedia，鏡像關著
    assert _log_of(tmp_path / "o")["mirror_enabled"] is False
    # `--mirror-only` 在那種情況下沒有來源可用 → 說清楚，不要靜默跑 0 張
    rc = F.main(["--manifest", m, "--dir", str(tmp_path / "o2"), "--mirror-only"],
                fetch=FakeNet(), sleep=Sleeper())
    assert rc == 2 and "mirror_fetch" in capsys.readouterr().err


# --- log／收尾／dry-run ---------------------------------------------------------

def test_the_log_keeps_the_two_sources_apart(tmp_path: Path,
                                             capsys: pytest.CaptureFixture) -> None:
    """原圖比縮圖大一個量級，混在一起加總的話「這一趟打了多少 Wikimedia」就看不出來了。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 5)])
    out = tmp_path / "out"
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
           fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=FakeMirrorNet(hits={1, 2}))
    s = _log_of(out)["summary"]
    assert s["ok"] == 4 and s["ok_mirror"] == 2 and s["ok_wikimedia"] == 2
    assert s["bytes_mirror"] == 2 * len(MIRROR_ORIGINAL)
    assert s["bytes_wikimedia"] == 2 * len(GOOD_JPEG)
    assert s["bytes_this_run_mirror"] + s["bytes_this_run_wikimedia"] == s["bytes_this_run"]
    err = capsys.readouterr().err
    assert "其中鏡像 2 張" in err and "Wikimedia 2 張" in err


def test_dry_run_prints_the_mirror_outlook_without_asking_anything(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """第一次是用實測命中率估的，跑過一趟之後就是精確值——兩者要分開講，
    否則使用者會把估出來的數字當成實測的。"""
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 5)])
    out = tmp_path / "out"
    assert F.main(["--dry-run", "--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=_boom, sleep=_boom, mirror_fetch=_boom) == 0
    first = capsys.readouterr().out
    assert "鏡像預計可得" in first and "Wikimedia 需要" in first
    assert "未知" in first and "66/313" in first
    assert "ftpmirror.your.org" in first and F.MIRROR_FREEZE in first

    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
           fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=FakeMirrorNet(hits={1, 2}))
    capsys.readouterr()
    F.main(["--dry-run", "--manifest", m, "--dir", str(out), "--order", "manifest",
            "--include-fetched"], fetch=_boom, sleep=_boom, mirror_fetch=_boom)
    second = capsys.readouterr().out
    assert "鏡像預計可得 2 張／Wikimedia 需要 2 張" in second
    assert "精確值不是估計" in second

    # 純函式層：估算與精確兩種情況
    plan = [_cand(i) for i in range(1, 5)]
    assert F.mirror_outlook(plan, {})["unknown"] == 4
    known = {"files": {"1": {"mirror_status": "hit"}, "2": {"mirror_status": "miss"}}}
    look = F.mirror_outlook(plan, known)
    assert (look["known_hit"], look["known_miss"], look["unknown"]) == (1, 1, 2)


def test_a_mirror_only_run_does_not_pretend_the_job_is_done(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """`--mirror-only` 跑完 ≠ 抓完（鏡像只有 66/313）。照印「打包帶回去」會讓使用者
    把 66 張當成 313 張帶走，而那個錯誤要到分析階段才會發現。"""
    m = _manifest(tmp_path, [_cand(1), _cand(2)])
    out = tmp_path / "out"
    F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--mirror-only"],
           fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=FakeMirrorNet(hits={1}))
    err = capsys.readouterr().err
    assert "tar czf" not in err
    assert "鏡像能給的都拿完了" in err and "不加** --mirror-only" in err

    # 對照組：鏡像剛好全命中（抓完了）就照印打包指令
    out2 = tmp_path / "out2"
    F.main(["--manifest", m, "--dir", str(out2), "--order", "manifest", "--mirror-only"],
           fetch=FakeNet(), sleep=Sleeper(), mirror_fetch=FakeMirrorNet(hits={1, 2}))
    assert "tar czf" in capsys.readouterr().err


def test_the_header_documents_the_mirror_route_and_its_boundary() -> None:
    """說明檔是這個腳本唯一會被讀的東西（它是要交給別人在別的機器上跑的）。
    鏡像的三件事一定要寫進去：路徑規則、2013-03 的邊界、以及被封的機器可以直接 --mirror-only。"""
    head = F.__doc__ or ""
    assert "ftpmirror.your.org" in head and "2013" in head
    assert "--mirror-only" in head and "66 張" in head
    # 「絕不抓原圖」的例外要講清楚**為什麼**，不然下一個人會把它套回 Wikimedia 那條路徑
    assert "只適用於 Wikimedia 那條路徑" in head
    assert "不計入全域 429 預算" in head
    flags = set(re.findall(r'ap\.add_argument\("(--[a-z0-9-]+)"', SOURCE))
    assert {"--mirror-only", "--no-mirror", "--mirror-base", "--mirror-pace"} <= flags


# ---------------------------------------------------------------------------
# ⑩ 第二輪六項的邊界——把「什麼情況下不准再發出一個請求」釘在**常數**上
#
# ⑧⑨ 守的是每一項修好之後的行為；這一節補的是它們的邊界，而且刻意**不寫死門檻**：
# 煞車在第二趟之後還在不在、回復是不是真的等滿 `PACE_RECOVER_AFTER` 張、名額最多被永久失敗的
# 圖佔幾趟、結尾標記的視窗到底多大、鏡像的時鐘會不會被 Wikimedia 的減速一起拖慢。
# 把數字寫死的話，下一個人把 `MAX_TOTAL_429` 從 5 改成 50、把 `RECENT_429_WINDOW_H` 從 24 改成 0.1
# 只會看到一條看不懂的紅線；綁在常數上的測試才會在**放寬煞車**的時候說話。
#
# 一樣一個 socket 都不開：Wikimedia／鏡像兩條路都用注入的假抓取器，等待也一律是假的。
# ---------------------------------------------------------------------------

def test_the_cross_run_brake_stays_on_until_new_network_clears_it(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """跨趟煞車的**邊界**：不是「下一趟拒跑」而是「在解除之前每一趟都拒跑」。

    反向很具體——`while ! cmd; do sleep 60; done` 只擋得住第一次重跑是沒有用的，
    那個迴圈會跑一整夜。所以這裡連跑兩趟拒跑，並且要求拒跑**什麼都不做**：
    零請求、零 sleep（`sleep=_boom`）、log 裡的 429 實證一筆都不准增減。
    解除之後也要真的解除乾淨：`wikimedia_block` 清成 None，**下一趟不必再加一次
    `--new-network`**（否則使用者會養成每次都加的習慣，那個旗標就失去意義）。
    """
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 41)])
    out = tmp_path / "out"
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--pace", "15"],
                  fetch=ThrottlingNet(), sleep=Sleeper()) == 1
    blocked = _log_of(out)["wikimedia_block"]
    assert blocked and blocked["kind"] == "throttled" and blocked["at"]

    for _ in range(2):                       # 第二趟、第三趟……在解除之前一律拒跑
        capsys.readouterr()
        net = ThrottlingNet()
        rc = F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--pace", "15"],
                    fetch=net, sleep=_boom)          # 拒跑連一次 sleep 都不該發生
        assert rc == 2 and net.urls == []
        assert "--new-network" in capsys.readouterr().err
        log = _log_of(out)
        assert len(log["events_429"]) == F.MAX_TOTAL_429      # 拒跑不增不減，實證原樣留著
        assert log["wikimedia_block"]["kind"] == "throttled"  # 煞車也沒有被「跑過一趟」磨掉

    net = FakeNet()
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--new-network"],
                  fetch=net, sleep=Sleeper()) == 0
    assert len(net.urls) == 40 - F.MAX_TOTAL_429    # 中止前已落地的那幾張不重抓
    assert _log_of(out)["wikimedia_block"] is None

    after = FakeNet()                        # 解除是一次性的，不是每趟都要再宣告一次
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=after, sleep=Sleeper()) == 0
    assert after.urls == []                  # 40 張都在磁碟上了，所以零請求也是對的


def test_the_budget_window_is_the_constant_not_a_number_typed_twice(tmp_path: Path) -> None:
    """預算的回看窗是 `RECENT_429_WINDOW_H`，兩邊都要跟著它動。

    反向有兩個方向，兩個都會害人：窗開太小（或退回單趟）→ 重跑同一行又吃滿一份預算；
    窗開太大又永不過期 → 使用者換了網路、隔了一週回來，卻被自己上個月的紀錄鎖死，
    而畫面只說「加 --new-network」——那在**新網路上**是對的，在舊網路上是硬闖。
    """
    now = datetime.now(timezone.utc)
    inside = (now - timedelta(hours=F.RECENT_429_WINDOW_H - 1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    outside = (now - timedelta(hours=F.RECENT_429_WINDOW_H + 1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert F.recent_429_count([{"at": inside}] * F.MAX_TOTAL_429) == F.MAX_TOTAL_429
    assert F.recent_429_count([{"at": outside}] * F.MAX_TOTAL_429) == 0

    # 行為面：窗外的舊事件不該讓下一趟拒跑（`test_an_exhausted_budget_refuses_to_start_at_all`
    # 的另一半）。上一趟是 Ctrl-C，所以沒有跨趟煞車、只剩預算這一關。
    out = tmp_path / "out"
    _seed_log(out, aborted="使用者中斷（Ctrl-C）", aborted_kind="interrupt",
              events_429=[{"at": outside, "http_status": 429}] * F.MAX_TOTAL_429)
    net = FakeNet()
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(1), _cand(2)]), "--dir", str(out),
                 "--order", "manifest"], fetch=net, sleep=Sleeper())
    assert rc == 0 and len(net.urls) == 2


def test_the_pace_returns_to_base_after_exactly_the_documented_clean_run(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """回復的**時機**：連續 `PACE_RECOVER_AFTER` 張乾淨才減半一次，不是「下一張就回去」。

    兩邊都要守：回得太早等於把伺服器剛說的「太快了」當耳邊風；回不來則是 78 分鐘變 20 小時
    （使用者在別人的筆電上看不到總進度，最可能的結局是以為當掉而 Ctrl-C）。
    這裡用**假 sleep 真的收到幾秒**來驗，而不是只看 log 最後那個數字——只改變數不改等待
    是「看起來有減速」的那種 bug，只有被封之後才會發現。
    """
    cands = [_cand(i) for i in range(1, 15)]          # 1 吃 429，2–14 共 13 張乾淨
    out = tmp_path / "out"
    nap = Sleeper()
    rc = F.main(["--manifest", _manifest(tmp_path, cands), "--dir", str(out),
                 "--order", "manifest", "--pace", "10"],
                fetch=SometimesThrottlingNet({1}), sleep=nap)
    err = capsys.readouterr().err
    assert rc == 0
    paced = [w for w in nap.waits if w != 600.0]      # 600 是 Retry-After，不是步調
    # 第 2 張起以加倍後的 20 s 在跑，滿 PACE_RECOVER_AFTER 張乾淨才減半回 10 s
    assert [round(w) for w in paced[:F.PACE_RECOVER_AFTER]] == [20] * F.PACE_RECOVER_AFTER
    assert [round(w) for w in paced[F.PACE_RECOVER_AFTER:]] == [10] * (13 - F.PACE_RECOVER_AFTER)
    assert f"連續 {F.PACE_RECOVER_AFTER} 張沒有 429" in err
    assert err.count("減半回") == 1                   # 一次 429 只換一次減半，不是每張都減
    assert _log_of(out)["pace_s"] == 10.0


def test_a_dead_image_costs_the_limit_at_most_fail_streak_demote_runs(tmp_path: Path) -> None:
    """名額被永久失敗的圖佔住的**趟數上限**＝`FAIL_STREAK_DEMOTE`，不是無限。

    「上一趟失敗」≠「永遠失敗」（新網路上的 404 可能只是 DNS 沒通），所以前幾趟照樣重試；
    但那個「幾」必須有界，否則 `--limit 3` 連跑一整天都在對著同樣三個 404 敲。
    綁在常數上：有人把門檻調高成 10，這條測試會跟著要求它在第 11 趟放手。
    """
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 21)])
    out = tmp_path / "out"
    seen: list[list[int]] = []
    for _ in range(F.FAIL_STREAK_DEMOTE + 1):
        net = AlwaysNotFoundNet({1, 2, 3})
        assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--limit", "3"],
                      fetch=net, sleep=Sleeper()) == 0
        seen.append(_pageids(net.urls))
    assert seen[:F.FAIL_STREAK_DEMOTE] == [[1, 2, 3]] * F.FAIL_STREAK_DEMOTE
    assert seen[-1] == [4, 5, 6]               # 名額終於落到真的抓得到的那些上
    assert sorted(p.name for p in out.glob("c*.jpg")) == ["c4.jpg", "c5.jpg", "c6.jpg"]
    # 排到尾端**不是刪掉**：它們仍在 log 裡、仍帶著理由，下一趟仍有最後一次機會
    files = _log_of(out)["files"]
    assert files["1"]["status"] == "failed" and files["1"]["fail_streak"] == F.FAIL_STREAK_DEMOTE
    assert "404" in files["1"]["reason"]


def test_two_runs_are_enough_when_the_directory_already_carries_the_failures(
        tmp_path: Path) -> None:
    """實際的使用情境：目錄是**帶著上一台機器的 `fetch_log.json` 一起搬過來的**。

    那份 log 裡的 `fail_streak` 要算數——不然換一台機器就把「已經知道這幾張抓不到」忘光，
    `--limit 3` 又從頭對著同樣三個 404 敲滿 `FAIL_STREAK_DEMOTE` 趟。
    這裡的 log 帶著「差一次就到門檻」的紀錄：第一趟給最後一次機會，**第二趟名額就要換人**。
    """
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 21)])
    out = tmp_path / "out"
    _seed_log(out, files={str(i): {"file": f"c{i}.jpg", "status": "failed", "reason": "HTTP 404",
                                   "fail_streak": F.FAIL_STREAK_DEMOTE - 1} for i in (1, 2, 3)})
    first = AlwaysNotFoundNet({1, 2, 3})
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--limit", "3"],
                  fetch=first, sleep=Sleeper()) == 0
    second = AlwaysNotFoundNet({1, 2, 3})
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--limit", "3"],
                  fetch=second, sleep=Sleeper()) == 0
    assert _pageids(first.urls) == [1, 2, 3]
    assert _pageids(second.urls) == [4, 5, 6]
    assert sorted(p.name for p in out.glob("c*.jpg")) == ["c4.jpg", "c5.jpg", "c6.jpg"]


def test_the_mirror_clock_and_budget_survive_a_wikimedia_slowdown(tmp_path: Path) -> None:
    """混合一趟：鏡像命中一半、Wikimedia 那一半每張都先 429。**兩條路完全分開**。

    這是「鏡像不計入 429 預算」最容易破功的形狀——同一個迴圈裡兩種請求交錯，
    只要有人把 `a.pace` 的加倍套到鏡像的時鐘上，或把鏡像的請求算進 `events_429`，
    結果都是錯的：前者讓鏡像陪著被罰站（那 66 張的捷徑失去意義），
    後者讓要寄給 bot-traffic@wikimedia.org 的實證變成假的、煞車也提早鎖死整趟。
    """
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 7)])
    out = tmp_path / "out"
    wm, mir, nap = ThrottlingNet(), FakeMirrorNet(hits={1, 3, 5}), Sleeper()
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest",
                   "--pace", "15", "--mirror-pace", "1"],
                  fetch=wm, sleep=nap, mirror_fetch=mir) == 0
    log = _log_of(out)
    # 預算只算 Wikimedia：3 張回退 × 每張 429 一次
    assert log["total_429"] == 3 and len(log["events_429"]) == 3
    assert all("wikimedia.org" in urllib.parse.urlsplit(e["url"]).netloc
               for e in log["events_429"])
    assert log["events_mirror"] == []                 # 鏡像 404 是預期的答案，不是事件
    assert _pageids(mir.urls) == [1, 2, 3, 4, 5, 6]   # 每張都先問鏡像
    assert _pageids(wm.urls) == [2, 2, 4, 4, 6, 6]    # 只有 miss 的那三張回退（各 429 + 重試）
    assert log["summary"]["ok_mirror"] == 3 and log["summary"]["ok_wikimedia"] == 3
    # Wikimedia 的步調被 429 一路加倍（15→30→60→120），而鏡像的時鐘還是 1 s
    assert log["pace_s"] == 120.0 and log["mirror_pace_s"] == 1.0
    mirror_waits = [w for w in nap.waits if 0.5 < w <= 1.0]
    assert len(mirror_waits) == 5                     # 第 1 張是這趟第一個請求，不必等


def test_the_tail_probe_window_is_exactly_the_documented_size(tmp_path: Path) -> None:
    """結尾標記的搜尋視窗＝`TAIL_PROBE_BYTES`（4 KB），兩端都要守。

    窗太小（原本的 32 bytes）→ 合法的 JPEG 被永久判成截斷，形成「判截斷 → 不落地 →
    下一趟磁碟上沒有 → 再抓一次」的閉環，每趟白打一個請求、理由還指向不存在的原因。
    窗無限大 → 只要檔案裡任何一處出現 FFD9 就算抓完，真正的截斷檔會被當成完整檔落地，
    而截斷的 JPEG 前 3 個 byte 與完整檔一模一樣，要到分析階段才會發現。
    """
    spec = F.JPEG_MAGIC + b"\x00" * 30_000 + F.JPEG_EOI + b"\x00" * 200
    assert F.image_bytes_complete(spec)               # 題目給的那一個形狀
    edge = F.JPEG_MAGIC + b"\x00" * 30_000 + F.JPEG_EOI + b"\x00" * (F.TAIL_PROBE_BYTES - 2)
    over = F.JPEG_MAGIC + b"\x00" * 30_000 + F.JPEG_EOI + b"\x00" * F.TAIL_PROBE_BYTES
    assert F.image_bytes_complete(edge)               # 剛好在窗內（EOI 的 2 bytes 也算）
    assert not F.image_bytes_complete(over)           # 超出一個 byte 就不算
    # 窗的**上界**要用絕對值守，否則「把 TAIL_PROBE_BYTES 開大一點」這個看似無害的改動
    # 會讓下面這種真截斷檔通過：FFD9 只是影像資料裡剛好出現的兩個 byte，離檔尾 300 KB。
    assert F.TAIL_PROBE_BYTES <= 64 * 1024
    stray = F.JPEG_MAGIC + b"\x00" * 1000 + F.JPEG_EOI + b"\x00" * 300_000
    assert not F.image_bytes_complete(stray)
    # 磁碟那一端（續傳判斷）與位元組那一端要給同一個答案，否則就是抓到了卻每趟重抓
    for name, blob, want in (("c1.jpg", spec, True), ("c2.jpg", edge, True),
                             ("c3.jpg", over, False)):
        p = tmp_path / name
        p.write_bytes(blob)
        assert F.existing_file_ok(str(p)) is want, name


def test_a_refused_pace_does_not_even_create_the_output_directory(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """`--pace 3`（3600÷3 = 1200 次/小時，是公布上限的 2.4 倍）要 rc=2、零請求——
    而且**什麼都不要留下**：連輸出目錄都不建、log 也不寫。

    理由不是潔癖：拒跑那一趟如果先建了目錄、寫了一份空的 `fetch_log.json`，
    下一趟的「磁碟才是權威」與「上一趟怎麼停的」兩個判斷都會讀到一份沒有內容的紀錄。
    """
    out = tmp_path / "out"
    net = FakeNet()
    rc = F.main(["--manifest", _manifest(tmp_path, [_cand(1)]), "--dir", str(out),
                 "--order", "manifest", "--pace", "3"], fetch=net, sleep=_boom)
    err = capsys.readouterr().err
    assert rc == 2 and net.urls == []
    assert not out.exists()
    assert str(F.SAFE_PACE_FLOOR_S) in err and "bot-traffic@wikimedia.org" in err


def test_a_403_block_brakes_the_next_run_with_no_429_in_the_log(
        tmp_path: Path, capsys: pytest.CaptureFixture) -> None:
    """跨趟煞車**不可以只靠 429 預算**——403／451 那一路一次 429 都沒有。

    反向很具體：CDN 的 requestctl 規則也會用 403 擋人（腳本自己這樣寫的），那種中止
    `events_429` 是空的，所以「最近 24 小時吃了幾次 429」那道閘一次都不會擋。真正擋住的是
    黏性的 `wikimedia_block`。把那一格拿掉（或讓 `--mirror-only` 把它磨掉）在 429 的情境下
    測不出來——第二道閘會把它蓋過去——所以這一條刻意挑 403，並且**斷言 log 裡零筆 429**。
    """
    m = _manifest(tmp_path, [_cand(i) for i in range(1, 6)])
    out = tmp_path / "out"

    net = FakeNet(script=[_http_error(403)])
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=net, sleep=Sleeper()) == 1
    log = _log_of(out)
    assert len(net.urls) == 1
    assert log["events_429"] == []                      # ← 429 預算在這一路完全使不上力
    assert F.recent_429_count(log["events_429"]) == 0
    assert log["aborted_kind"] == "blocked"
    assert log["wikimedia_block"]["kind"] == "blocked"

    again = FakeNet()                                   # 重跑同一行：拒跑、零請求、零 sleep
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=again, sleep=_boom) == 2
    assert again.urls == []
    assert "--new-network" in capsys.readouterr().err

    # `--mirror-only` 跑得動，但**不准把那一格磨掉**（它會把 aborted/aborted_kind 覆寫成 None）
    mir = FakeMirrorNet(hits={1, 2})
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--mirror-only"],
                  fetch=_boom, sleep=Sleeper(), mirror_fetch=mir) == 0
    after = _log_of(out)
    assert after["aborted_kind"] is None                 # 這一趟自己沒有中止
    assert after["wikimedia_block"]["kind"] == "blocked"  # 封鎖仍在
    assert after["events_429"] == []                     # 仍然沒有任何 429 可以當第二道閘

    still = FakeNet()
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest"],
                  fetch=still, sleep=_boom) == 2
    assert still.urls == []

    freed = FakeNet()                                    # --new-network 是唯一的解除方式
    assert F.main(["--manifest", m, "--dir", str(out), "--order", "manifest", "--new-network"],
                  fetch=freed, sleep=Sleeper()) == 0
    assert _pageids(freed.urls) == [3, 4, 5]             # 鏡像已經給了 1、2
    assert _log_of(out)["wikimedia_block"] is None
