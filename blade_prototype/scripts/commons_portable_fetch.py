#!/usr/bin/env python3
"""可攜版 Commons 縮圖抓取器——拿到**另一個網路**上跑，把剩下的整機照抓回來。

為什麼會有這個腳本
------------------
`scripts/fetch_commons_turbines.py` 的 `download` 子命令在**本機（容器）出口 IP 上已經抓不動了**：
2026-09-19 首次 429（Retry-After 300 s）→ 09-20 停手 9 小時後單發試探仍 429 且 Retry-After 升到 600 s
→ 09-26 完全靜默 6 天後單發試探**仍是 429、Retry-After 仍是 600**。懲罰沒有隨時間衰減，這不符合
「滾動窗計數器」的行為，只符合「CDN edge 上有一條持久規則（requestctl 風格，比對 IP/CIDR）」。
同一時間 `commons.wikimedia.org/w/api.php` 的 Retry-After 只有 32 s——**限流是按服務分開的**，
圖片 CDN 是持續性封鎖，API 只是每分鐘滾動窗。結論：**這個 IP 不要再試了**。

所以這個檔案是一個**零相依、可搬走**的下載器：純標準函式庫、不 import 這個 repo 的任何東西、
不需要 pip install、輸入只有版控裡的 `data/commons_turbines_manifest.json`（git clone 就有）。
把它連同 manifest 帶到自己的筆電／VPS／Colab（另一個出口 IP）上跑，抓完再把整個目錄帶回來。

**換網路重跑是合規的，輪換 IP／代理池／改 UA 不是。** 前者是另一個合法客戶端正常使用服務；後者是
「spreading requests over multiple user agents to hide excessive use by a single operator」，
Wikimedia API Usage Guidelines 明文禁止。這個腳本刻意**不提供**換 UA 與並發的開關。
若新網路上也被擋，正確的下一步是寄信給 **bot-traffic@wikimedia.org**（不是 noc@），
說明量級（313 張 CC/PD 授權照片、一次性、非商業、非 AI 訓練語料）與已遵守的四件事。

怎麼用（完整的一行指令）
------------------------
    # 在新網路的機器上：
    git clone https://github.com/dofliu/InduSpect.git && cd InduSpect/blade_prototype
    python3 scripts/commons_portable_fetch.py \
        --manifest data/commons_turbines_manifest.json \
        --dir ~/commons_turbines --thumb-width 1280 --pace 15

    # 先看要抓什麼（不發任何請求）：
    python3 scripts/commons_portable_fetch.py --dry-run --limit 5

    # 在**已經被封的這台機器**上也能先拿一批（完全不碰 Wikimedia，見下一節）：
    python3 scripts/commons_portable_fetch.py --mirror-only --dir ~/commons_turbines

    # 抓完之後不碰網路驗一次完整性（對 fetch_log.json 逐筆重算 sha256）：
    python3 scripts/commons_portable_fetch.py --dir ~/commons_turbines --verify

**待抓清單以磁碟實際狀態為準**：manifest 的 `file` 欄位只是「原機器上曾經抓到過」的紀錄，
而那 86 個檔案已隨 scratchpad 清空消失。所以上面那一行在空目錄上跑是完整的 **313 張**
（313 × 15 s ≈ 78 分鐘），不是 227 張；已經在磁碟上、而且通過完整性檢查（magic bytes +
結尾標記 + 大小）的檔案才會被跳過。中斷後重跑同一行就是續傳，不必加任何旗標
（`--limit`／`--per-model` 分批跑也一樣，名額是從**還沒抓到的**那些裡切；在這個目錄裡
已經連續失敗 ≥2 次的會被排到清單尾端，不佔名額）。

**唯一的例外是「上一趟因為 429／被擋而中止」**：那種情況下重跑同一行會被**拒絕**（rc=2），
因為在同一個網路上反覆試探正是把懲罰從 300 墊到 600 的那個形狀。換到另一個出口 IP 之後，
在同一行指令加 `--new-network` 才會續傳。429 預算本身也是**跨趟**的——起算值是這個目錄
最近 24 小時內已經吃掉的 429 次數，不是 0。

鏡像這條路（預設就會先走）——`ftpmirror.your.org`
--------------------------------------------------
Meta 的官方 mirror 清單上唯一帶 raw images 的鏡像。它**不是 Wikimedia 的 IP**，
不受這個封鎖影響、也沒有 429，所以預設的順序是「**先問鏡像、404 才回退到 Wikimedia 縮圖**」。

    https://ftpmirror.your.org/pub/wikimedia/images/wikipedia/commons/<path>

`<path>` 就是 manifest 候選的 `url` 欄位裡 `/commons/` 之後的那一段（原樣保留 percent-encoding，
實測 `b/b5/Windkraftanlage_Gr%C3%BCner_Heiner.jpg` 直接命中、沒有任何重導向）。

**它的邊界是 2013 年 3 月**：媒體檔的鏡像凍結在那個時間點，之後上傳到 Commons 的檔案一律 404。
實測 313 張 selected 裡 **66 張**拿得到（227 張未抓的裡 50 張、86 張遺失的裡 16 張），
其餘 247 張只能走 Wikimedia。換算下來，光是開著鏡像就把對 Wikimedia 的請求量砍掉約 21%。

    # 這台機器（IP 已被封）唯一跑得動的模式：只抓鏡像拿得到的，一個請求都不會打到 Wikimedia
    python3 scripts/commons_portable_fetch.py --mirror-only --dir ~/commons_turbines

三件要知道的事：
  * 鏡像給的是**原圖**不是縮圖（實測 1.5–5.8 MB／張，66 張約 270 MB），而原圖的 EXIF 完整，
    對 `real_pose_validation.py` 這條管線反而更好（它只縮不放）。所以說明檔裡
    「**絕不抓原圖**」那一條**只適用於 Wikimedia 那條路徑**——那條規則的理由是
    「原圖是多 MB、而且原圖同樣在 429 名單上」，兩個理由在鏡像上都不成立
    （鏡像上**只有**原圖，沒有縮圖可選；鏡像不限流）。
  * 鏡像的請求**不計入全域 429 預算**，步調也另外算（`--mirror-pace`，預設 1.0 s；
    Wikimedia 那邊維持 `--pace` 15 s）。理由同上：那份預算保護的是使用者的出口 IP
    在 Wikimedia 眼中的處境，而鏡像不是 Wikimedia。
  * `--mirror-only` **不會**清掉「這個目錄上一趟被 Wikimedia 擋過」這件事（`wikimedia_block`），
    也不受它阻擋——它本來就不碰 Wikimedia。要解除那個封鎖仍然只有 `--new-network` 一條路。

旗標：`--mirror-only`（只走鏡像）、`--no-mirror`（跳過鏡像、行為回到舊版）、
`--mirror-base`（換一個鏡像；**指向 wikimedia.org 會被拒絕**）、`--mirror-pace`。
`--dry-run` 會印「鏡像預計可得 N 張／Wikimedia 需要 M 張」（第一次是用實測命中率估的，
跑過一趟鏡像之後就是精確值——每一張的命中／404 都記在 log 的 `mirror_status`）。

被擋住的時候
------------
腳本有**全域且跨趟的 429 預算**：收到 429 就把步調加倍（上限 300 s）並印出新步調與剩餘 ETA，
最近 24 小時累計 5 次就中止；同一張連兩次 429、或 403／451（CDN 的 requestctl 規則也會用 403
擋人）一律立刻中止整趟。連續 10 張沒有 429 會把步調減半回 `--pace` 的原值（只加倍不衰減的話，
一次暫時性的 429 會把 78 分鐘的活變成好幾小時）。被限流中止之後，**同一個網路上重跑會被拒絕**，
`--new-network` 是唯一的解除方式。中止時 `fetch_log.json` 的 `events_429` 留著每一次 429 的
時刻／網址／Retry-After／實際等待秒數——那就是要寄給 **bot-traffic@wikimedia.org** 的實證。
**不要**把 --pace 改小（低於 7.2 s 會被拒跑：那是未認證每 IP 每小時 500 次換算出來的地板）、
也不要重跑硬闖。
若縮圖主機 thumb.wikimedia.org 在你的網路上不通（DNS／防火牆擋掉），
`--thumb-host upload.wikimedia.org` 是唯一的逃生口（兩個 host 指向同一組縮圖）。

抓完之後怎麼帶回去
------------------
    tar czf commons_turbines.tar.gz --exclude='*.part' -C ~/commons_turbines .   # 檔名就是 c<pageid>.jpg
    # 把 commons_turbines.tar.gz（含 fetch_log.json）複製回 InduSpect 容器，解到 scratchpad：
    mkdir -p <scratch>/commons_turbines && tar xzf commons_turbines.tar.gz -C <scratch>/commons_turbines
    python3 scripts/real_pose_validation.py run --manifest data/commons_turbines_manifest.json \
        --dir <scratch>/commons_turbines --out data/commons_pose_results.json
    python3 scripts/real_pose_validation.py report   # 重新產 REAL_POSE_VALIDATION.md（不可手改）

**影像不進版控**（授權 CC BY／BY-SA，出處逐張留在 manifest 與結果檔裡就夠）。
manifest 的 `file` 欄位不補也沒關係——`real_pose_validation.py` 找不到 `file` 時會 fallback 到
`c<pageid>.jpg`，而這正是本腳本的命名規則。`fetch_log.json` 帶回去是用來**驗證完整性**
（每張的成功／失敗／原因／位元組數／sha256；`--verify` 會對著磁碟重算一遍）
與**回報給 bot-traffic@ 的 429 實證**。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# 常數——這一段全部是從 scripts/fetch_commons_turbines.py 抄過來的實測結論，不要憑感覺改
# ---------------------------------------------------------------------------

# Wikimedia User-Agent policy 要求可辨識的 UA 帶聯絡方式；預設的 python-urllib UA 會被直接擋
# （配額差 20 倍：未識別請求 10 req/min、帶 UA 的 bot 200 req/min）。**原樣沿用 repo 的字串**，
# 不要為了「不外洩 email」把聯絡資訊拿掉——那反而會被歸進未識別流量。
# （政策建議函式庫名帶版本，例如 `Python-urllib/3.11`；這裡刻意維持與 repo 一致的字串。）
UA = "InduSpectBladeResearch/0.1 (https://github.com/dofliu/InduSpect; moredof@gmail.com) python-urllib"

# T413570（2026-01）：沒有 Referer 的縮圖請求會被 CDN 當成 bot traffic 而很快 429。該 bug 已修掉，
# 所以現在非必要，但成本為零、且讓客戶端長得更像正常用戶。
REFERER = "https://commons.wikimedia.org/"

# Wikimedia 只對「常用縮圖寬度」預先渲染並快取（Varnish 直接命中）；其他寬度每一張都要現場 render，
# 連續幾張就 429 並要求改用 https://www.mediawiki.org/wiki/Common_thumbnail_sizes 列出的尺寸。
STANDARD_THUMB_WIDTHS = (320, 640, 800, 1024, 1280, 1600, 1920, 2560)

# 下限必須 ≥ 1280：驗證管線的 `_resize_to(img, MAX_SIDE=1024)` **只縮不放**，而 Wikimedia 的
# `<N>px-` 指定的是**寬度**——橫幅照長邊 = 寬 = N，直幅照長邊 = 高 > N。1280 在兩種方向都保證
# 長邊 ≥ 1024（與 App 同尺度）。1920 也可以（既有 86 張多半是這個），只是流量多一倍——
# 而且 selected 裡有 4 張原圖比 1920 還窄，那幾張會被 `clamp_thumb_width` 自動夾到 1600
# （要求的寬度 ≥ 原圖寬度時，縮圖處理器不放大而是把請求導回原圖）。
MIN_THUMB_WIDTH = 1280
DEFAULT_THUMB_WIDTH = 1280

# API 回的 thumb_url 在這個 manifest 裡用的是 thumb.wikimedia.org（166/227），
# 原圖網址則是 upload.wikimedia.org。自行推導縮圖時沿用前者。
DERIVED_THUMB_HOST = "thumb.wikimedia.org"

# ---------------------------------------------------------------------------
# 鏡像（ftpmirror.your.org）——**不是 Wikimedia 的 IP**，所以不受這個封鎖影響
# ---------------------------------------------------------------------------

# Meta 的官方 mirror 清單上唯一帶 raw images 的鏡像。路徑規則實測驗證過（16 次 HEAD）：
# manifest 的 `url` 去掉 query、取 `/commons/` 之後那一段，原樣（含 percent-encoding）接在這後面。
MIRROR_BASE = "https://ftpmirror.your.org/pub/wikimedia/images/wikipedia/commons"

# **媒體檔的鏡像凍結在 2013 年 3 月**，之後上傳到 Commons 的一律 404。
# 實測 313 張 selected 裡 66 張拿得到（227 未抓的裡 50、86 遺失的裡 16）。
MIRROR_FREEZE = "2013-03"
MIRROR_HIT_RATE = 66 / 313          # 只用來在 --dry-run 上估「預計可得幾張」，不影響任何判定

# 鏡像不限流，所以步調可以比 Wikimedia 快；但仍然是別人的頻寬，地板 1.0 s＝Robot policy 的官方地板。
DEFAULT_MIRROR_PACE_S = 1.0
MIRROR_PACE_FLOOR_S = 1.0

# 鏡像給的是**原圖**（實測 1.5–5.8 MB），所以 8 MB 的縮圖上限套不上去。
# 這個上限只是「別把整台機器的記憶體吃光」的保險，不是「不要抓原圖」——
# 鏡像上只有原圖，沒有縮圖可選。
MAX_MIRROR_RESPONSE_BYTES = 64 * 1024 * 1024

# 鏡像連續這麼多次非 404 的失敗就關掉鏡像、這一趟剩下的全走 Wikimedia
# （多半是這個網路連不到鏡像；每張各付一個失敗請求是白花的）。404 不算——那是預期的答案。
MIRROR_MAX_FAILURES = 3

# 政策 agent 的建議值：Robot policy 的官方地板是「delay ≥ 1 s、並發 ≤ 1」，15 s 是它的 15 倍；
# 未認證每 IP 每小時 500 次的公布上限換算是 7.2 s／次，15 s → 240 次/小時，留了一半餘裕。
# 313 張 × 15 s ≈ 78 分鐘。**並發永遠是 1，沒有開關。**
DEFAULT_PACE_S = 15.0
# **`--pace` 的硬地板，不是建議值**：上一行那個推導（500 次/小時 → 7.2 s／次）是 Wikimedia
# 公布的未認證上限，低於它就是明知故犯地超速。這支腳本存在的唯一理由是「不要害使用者的新 IP 也被封」，
# 所以自己算出來的地板要當閘門用——全域 429 預算會在 5 次之後停手沒錯，但那 5 次已經打在他的 IP 上了。
# 想更快只有一條合規的路：用認證帳號，或寄信給 bot-traffic@wikimedia.org 談量級。
SAFE_PACE_FLOOR_S = 7.2
DEFAULT_TIMEOUT_S = 120.0

# 沒有 Retry-After 時的起跳值；官方指示是「至少 5 秒並指數退避」。
BACKOFF_NO_HEADER_S = 90.0
# 上限**只**用來擋解析不出來／荒謬的值。伺服器明確給了數字就全額等——
# 既有腳本把 cap 設成 300 會把 Retry-After: 600 夾成 300、提早一半時間重試，
# 那正是 Robot policy 禁止的行為，也很可能是懲罰從 300 被墊到 600 的原因。
BACKOFF_CAP_S = 3600.0
# Robot policy：收到 5xx 要暫停至少 15 分鐘。
SERVER_ERROR_PAUSE_S = 900.0

# 「已經有這個檔」的門檻。**光看大小會把錯誤頁當成有效檔案**（429/503 的 HTML 可能 > 20 KB），
# 所以一律加驗影像 magic bytes；而只驗開頭又會把**截斷檔**當成完整檔，所以再加驗結尾標記。
MIN_VALID_BYTES = 20_000
JPEG_MAGIC = b"\xff\xd8\xff"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
JPEG_EOI = b"\xff\xd9"
PNG_IEND = b"IEND\xaeB`\x82"
# 結尾標記容許後面有填充，所以從**尾端往前找**而不是硬性要求 `endswith`。4 KB 足夠涵蓋任何
# 合理的尾端 metadata，又遠小於任何一張真影像；原本的 32 bytes 會把「FFD9 之後還有 200 bytes」
# 這種合法 JPEG 永久判成截斷，而且形成閉環（判截斷 → 不落地 → 下一趟磁碟上沒有 → 再抓一次）。
TAIL_PROBE_BYTES = 4096

# 單一回應的上限。1280 px 的縮圖不可能到這個量級；會超過的只有「被導回原圖」這一種情況。
MAX_RESPONSE_BYTES = 8 * 1024 * 1024

LOG_NAME = "fetch_log.json"

# 連續這麼多次非 429 的網路失敗就中止整趟（多半是新網路本身斷了，繼續跑只是空轉）
MAX_CONSECUTIVE_FAILURES = 5

# CDN 的 requestctl 規則不只回 429，也會回 403；451 是法務層的封鎖。兩者都視同被擋、立刻中止。
BLOCKED_STATUS = (403, 451)

# **全域 429 預算**。只防「連續兩次 429」是不夠的：標準的限流形狀是「每張都先 429、重試就過」，
# 那個形狀下每張各自重試一次都會成功，整趟會 rc=0 跑完並吃掉幾百次 429——那正是把單次限流
# 養成持久封鎖（Retry-After 300 → 600）的路徑。累計到這個數字就中止整趟。
MAX_TOTAL_429 = 5
# 收到 429 就把步調加倍的上限。伺服器說太快就真的變慢，但不必慢到整趟卡死。
PACE_MAX_S = 300.0
# **429 預算的回看窗**。單趟預算不夠：中止之後重跑同一行（這支腳本的一般 UX 就是這樣）
# 會從 0 起算、又吃滿 5 次——那正是「反覆試探」的形狀，也是把懲罰從 300 墊到 600 的那條路徑。
# 起算值改成「最近這段時間內已經吃掉的 429 次數」，短時間內連續重跑吃的是同一份預算。
RECENT_429_WINDOW_H = 24.0
# 連續這麼多張沒有 429 就把步調減半回去（下限是使用者給的 `--pace`）。
# 只加倍不衰減的話，一次暫時性的 429 會把 78 分鐘的活變成好幾小時，使用者多半會以為當掉而 Ctrl-C。
PACE_RECOVER_AFTER = 10
# 這個目錄裡已經連續失敗幾次就排到清單尾端（不是刪掉——還是給最後一次機會）。
# 反向：永久失敗的圖會把 `--limit`／`--per-model` 的名額整碗佔住，續傳變成對著 404 空轉。
FAIL_STREAK_DEMOTE = 2

# 失敗的分類。**中止訊息不能照 `http_status` 推導**：寫檔失敗那一路的 http_status 是 200
# （伺服器沒問題，是這台機器的磁碟滿了），照它分會把 ENOSPC 說成「網路中斷或 CDN 擋人」，
# 並把使用者指向一個那些紀錄根本沒有的欄位。
FAILURE_KIND_LABEL = {
    "http": "HTTP 錯誤",
    "network": "連線失敗：DNS、逾時或斷線",
    "content": "回應不是合格的縮圖：錯誤頁、被導回原圖或截斷",
    "local": "磁碟或權限",
    "manifest": "縮圖網址推不出來",
}


# ---------------------------------------------------------------------------
# 純函式——這幾個都測得到，不碰網路
# ---------------------------------------------------------------------------

def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def retry_after_seconds(header: str | None,
                        default: float = BACKOFF_NO_HEADER_S,
                        cap: float = BACKOFF_CAP_S) -> float:
    """Retry-After 可能是秒數或 HTTP 日期。

    與 `fetch_commons_turbines.retry_after_seconds` 的差別只有一個、而且是刻意的：
    **cap 大到不會夾掉伺服器真的給的值**（實測 upload.wikimedia.org 給 600）。
    夾上限只該用在讀不出來／荒謬的值上，不該用在伺服器明講的數字上。
    """
    if header:
        try:
            return min(max(float(header), 1.0), cap)
        except ValueError:
            pass
        try:
            from email.utils import parsedate_to_datetime
            delta = (parsedate_to_datetime(header) - datetime.now(timezone.utc)).total_seconds()
            return min(max(delta, 1.0), cap)
        except Exception:  # noqa: BLE001
            return default
    return default


def parse_utc(stamp: str | None) -> datetime | None:
    """讀回 `utcnow()` 寫下的時刻。讀不出來回 None（舊 log／被編輯過的 log 不該讓整支掛掉）。"""
    if not stamp:
        return None
    try:
        return datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None


def recent_429_count(events: list[dict] | None,
                     now: datetime | None = None,
                     window_h: float = RECENT_429_WINDOW_H) -> int:
    """**這一趟的 429 預算從幾起算**＝最近 `window_h` 小時內、且不屬於上一個網路的 429 筆數。

    單趟預算是不夠的：中止之後重跑同一行會從 0 起算、又吃滿 5 次，而畫面上一個字的提醒都沒有。
    `--new-network` 會把舊事件標成 `network_generation: "previous"`——那是**唯一**的歸零方式，
    因為換了出口 IP 之後舊 IP 的配額確實與這一趟無關。讀不出時刻的（舊 log）**算進來**，
    寧可保守：預算少一點只是慢一點，預算多一點是讓使用者的新 IP 被封。
    """
    now = now or datetime.now(timezone.utc)
    n = 0
    for e in events or []:
        if not isinstance(e, dict) or e.get("network_generation") == "previous":
            continue
        at = parse_utc(e.get("at"))
        if at is None or (now - at).total_seconds() <= window_h * 3600.0:
            n += 1
    return n


def classify_abort(message: str | None) -> str | None:
    """把中止原因歸成一類，給**跨趟煞車**判斷用。舊 log 沒有 `aborted_kind` 欄位時的回退路徑。

    只有 `throttled`／`blocked` 兩類會讓下一趟拒跑——那兩類的共同點是「伺服器已經對這個 IP
    說不」，重跑就是試探。`failures`（網路斷了／磁碟滿）與 `interrupt`（Ctrl-C）重跑是對的。
    **不要拿中止訊息的字面去比對**：「連續 N 張失敗（網路中斷，或 CDN 改用 403/404 擋人）」
    裡也有 CDN 兩個字，字面比對會把單純的斷網誤判成被擋。
    """
    if not message:
        return None
    if "429" in message:
        return "throttled"
    if "CDN 擋住" in message or "CDN 直接拒絕" in message:
        return "blocked"
    if "中斷" in message and "Ctrl-C" in message:
        return "interrupt"
    if "磁碟錯誤" in message:
        return "disk"
    return "failures"


def wikimedia_block_of(log: dict | None) -> dict | None:
    """這個目錄上一次被 **Wikimedia** 擋（429／403／451）的黏性紀錄，沒有就回 None。

    為什麼不直接看 `aborted_kind`：`--mirror-only` 現在可以在**已經被擋的機器**上正常跑完，
    而跑完的那一趟會把 `aborted`／`aborted_kind` 覆寫成 None——於是跨趟煞車被一趟
    「根本沒碰 Wikimedia 的抓取」無聲解除，下一趟就直接打回那個已經被封的 IP。
    所以封鎖狀態要**自己有一格**、只由 `--new-network` 清除。
    舊 log（沒有這一欄）用 `aborted_kind`／`classify_abort` 回推，不然升級的人會少一道煞車。
    """
    log = log or {}
    got = log.get("wikimedia_block")
    if isinstance(got, dict) and got.get("kind") in ("throttled", "blocked"):
        return got
    kind = log.get("aborted_kind") or classify_abort(log.get("aborted"))
    if kind in ("throttled", "blocked"):
        return {"kind": kind, "message": log.get("aborted"), "at": log.get("updated")}
    return None


def _strip_query(url: str) -> str:
    """去掉 API 加上的 `?utm_*` 追蹤參數；縮圖內容與它們無關，拿掉比較乾淨也少一個 cache 變因。"""
    parts = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))


def standard_thumb_url(thumb_url: str | None, width: int = DEFAULT_THUMB_WIDTH) -> str | None:
    """把 API 回的 `<N>px-` 縮圖網址改成常用寬度。不是縮圖網址（原圖）就原樣回傳。

    行為與 `fetch_commons_turbines.standard_thumb_url` 逐條相同（非常用寬度 raise、原圖網址 no-op），
    因為那兩個行為在 `tests/test_fetch_commons.py` 裡被釘住了。**原圖網址的 no-op 是陷阱**：
    manifest 裡有 61 張的 `thumb_url` 其實是原圖（API 在不需要縮放時直接回原檔），照抄這個函式
    會去抓多 MB 的原圖，而原圖同樣在 429 名單上。那 61 張要走 `derive_thumb_url()`。
    """
    if not thumb_url:
        return None
    if width not in STANDARD_THUMB_WIDTHS:
        raise ValueError(f"{width} 不在 Wikimedia 常用縮圖寬度表 {STANDARD_THUMB_WIDTHS} 裡")
    return re.sub(r"/(\d+)px-", f"/{width}px-", thumb_url, count=1)


_ORIGINAL_PATH_RE = re.compile(
    r"^/wikipedia/(?P<project>[^/]+)/(?P<a>[0-9a-fA-F])/(?P<ab>[0-9a-fA-F]{2})/(?P<name>[^/]+)$")


def derive_thumb_url(file_url: str | None,
                     width: int = DEFAULT_THUMB_WIDTH,
                     host: str = DERIVED_THUMB_HOST) -> str | None:
    """從**原圖網址**推出縮圖網址：`/wikipedia/commons/<a>/<ab>/<NAME>` → `.../thumb/<a>/<ab>/<NAME>/<W>px-<NAME>`。

    這是新寫的函式而不是改 `standard_thumb_url`——後者對原圖網址原樣回傳的行為被既有測試釘住。
    推不出來（網址形狀不合）回 None，呼叫端會把那張記成失敗而不是去抓原圖。
    """
    if not file_url:
        return None
    if width not in STANDARD_THUMB_WIDTHS:
        raise ValueError(f"{width} 不在 Wikimedia 常用縮圖寬度表 {STANDARD_THUMB_WIDTHS} 裡")
    parts = urllib.parse.urlsplit(_strip_query(file_url))
    if "/thumb/" in parts.path:            # 本來就是縮圖路徑，交給 standard_thumb_url
        return standard_thumb_url(urllib.parse.urlunsplit(parts), width)
    m = _ORIGINAL_PATH_RE.match(parts.path)
    if not m:
        return None
    name = m.group("name")
    # 非點陣格式（svg/tif…）的縮圖檔名要補 .jpg；目前 227 張全是 jpg，這條是防禦性的。
    thumb_name = name if name.lower().endswith((".jpg", ".jpeg", ".png")) else name + ".jpg"
    path = f"/wikipedia/{m.group('project')}/thumb/{m.group('a')}/{m.group('ab')}/{name}/{width}px-{thumb_name}"
    return urllib.parse.urlunsplit((parts.scheme or "https", host or parts.netloc, path, "", ""))


def clamp_thumb_width(width: int, source_width: int | None) -> int:
    """把要求的縮圖寬度夾到「不超過原圖寬度」——**這是「絕不抓原圖」的另一半**。

    MediaWiki 的縮圖處理器不做放大：要求的寬度 ≥ 原圖寬度時，不是 404 就是導回原圖
    （多 MB，而且原圖同樣在 429 名單上）。manifest 的 313 張 selected 裡有 4 張寬度 < 1920
    （1704／1704／1726／1872）、49 張 < 2560，而說明檔明寫「1920 也可以」——照著做就會踩到。
    夾到「不超過原圖寬度的最大常用寬度」，下限仍是 MIN_THUMB_WIDTH（驗證管線只縮不放）。
    """
    if not source_width or source_width <= 0:
        return width
    usable = [w for w in STANDARD_THUMB_WIDTHS if MIN_THUMB_WIDTH <= w <= source_width]
    return min(width, max(usable) if usable else MIN_THUMB_WIDTH)


def thumb_width_of(url: str | None) -> int:
    """從縮圖網址讀回實際要求的寬度（寫進 log 用）。不是縮圖網址回 0。"""
    m = re.search(r"/(\d+)px-", url or "")
    return int(m.group(1)) if m else 0


def thumb_url_for(cand: dict, width: int = DEFAULT_THUMB_WIDTH,
                  host_override: str = "") -> tuple[str | None, str]:
    """決定這張候選要抓哪個網址。回 `(url, how)`；抓不出來時 url 是 None、how 是拒收原因。

    規則：`thumb_url` 已經是 `<N>px-` 形狀 → 改寫成常用寬度；否則（原圖網址）→ 從 `url` 自行推導。
    **任何情況都不抓原圖**——原圖是多 MB 而且同樣在 429 名單上。要求的寬度會先依候選自己的
    `width` 夾小（見 `clamp_thumb_width`），因為「寬度 ≥ 原圖寬度」同樣會拿到原圖。
    """
    width = clamp_thumb_width(width, cand.get("width"))
    thumb = cand.get("thumb_url")
    if thumb and re.search(r"/(\d+)px-", thumb):
        url = standard_thumb_url(_strip_query(thumb), width)
        how = "rewritten"
    else:
        url = derive_thumb_url(cand.get("url"), width,
                               host_override or DERIVED_THUMB_HOST)
        how = "derived"
    if not url:
        return None, "no_thumb_url"
    if host_override:
        p = urllib.parse.urlsplit(url)
        url = urllib.parse.urlunsplit((p.scheme, host_override, p.path, "", ""))
    return url, how


def is_wikimedia_host(url: str | None) -> bool:
    """這個網址是不是打到 Wikimedia 自己的機器上。

    `--mirror-base` 的硬閘門用它：把 base 指回 `upload.wikimedia.org` 會讓「鏡像不計入 429 預算、
    步調 1 s」這兩條直接變成對著已經封鎖我們的 CDN 每秒敲一次——那是這支腳本存在理由的反面。
    """
    host = urllib.parse.urlsplit(url or "").netloc.lower().split("@")[-1].split(":")[0]
    return host == "wikimedia.org" or host.endswith(".wikimedia.org")


def commons_path_of(file_url: str | None) -> str | None:
    """從原圖網址取出 `/commons/` **之後**那一段（原樣保留 percent-encoding）。

    例：`https://upload.wikimedia.org/wikipedia/commons/a/a9/Foo.jpg?utm_source=…` → `a/a9/Foo.jpg`。
    實測鏡像吃的就是這一段、原樣送出即命中（`b/b5/Windkraftanlage_Gr%C3%BCner_Heiner.jpg` → 200）。
    **不要先 unquote 再 quote**：那會把 `%2C` 這種「本來就在檔名裡的逗號」改寫成不同的字串。
    推不出來（不是 commons 路徑、或路徑空的）回 None，呼叫端直接跳過鏡像走 Wikimedia。
    """
    path = urllib.parse.urlsplit(_strip_query(file_url or "")).path
    marker = "/commons/"
    i = path.find(marker)
    if i < 0:
        return None
    rest = path[i + len(marker):].lstrip("/")
    # `/thumb/…` 是縮圖路徑，鏡像上沒有（它鏡的是原始 media 樹）；`..` 是路徑穿越的防禦。
    if not rest or rest.startswith("thumb/") or ".." in rest.split("/"):
        return None
    return rest


def mirror_url_for(cand: dict, base: str = MIRROR_BASE) -> str | None:
    """這張候選在鏡像上的網址。推不出來回 None。

    **一律用 `url`（原圖網址）而不是 `thumb_url`**：鏡像只鏡原始 media 樹，沒有縮圖。
    """
    rest = commons_path_of(cand.get("url"))
    if not rest:
        return None
    return f"{(base or MIRROR_BASE).rstrip('/')}/{rest}"


def mirror_outlook(plan: list[dict], log: dict | None = None,
                   hit_rate: float = MIRROR_HIT_RATE) -> dict:
    """`--dry-run` 的「鏡像預計可得 N 張／Wikimedia 需要 M 張」。**不發任何請求**。

    第一次跑的時候沒有任何依據，只能用實測命中率（66/313）估；跑過一趟鏡像之後，
    每一張的命中／404 都記在 log 的 `mirror_status`，數字就變成精確的。
    兩種來源分開印，否則使用者看到一個估出來的數字會以為它是實測的。
    """
    files = log.get("files", {}) if isinstance((log or {}).get("files"), dict) else {}
    hit = miss = unknown = 0
    for c in plan:
        st = (files.get(str(c.get("pageid"))) or {}).get("mirror_status")
        if st == "hit":
            hit += 1
        elif st == "miss":
            miss += 1
        else:
            unknown += 1
    expected = hit + int(round(unknown * hit_rate))
    return {"known_hit": hit, "known_miss": miss, "unknown": unknown,
            "expected_mirror": expected, "expected_wikimedia": max(0, len(plan) - expected)}


def drop_known_mirror_misses(plan: list[dict], log: dict | None = None) -> tuple[list[dict], int]:
    """`--mirror-only` 專用：把「上一趟已經確認鏡像上沒有」的從計畫裡拿掉。

    鏡像凍結在 2013-03，所以 404 是**永久**的（不像 Wikimedia 的失敗可能只是 DNS 沒通）。
    留著它們只會把 `--limit` 的名額佔住、每趟各白打一個註定 404 的請求。
    **只在 `--mirror-only` 下這樣做**：一般模式裡那些張本來就要走 Wikimedia，不能被拿掉。
    """
    files = log.get("files", {}) if isinstance((log or {}).get("files"), dict) else {}
    keep = [c for c in plan
            if (files.get(str(c.get("pageid"))) or {}).get("mirror_status") != "miss"]
    return keep, len(plan) - len(keep)


def candidate_filename(cand: dict) -> str:
    """檔名是**唯一的對應鍵，不可改**：`real_pose_validation.py` 找不到 manifest 的 `file` 欄位時
    就是用這個字串 fallback。固定小寫 c + pageid（不補零）+ 一律 `.jpg`（不看實際 MIME）。

    缺 pageid 丟 `ValueError` 而不是 `KeyError`：呼叫端要接得住並記錄，不是整支掛掉。
    """
    pid = cand.get("pageid")
    if pid is None:
        raise ValueError(f"候選缺 pageid，組不出檔名：{cand.get('title')!r}")
    return f"c{pid}.jpg"


def base_record(cand: dict) -> dict:
    """log 裡每一筆共用的出處欄位（授權與 page_url 是影像不進版控的前提）。"""
    return {"file": candidate_filename(cand), "title": cand.get("title"),
            "model": cand.get("model"), "page_url": cand.get("page_url"),
            "license": cand.get("license")}


def selected_candidates(doc: dict) -> list[dict]:
    """全部入選（`selected` 為真）而且**有 pageid** 的候選。

    `pageid` 是檔名與 log 的鍵，缺了就 KeyError 穿出整支腳本（連 `--dry-run` 也一樣）。
    這個腳本的前提就是「拿到別人的機器、別人的 checkout 上跑」，所以缺欄位要**記錄後繼續**，
    不是整支掛掉。被濾掉的用 stderr 點名。
    """
    sel = [c for c in doc.get("candidates", []) if c.get("selected")]
    ok = [c for c in sel if c.get("pageid") is not None]
    if len(ok) != len(sel):
        print(f"略過 {len(sel) - len(ok)} 筆沒有 pageid 的候選（manifest 壞了？它們不會被抓也不會被記錄）",
              file=sys.stderr)
    return ok


def pending_candidates(doc: dict, include_fetched: bool = False) -> list[dict]:
    """**純 manifest 視角**的待抓清單 = `selected` 為真且沒有 `file` 欄位。只給報表用。

    真正的待抓清單在 `build_plan`，依據是**磁碟實際狀態**：manifest 的 `file` 只說
    「原機器上曾經抓到過」，而那 86 個檔案已隨 scratchpad 清空消失，照它濾永遠湊不回 313 張。
    這個函式刻意不碰磁碟（`--dry-run` 要同時印出兩種視角的數字才看得出落差）。
    """
    sel = selected_candidates(doc)
    if include_fetched:
        return sel
    return [c for c in sel if not c.get("file")]


def interleave_by_model(cands: list[dict]) -> list[dict]:
    """依機型輪流取（round-robin）。

    manifest 的 candidates 已按 `(not selected, model, title)` 排序，pending 高度集中在
    Enercon E-82（77）與 E-126（42）。整批跑完的話順序無所謂；但萬一中途被擋停，
    照原順序會只拿到一兩個機型。輪流取讓「抓到一半」也保有機型多樣性。
    """
    buckets: dict[str, list[dict]] = {}
    for c in cands:
        buckets.setdefault(c.get("model") or "", []).append(c)
    out: list[dict] = []
    while buckets:
        for key in list(buckets):
            out.append(buckets[key].pop(0))
            if not buckets[key]:
                del buckets[key]
    return out


def per_model_cap(cands: list[dict], cap: int) -> list[dict]:
    """每個機型最多取 cap 張（對 **pending** 計數，不是對全部 selected）。"""
    if not cap:
        return cands
    seen: dict[str, int] = {}
    out = []
    for c in cands:
        key = c.get("model") or ""
        if seen.get(key, 0) < cap:
            out.append(c)
            seen[key] = seen.get(key, 0) + 1
    return out


def looks_like_image(blob: bytes) -> bool:
    """驗 magic bytes。光看大小不夠——Wikimedia 的 429/503 HTML 錯誤頁可能超過 20 KB，
    被當成「已抓到」跳過之後，`cv2.imread` 會回 None、驗證管線靜默跳過那張，
    最後只會看到「怎麼少了幾張」而查不出原因。"""
    return blob.startswith(JPEG_MAGIC) or blob.startswith(PNG_MAGIC)


def image_bytes_complete(blob: bytes) -> bool:
    """有沒有**抓完**——只驗開頭的 magic 會把截斷檔當成完整檔（前 3 個 byte 一模一樣）。

    JPEG 的結尾標記是 FFD9、PNG 是 IEND chunk。兩者都容許尾端有填充，所以**從尾端往前找**
    （最後 `TAIL_PROBE_BYTES` = 4 KB），而不是硬性要求 `endswith`、也不是只看最後 32 bytes——
    後者會把「FFD9 之後還有 200 bytes 尾端資料」這種合法 JPEG 永久判成截斷，而且每趟重抓一次。
    """
    if blob.startswith(JPEG_MAGIC):
        return JPEG_EOI in blob[-TAIL_PROBE_BYTES:]
    if blob.startswith(PNG_MAGIC):
        return PNG_IEND in blob[-TAIL_PROBE_BYTES:]
    return False


def existing_file_ok(path: str) -> bool:
    """續傳判斷：檔案存在、大小合理、是影像、**而且抓完了**。

    結尾標記那一關是新加的：任何 > 20 KB 的截斷 JPEG 原本都會被當成「抓好了」而永遠跳過。
    這支腳本自己用 `.part` + `os.replace` 原子落地不會產生那種檔，但既有那 86 張是舊
    `fetch_commons_turbines.cmd_download` 直接 `open(path, "wb")` 寫的（非原子），
    而跨網路 tar／scp 傳輸也可能截斷——正好是這個腳本的使用情境。
    """
    try:
        size = os.path.getsize(path)
        if size <= MIN_VALID_BYTES:
            return False
        with open(path, "rb") as fh:
            head = fh.read(8)
            fh.seek(max(0, size - TAIL_PROBE_BYTES))
            tail = fh.read(TAIL_PROBE_BYTES)
    except OSError:
        return False
    if head.startswith(JPEG_MAGIC):
        return JPEG_EOI in tail
    if head.startswith(PNG_MAGIC):
        return PNG_IEND in tail
    return False


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def human_bytes(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


# ---------------------------------------------------------------------------
# 只有這一段會碰網路
# ---------------------------------------------------------------------------

class Blocked(Exception):
    """這個出口 IP 被 CDN 擋住了——整趟中止，不是跳過這一張。

    **帶著實證走**：`events` 是這一張累積的 429／5xx 紀錄、`url` 是被擋的那個網址。
    呼叫端 `except Blocked` 時要把它們寫進 `fetch_log.json`——那正是要寄給
    bot-traffic@wikimedia.org 的東西，而唯一真正需要它的情境就是被擋的這一趟。
    """

    def __init__(self, message: str, events: list[dict] | None = None,
                 url: str | None = None, http_status: int | None = None) -> None:
        super().__init__(message)
        self.events = events or []
        self.url = url
        self.http_status = http_status


def http_get(url: str, timeout: float) -> tuple[bytes, int, str]:
    """回 `(blob, status, final_url)`。

    `final_url` 是**跟完重導向之後**的網址：縮圖處理器在要求寬度 ≥ 原圖寬度時會把請求導回原圖，
    只在組 URL 時檢查「不抓原圖」擋不住這一路。讀取一律帶上限（`MAX_RESPONSE_BYTES`），
    真的被導回多 MB 原圖也不會整個吞進記憶體。
    """
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Referer": REFERER,
        "Accept": "image/jpeg,image/png,image/*;q=0.8",
        "Accept-Encoding": "identity",   # urllib 不會自動解壓，所以不要宣告 gzip
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        blob = r.read(MAX_RESPONSE_BYTES + 1)
        final_url = r.geturl() if hasattr(r, "geturl") else url
        return blob, getattr(r, "status", 200) or 200, final_url


class _SameHostRedirect(urllib.request.HTTPRedirectHandler):
    """鏡像這條路徑上，**跨主機的重導向一律拒絕**。

    `--mirror-only` 承諾的是「一個請求都不會打到 Wikimedia」。只檢查自己組出來的網址是不夠的——
    鏡像回一個 302 指向 upload.wikimedia.org 的話，urllib 預設會乖乖跟過去，承諾當場破功
    （而且那一發請求打在使用者已經被封的 IP 上）。同主機的重導向照常跟隨。
    """

    def __init__(self, host: str) -> None:
        self.host = (host or "").lower()

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        to = urllib.parse.urlsplit(newurl).netloc.lower()
        if to != self.host:
            raise urllib.error.HTTPError(
                newurl, code, f"鏡像把請求重導向到 {to}——不跟隨（鏡像模式不得碰其他主機）",
                headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_MIRROR_OPENERS: dict[str, object] = {}


def _mirror_opener(host: str):
    op = _MIRROR_OPENERS.get(host)
    if op is None:
        op = urllib.request.build_opener(_SameHostRedirect(host))
        _MIRROR_OPENERS[host] = op
    return op


def http_get_mirror(url: str, timeout: float) -> tuple[bytes, int, str]:
    """鏡像版的 `http_get`。回 `(blob, status, final_url)`。

    與 Wikimedia 版的三個差別，每一個都有理由：
      ① **先擋 wikimedia.org**——這個函式的呼叫端不算進 429 預算、步調也只有 1 s，
         所以「網址其實指回 Wikimedia」是這支腳本最貴的一種 bug，要在發出去之前就死掉。
      ② **不帶 Referer**——那個 header 是 T413570 的 Wikimedia CDN 變通做法，對鏡像沒有意義。
      ③ **跨主機重導向不跟隨**（見 `_SameHostRedirect`）。
    UA 照樣帶（帶聯絡方式的那一個）：鏡像同樣是別人出錢的頻寬。
    """
    if is_wikimedia_host(url):
        raise ValueError(f"鏡像路徑不得指向 Wikimedia：{url}")
    host = urllib.parse.urlsplit(url).netloc
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Accept": "image/jpeg,image/png,image/*;q=0.8",
        "Accept-Encoding": "identity",
    })
    with _mirror_opener(host).open(req, timeout=timeout) as r:
        blob = r.read(MAX_MIRROR_RESPONSE_BYTES + 1)
        final_url = r.geturl() if hasattr(r, "geturl") else url
        return blob, getattr(r, "status", 200) or 200, final_url


def validate_blob(blob: bytes, status: int, final_url: str, *,
                  require_thumb: bool, max_bytes: int,
                  same_host: str | None = None) -> dict | None:
    """回應能不能落地。可以就回 None，不行就回一筆 `failed` 紀錄（不含 `events`）。

    兩條路徑共用同一套內容檢查（magic／大小／結尾標記），差別只有前兩關：
      * `require_thumb`：**「絕不抓原圖」的回應端防線，只對 Wikimedia 那條路徑成立**——
        縮圖處理器在要求寬度 ≥ 原圖寬度時會把請求導回原圖（多 MB，而且原圖同樣在 429 名單上）。
        鏡像上**只有**原圖、沒有縮圖可選，而且鏡像不限流，所以那條規則在鏡像上不適用；
        鏡像改用 `same_host` 守「不准被導到別的主機」。
      * `max_bytes`：縮圖 8 MB、鏡像原圖 64 MB，理由同上。
    """
    if require_thumb and "/thumb/" not in urllib.parse.urlsplit(final_url).path:
        return {"status": "failed",
                "reason": f"被導向非縮圖網址（{final_url}）——那是原圖，不落地",
                "http_status": status, "failure_kind": "content"}
    if same_host and urllib.parse.urlsplit(final_url).netloc.lower() != same_host.lower():
        return {"status": "failed",
                "reason": f"被導向別的主機（{final_url}）——鏡像路徑不跟隨跨主機重導向",
                "http_status": status, "failure_kind": "content"}
    if len(blob) > max_bytes:
        return {"status": "failed",
                "reason": f"回應超過 {max_bytes} B 上限（{len(blob)} B，多半是原圖）",
                "http_status": status, "failure_kind": "content"}
    if not looks_like_image(blob):
        # 錯誤頁或被中間 proxy 包裝過的東西。**不落地**，否則下次重跑會把它當成已抓到。
        return {"status": "failed",
                "reason": f"回應不是影像（前 4 bytes {blob[:4]!r}，{len(blob)} B）",
                "http_status": status, "failure_kind": "content"}
    if len(blob) <= MIN_VALID_BYTES:
        return {"status": "failed", "reason": f"檔案太小（{len(blob)} B ≤ {MIN_VALID_BYTES}）",
                "http_status": status, "failure_kind": "content"}
    if not image_bytes_complete(blob):
        return {"status": "failed",
                "reason": f"找不到結尾標記（截斷，或尾端填充超過 {TAIL_PROBE_BYTES // 1024} KB，"
                          f"{len(blob)} B）",
                "http_status": status, "failure_kind": "content"}
    return None


def write_blob(blob: bytes, path: str, status: int) -> dict | None:
    """`.part` + `os.replace` 原子落地。成功回 None，失敗回一筆 `failed` 紀錄。

    磁碟滿／唯讀／沒權限要回成失敗（會計入 consecutive_failures，連續 5 次自動停），
    不要帶著 traceback 穿出整支腳本——那樣連 fetch_log.json 都留不下來。
    """
    try:
        tmp = path + ".part"
        with open(tmp, "wb") as fh:
            fh.write(blob)
        os.replace(tmp, path)
    except OSError as e:
        return {"status": "failed", "reason": f"寫檔失敗 {type(e).__name__}: {e}",
                "http_status": status, "failure_kind": "local"}
    return None


def fetch_one(url: str, path: str, timeout: float, quiet: bool = False,
              fetch=None, sleep=None) -> dict:
    """抓一張。**429 只重試同一張一次，第二次就丟 Blocked 中止整趟。**

    CDN 的 429 說的是「這個客戶端現在不受歡迎」，不是「這個 URL 有問題」。既有腳本每張重試 3 次、
    失敗後還繼續跑下一張，313 張最多會往一個已經說不的 CDN 打掉 900 多次請求——那是把單次限流
    養成持久封鎖的最快路徑。403／451 同樣視為被擋（Wikimedia 的 requestctl 規則不只回 429），
    立刻中止而不是再往下打五張。

    丟出去的 `Blocked` **帶著 429 實證**（`events`／`url`）：那是要寄給 bot-traffic@wikimedia.org 的
    東西，而唯一真正需要它的情境就是被擋的這一趟；讓它隨例外消失等於沒有蒐證。

    `fetch`／`sleep` 是給測試用的注入縫（慣例沿用 `fetch_commons_turbines.subcategories(fetch=)`）：
    預設就是 `http_get` 與 `time.sleep`，**行為完全不變**；測試靠它驗「真的等了 Retry-After 說的秒數」
    而不必真的睡 600 秒。
    """
    fetch = fetch or http_get
    sleep = sleep or time.sleep
    events: list[dict] = []
    for attempt in range(2):
        try:
            got = fetch(url, timeout)
        except urllib.error.HTTPError as e:
            retry_after = e.headers.get("Retry-After") if e.headers else None
            if e.code == 429:
                wait = retry_after_seconds(retry_after)
                events.append({"at": utcnow(), "url": url, "http_status": 429,
                               "retry_after_header": retry_after, "waited_s": wait})
                if attempt == 0:
                    if not quiet:
                        print(f"    429（Retry-After={retry_after}）→ 完整等 {wait:.0f} s 後只重試這一張一次",
                              file=sys.stderr)
                    sleep(wait)
                    continue
                raise Blocked("連續兩次 429", events, url, 429) from e
            if e.code in BLOCKED_STATUS:
                # CDN 直接拒絕（IP／UA 層的規則；451 是法務層）。這同樣是「這個客戶端不受歡迎」，
                # 不是「這個 URL 有問題」——落進一般失敗分支的話還會再打 4 張才停，
                # 而且停下來時印的是「多半是網路本身的問題」，把人引導去檢查 wifi 然後重跑。
                events.append({"at": utcnow(), "url": url, "http_status": e.code})
                raise Blocked(f"HTTP {e.code}——CDN 直接拒絕（IP／UA 層的規則）",
                              events, url, e.code) from e
            if 500 <= e.code < 600:
                events.append({"at": utcnow(), "url": url, "http_status": e.code})
                if attempt == 0:
                    if not quiet:
                        print(f"    {e.code}，Robot policy 要求暫停 ≥ 15 分鐘", file=sys.stderr)
                    sleep(SERVER_ERROR_PAUSE_S)
                    continue
                raise Blocked(f"連續兩次 {e.code}", events, url, e.code) from e
            return {"status": "failed", "reason": f"HTTP {e.code}", "http_status": e.code,
                    "failure_kind": "http", "events": events}
        except Exception as e:  # noqa: BLE001  （URLError／timeout／DNS…）
            return {"status": "failed", "reason": f"{type(e).__name__}: {e}",
                    "failure_kind": "network", "events": events}

        # `http_get` 回三元組（多一個跟完重導向的網址）；測試注入的假抓取器可以只回兩元組。
        if isinstance(got, tuple) and len(got) == 3:
            blob, status, final_url = got
        else:
            blob, status = got
            final_url = url

        # **「絕不抓原圖」的回應端防線只在這一條路徑上**（`require_thumb=True`）：縮圖處理器不放大，
        # 要求的寬度 ≥ 原圖寬度時會導回原圖。鏡像那條路徑走 `fetch_mirror_one`，見那裡的說明。
        bad = validate_blob(blob, status, final_url,
                            require_thumb=True, max_bytes=MAX_RESPONSE_BYTES)
        if bad is None:
            bad = write_blob(blob, path, status)
        if bad is not None:
            bad["events"] = events
            return bad
        return {"status": "ok", "bytes": len(blob), "http_status": status,
                "sha256": hashlib.sha256(blob).hexdigest(), "events": events}
    return {"status": "failed", "reason": "retry loop exhausted",
            "failure_kind": "local", "events": events}


def fetch_mirror_one(url: str, path: str, timeout: float, fetch=None) -> dict:
    """從鏡像抓一張。**不重試、不退避、不丟 `Blocked`。**

    刻意與 `fetch_one` 長得不一樣，因為它守的東西不同：`fetch_one` 的每一條規則都是為了
    「不要害使用者的出口 IP 在 **Wikimedia** 眼中被封」，而鏡像不是 Wikimedia——
    它不限流、也沒有懲罰可以被墊高。所以這裡：

      * **404 是預期的答案**（鏡像的媒體檔凍結在 2013-03），回 `status="miss"`，
        既不算失敗、也不加 `fail_streak`、更不會讓「連續 N 張失敗」的煞車誤觸。
      * **429／403／451 → `status="unavailable"`**：鏡像說不就整趟不再用鏡像、剩下的走 Wikimedia
        （不是中止整趟——鏡像只是一條捷徑，不是這支腳本要保護的對象）。
      * 其他錯誤算失敗，連續 `MIRROR_MAX_FAILURES` 次同樣關掉鏡像（多半是這個網路連不到它）。
      * **抓到的是原圖，這是對的**：鏡像上沒有縮圖可選，而原圖的 EXIF 完整，對
        `real_pose_validation.py` 反而更好（它只縮不放）。`require_thumb=False` 就是這個意思，
        改用 `same_host` 守「不准被導到別的主機」。
    """
    fetch = fetch or http_get_mirror
    host = urllib.parse.urlsplit(url).netloc
    try:
        got = fetch(url, timeout)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {"status": "miss", "reason": f"鏡像上沒有（媒體檔凍結在 {MIRROR_FREEZE}）",
                    "http_status": 404}
        if e.code == 429 or e.code in BLOCKED_STATUS:
            return {"status": "unavailable", "http_status": e.code,
                    "reason": f"鏡像回 HTTP {e.code}——這一趟不再用鏡像，剩下的走 Wikimedia"}
        return {"status": "failed", "reason": f"鏡像 HTTP {e.code}", "http_status": e.code,
                "failure_kind": "http"}
    except Exception as e:  # noqa: BLE001  （URLError／timeout／DNS／ValueError…）
        return {"status": "failed", "reason": f"鏡像 {type(e).__name__}: {e}",
                "failure_kind": "network"}

    if isinstance(got, tuple) and len(got) == 3:
        blob, status, final_url = got
    else:
        blob, status = got
        final_url = url

    bad = validate_blob(blob, status, final_url, require_thumb=False,
                        max_bytes=MAX_MIRROR_RESPONSE_BYTES, same_host=host)
    if bad is None:
        bad = write_blob(blob, path, status)
    if bad is not None:
        return bad
    return {"status": "ok", "bytes": len(blob), "http_status": status,
            "sha256": hashlib.sha256(blob).hexdigest()}


# ---------------------------------------------------------------------------
# log
# ---------------------------------------------------------------------------

def write_log(path: str, log: dict) -> bool:
    """逐張落地（tmp + rename）。既有腳本只在整批結束時寫回 manifest 一次，
    中途 Ctrl-C 或崩潰就**不知道抓了哪些**——抓了 200 張卻對不上帳是最貴的失敗。

    寫不出來（磁碟滿／唯讀）時印警告但**不中斷**：log 寫不出來不該毀掉已經抓到的影像。
    """
    log["updated"] = utcnow()
    tmp = path + ".part"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(log, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, path)
        return True
    except OSError as e:
        print(f"    警告：寫不出 {os.path.basename(path)}（{type(e).__name__}: {e}）"
              f"——影像本身不受影響，但這一趟的紀錄會不完整", file=sys.stderr)
        return False


def summarise(log: dict, run_bytes: int = 0,
              run_bytes_mirror: int = 0, run_bytes_wikimedia: int = 0) -> dict:
    files = log.get("files", {})
    counts: dict[str, int] = {}
    total = downloaded = 0
    by_source: dict[str, int] = {"mirror": 0, "wikimedia": 0}
    bytes_by_source: dict[str, int] = {"mirror": 0, "wikimedia": 0}
    for rec in files.values():
        counts[rec["status"]] = counts.get(rec["status"], 0) + 1
        total += rec.get("bytes") or 0
        if rec["status"] == "ok":
            downloaded += rec.get("bytes") or 0
            # **原圖比縮圖大一個量級**（實測鏡像 1.5–5.8 MB／張 vs 縮圖 350–700 KB），
            # 兩邊混在一起加總的話，「這一趟下載了多少」就說不出「打了多少 Wikimedia」。
            src = rec.get("source") or "wikimedia"
            by_source[src] = by_source.get(src, 0) + 1
            bytes_by_source[src] = bytes_by_source.get(src, 0) + (rec.get("bytes") or 0)
    # `bytes` 是目錄裡的總量；`bytes_downloaded` 是 log 裡所有 status=ok 的總和——
    # 續傳時 log 會帶著上一趟的紀錄，所以**只有 `bytes_this_run` 是這一趟真的下載的量**
    # （由呼叫端在迴圈裡累計傳進來，不是從 log 反推）。
    return {"ok": counts.get("ok", 0),
            "skipped_existing": counts.get("skipped_existing", 0),
            "failed": counts.get("failed", 0),
            "not_attempted": counts.get("not_attempted", 0),
            "mirror_miss": counts.get("mirror_miss", 0),
            "ok_mirror": by_source.get("mirror", 0),
            "ok_wikimedia": by_source.get("wikimedia", 0),
            "bytes_mirror": bytes_by_source.get("mirror", 0),
            "bytes_wikimedia": bytes_by_source.get("wikimedia", 0),
            "bytes": total, "bytes_downloaded": downloaded, "bytes_this_run": run_bytes,
            "bytes_this_run_mirror": run_bytes_mirror,
            "bytes_this_run_wikimedia": run_bytes_wikimedia}


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def read_log(dir_path: str) -> dict:
    """讀回這個目錄的 `fetch_log.json`。讀不到／壞掉一律回空 dict——log 是輔助資訊，不是前提。"""
    try:
        with open(os.path.join(dir_path, LOG_NAME), encoding="utf-8") as fh:
            got = json.load(fh)
        return got if isinstance(got, dict) else {}
    except (OSError, ValueError):
        return {}


def demote_repeat_failures(plan: list[dict], log: dict,
                           threshold: int = FAIL_STREAK_DEMOTE) -> tuple[list[dict], int]:
    """把**這個目錄裡已經連續失敗 ≥ threshold 次**的排到清單尾端（不是刪掉）。

    反向：`interleave_by_model` 是決定性的，所以永久失敗的那幾張永遠排在名額最前面，
    `--limit 3` 連跑三趟就是對著同樣三個 404 各敲三次、磁碟上始終 0 張，
    而收尾還只印「失敗的可以直接重跑同一行指令續傳」。排到尾端讓名額落到真的抓得到的那些上，
    留在清單裡則是因為「上一趟失敗」不等於「永遠失敗」（新網路上 404 可能只是 DNS 沒通）。
    """
    files = log.get("files", {}) if isinstance(log.get("files"), dict) else {}
    keep: list[dict] = []
    tail: list[dict] = []
    for c in plan:
        rec = files.get(str(c.get("pageid"))) or {}
        streak = rec.get("fail_streak") or 0
        (tail if isinstance(streak, int) and streak >= threshold else keep).append(c)
    return keep + tail, len(tail)


def build_plan(a: argparse.Namespace) -> tuple[dict, list[dict]]:
    """決定這一趟要抓哪些。

    **待抓清單以磁碟實際狀態為準，不是 manifest 的 `file` 欄位**：`file` 只說「原機器上曾經抓到過」，
    而那 86 個檔案已隨 scratchpad 清空消失，照它濾就永遠湊不回 313 張。
    磁碟濾一定要排在 `--per-model`／`--limit` **之前**——順序反了的話，名額會被已經抓好的那幾張
    整碗吃掉（`interleave_by_model` 是決定性的，所以第二趟切出來的是同一批前 N 筆，
    全部命中 `existing_file_ok` 被跳過，真正沒抓的永遠排在名額之外），續傳就變成原地空轉。
    `--include-fetched` 是唯一會跳過磁碟濾的開關，用途是重建 `fetch_log.json`（逐張重算 sha256），
    不是「重抓」——迴圈裡的 skip 分支仍然會把已經完整的檔案跳過。
    `--mirror-only` 另外會把「已知鏡像上沒有」的拿掉（見 `drop_known_mirror_misses`）。
    """
    with open(a.manifest, encoding="utf-8") as fh:
        doc = json.load(fh)
    plan = selected_candidates(doc)
    if a.order == "interleave":
        plan = interleave_by_model(plan)
    if not a.include_fetched:
        plan = [c for c in plan
                if not existing_file_ok(os.path.join(a.dir, candidate_filename(c)))]
    # 磁碟濾**之後**、切名額**之前**降級：磁碟濾拿掉「已經成功落地」的，這一步拿掉
    # 「每次都失敗」的優先權，兩者少一個名額都會被空轉佔住。
    log = read_log(a.dir)
    a.mirror_dropped = 0
    if getattr(a, "mirror_only", False):
        # `--mirror-only` 下，鏡像上已知 404 的那些在這個模式裡**永遠**抓不到
        # （鏡像凍結在 2013-03，404 是永久的），留著只會把名額佔住、每趟白打一個請求。
        plan, a.mirror_dropped = drop_known_mirror_misses(plan, log)
    plan, demoted = demote_repeat_failures(plan, log)
    a.demoted = demoted
    plan = per_model_cap(plan, a.per_model)
    if a.limit:
        plan = plan[: a.limit]
    return doc, plan


def cmd_dry_run(a: argparse.Namespace, doc: dict, plan: list[dict]) -> int:
    sel = selected_candidates(doc)
    done = [c for c in sel if c.get("file")]
    pend = [c for c in sel if not c.get("file")]
    on_disk = [c for c in sel if existing_file_ok(os.path.join(a.dir, candidate_filename(c)))]
    print(f"manifest : {a.manifest}")
    print(f"候選 {len(doc.get('candidates', []))} 筆／入選 {len(sel)}／manifest 記為已抓 {len(done)}"
          f"／manifest 待抓 {len(pend)}")
    print(f"磁碟 {a.dir}：已有 {len(on_disk)} 張 → 實際待抓 {len(sel) - len(on_disk)} 張"
          f"（manifest 的 file 欄位只是原機器的紀錄，那 86 個檔案已經不在了；**磁碟才是權威**）")
    print(f"這一趟要抓 {len(plan)} 張 → {a.dir}（寬度 {a.thumb_width} px、間隔 {a.pace} s、並發 1）")
    prev = read_log(a.dir)

    # 鏡像這一段：**不發任何請求**，所以第一次只能用實測命中率估，跑過一趟之後才是精確值。
    mirror_on = getattr(a, "mirror_only", False) or not getattr(a, "no_mirror", False)
    look = mirror_outlook(plan, prev) if mirror_on else {
        "expected_mirror": 0, "expected_wikimedia": len(plan),
        "known_hit": 0, "known_miss": 0, "unknown": 0}
    n_mirror, n_wm = look["expected_mirror"], look["expected_wikimedia"]
    if getattr(a, "mirror_only", False):
        n_wm = 0
    if mirror_on:
        base = getattr(a, "mirror_base", MIRROR_BASE)
        print(f"鏡像預計可得 {n_mirror} 張／Wikimedia 需要 {n_wm} 張"
              f"（{base}，媒體檔凍結在 {MIRROR_FREEZE}）")
        if look["unknown"]:
            print(f"  其中 {look['known_hit']} 張已知命中、{look['known_miss']} 張已知 404，"
                  f"剩 {look['unknown']} 張未知（以實測命中率 {MIRROR_HIT_RATE * 100:.1f}% ＝ 66/313 估；"
                  f"跑過一趟鏡像之後這個數字就是精確的）")
        else:
            print(f"  全部 {len(plan)} 張的鏡像狀態都已經探過，上面是精確值不是估計")
        if getattr(a, "mirror_dropped", 0):
            print(f"  另有 {a.mirror_dropped} 張已知鏡像上沒有，--mirror-only 下已從清單移除"
                  f"（鏡像凍結，404 是永久的）")
    # 估計時間與流量。兩條路要**分開算**：
    #   * 請求數 ≠ 下載數——鏡像那邊每一張都要問（404 也是一個請求），Wikimedia 那邊只問回退的那些；
    #   * 鏡像給的是**原圖**（實測 1.5–5.8 MB），與縮圖（350–700 KB）差一個量級。
    mirror_pace = getattr(a, "mirror_pace", DEFAULT_MIRROR_PACE_S)
    mirror_reqs = (len(plan) - look["known_miss"]) if mirror_on else 0
    minutes = (mirror_reqs * mirror_pace + n_wm * a.pace) / 60
    parts = [f"預估 {minutes:.0f} 分鐘"]
    if n_wm or not mirror_on:
        parts.append(f"Wikimedia {n_wm} 張 "
                     f"{human_bytes(n_wm * 350 * 1024)}–{human_bytes(n_wm * 700 * 1024)}"
                     f"（縮圖 350–700 KB/張）")
    if mirror_on:
        parts.append(f"鏡像 {n_mirror} 張 "
                     f"{human_bytes(n_mirror * 1.5 * 1024 * 1024)}–"
                     f"{human_bytes(n_mirror * 5.8 * 1024 * 1024)}"
                     f"（原圖 1.5–5.8 MB/張，{mirror_reqs} 個請求）")
    print("、".join(parts))
    blocked = wikimedia_block_of(prev)
    if blocked:
        print(f"!! 上一趟因為被限流／被擋而中止：{blocked.get('message')}\n"
              f"   在同一個網路上真的跑（不加 --dry-run）會被拒絕；換出口 IP 之後加 --new-network。\n"
              f"   （`--mirror-only` 不受影響——它一個請求都不會打到 Wikimedia。）")
    carried = recent_429_count(prev.get("events_429"))
    if carried:
        print(f"!! 這個目錄最近 {RECENT_429_WINDOW_H:.0f} 小時內已經吃掉 {carried} 次 429，"
              f"下一趟的預算從 {carried}/{MAX_TOTAL_429} 起算")
    if getattr(a, "demoted", 0):
        print(f"其中 {a.demoted} 張在這個目錄裡已經連續失敗 ≥ {FAIL_STREAK_DEMOTE} 次，已排到清單尾端")
    print("--dry-run：以下只是清單，**一個請求都不會發出**\n")
    prev_files = prev.get("files", {}) if isinstance(prev.get("files"), dict) else {}
    by_model: dict[str, int] = {}
    derived = clamped = 0
    for c in plan:
        by_model[c.get("model") or "?"] = by_model.get(c.get("model") or "?", 0) + 1
        url, how = thumb_url_for(c, a.thumb_width, a.thumb_host)
        if how == "derived":
            derived += 1
        w = thumb_width_of(url)
        note = ""
        if w and w < a.thumb_width:
            clamped += 1
            note = f"（原圖只有 {c.get('width')} px 寬，縮圖寬度夾到 {w}）"
        fname = candidate_filename(c)
        print(f"  {fname:<16} {c.get('model') or '?':<16} f35={c.get('focal_35mm')!s:<6} "
              f"{c.get('width')}x{c.get('height')} [{how}]{note}")
        if mirror_on:
            st = (prev_files.get(str(c.get("pageid"))) or {}).get("mirror_status")
            mark = {"hit": "已知命中", "miss": "已知 404"}.get(st, "未探過")
            murl = mirror_url_for(c, getattr(a, "mirror_base", MIRROR_BASE))
            print(f"      鏡像[{mark}] {murl or '（推不出鏡像路徑，直接走 Wikimedia）'}")
        # `--mirror-only` 下這個網址**不會**被送出去，印出來只會讓人以為它會。
        if not getattr(a, "mirror_only", False):
            print(f"      {url}")
    print(f"\n機型分布：{', '.join(f'{k} {v}' for k, v in sorted(by_model.items()))}")
    print(f"其中 {derived} 張的 thumb_url 其實是**原圖網址**，已改由 url 自行推導縮圖路徑"
          f"（照抄 standard_thumb_url 會去抓多 MB 的原圖）")
    if clamped:
        print(f"其中 {clamped} 張的原圖比 --thumb-width 還窄，寬度已夾小"
              f"（要求的寬度 ≥ 原圖寬度時縮圖處理器會把請求導回原圖）")
    return 0


def cmd_verify(a: argparse.Namespace) -> int:
    """不碰網路的完整性驗證：對 `fetch_log.json` 逐筆重算 sha256 與大小。

    文件承諾「帶回去用 sha256 驗完整性」，但在此之前沒有任何模式做這件事，使用者得自己寫。
    跨網路 tar／scp 會截斷檔案，而截斷的 JPEG 前幾個 byte 與完整檔一模一樣。
    """
    log_path = os.path.join(a.dir, LOG_NAME)
    try:
        with open(log_path, encoding="utf-8") as fh:
            log = json.load(fh)
    except FileNotFoundError:
        print(f"找不到 {log_path}——`--verify` 要對著抓取用的輸出目錄跑（用 --dir 指定）", file=sys.stderr)
        return 2
    except (OSError, ValueError) as e:
        print(f"{log_path} 讀不了或不是合法 JSON（{type(e).__name__}: {e}）", file=sys.stderr)
        return 2

    files = log.get("files", {})
    good: list[str] = []
    bad: list[str] = []
    missing: list[str] = []
    for key in sorted(files, key=lambda k: files[k].get("file") or k):
        rec = files[key]
        if rec.get("status") not in ("ok", "skipped_existing"):
            continue
        name = rec.get("file") or f"c{key}.jpg"
        p = os.path.join(a.dir, name)
        try:
            size = os.path.getsize(p)
        except OSError:
            missing.append(name)
            continue
        try:
            digest = sha256_of(p)
        except OSError as e:
            bad.append(f"{name}：讀不了（{type(e).__name__}: {e}）")
            continue
        want = rec.get("sha256")
        if want and digest != want:
            bad.append(f"{name}：sha256 不符（log {want[:12]}… / 磁碟 {digest[:12]}…）")
        elif rec.get("bytes") and size != rec["bytes"]:
            bad.append(f"{name}：大小不符（log {rec['bytes']} B／磁碟 {size} B）")
        elif not existing_file_ok(p):
            bad.append(f"{name}：magic／結尾標記／大小其中一關沒過（截斷或不是影像）")
        else:
            good.append(name)

    try:
        on_disk = {f for f in os.listdir(a.dir) if f.endswith((".jpg", ".png"))}
    except OSError:
        on_disk = set()
    unrecorded = sorted(on_disk - {n for n in good} - {n for n in missing}
                        - {b.split("：")[0] for b in bad})

    print(f"驗證 {a.dir}（{LOG_NAME} 裡 {len(files)} 筆紀錄，不發任何請求）")
    print(f"  通過 {len(good)}／對不上 {len(bad)}／log 有但檔案不見 {len(missing)}")
    for b in bad:
        print(f"  x {b}")
    for m in missing:
        print(f"  ? {m}：log 記了但磁碟上沒有")
    if unrecorded:
        print(f"  i 磁碟上有 {len(unrecorded)} 個檔案沒有 log 紀錄（別的工具抓的？）："
              f"{', '.join(unrecorded[:5])}{'…' if len(unrecorded) > 5 else ''}")
    if bad or missing:
        print("對不上的刪掉之後重跑同一行抓取指令就會自動補回來（待抓清單以磁碟為準）")
        return 1
    return 0


def main(argv: list[str] | None = None, fetch=None, sleep=None, mirror_fetch=None) -> int:
    ap = argparse.ArgumentParser(
        description="可攜版 Commons 縮圖抓取器（零相依、可續傳、有禮貌）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="本機 IP 已被 upload.wikimedia.org 持續封鎖，這個腳本是要拿到別的網路上跑的。")
    ap.add_argument("--manifest", default="data/commons_turbines_manifest.json",
                    help="版控裡的 manifest（git clone 就有）")
    ap.add_argument("--dir", default="commons_turbines", help="影像輸出目錄（單一平坦目錄）")
    ap.add_argument("--thumb-width", type=int, default=DEFAULT_THUMB_WIDTH,
                    help=f"縮圖寬度，只能是常用寬度 {STANDARD_THUMB_WIDTHS} 之一"
                         f"（預設 {DEFAULT_THUMB_WIDTH}）；超過原圖寬度時會自動夾小，"
                         f"否則縮圖處理器會把請求導回原圖")
    ap.add_argument("--pace", type=float, default=DEFAULT_PACE_S,
                    help=f"每個請求之間的間隔秒數（收到 429 會自動加倍，上限 {PACE_MAX_S:.0f} s；"
                         f"連續 {PACE_RECOVER_AFTER} 張乾淨會減半回來）。"
                         f"硬地板 {SAFE_PACE_FLOOR_S} s＝Wikimedia 公布的未認證上限 500 次/小時")
    ap.add_argument("--new-network", action="store_true",
                    help="宣告「我已經換到另一個出口 IP 了」。這是上一趟因為 429／被擋而中止之後"
                         "**唯一**能再跑的方式：它會把 log 裡舊的 events_429 標記成上一個網路的、"
                         "不併進這一趟的預算。**在同一個網路上加這個旗標＝對著已經說不的 CDN 硬闖**")
    ap.add_argument("--limit", type=int, default=0, help="這一趟最多抓幾張（0 = 不限）")
    ap.add_argument("--per-model", type=int, default=0, help="每個機型最多幾張（對待抓清單計數）")
    ap.add_argument("--order", choices=("interleave", "manifest"), default="interleave",
                    help="interleave = 機型輪流取（被擋停時仍保有多樣性）；manifest = 照 manifest 原順序")
    ap.add_argument("--include-fetched", action="store_true",
                    help="把磁碟上已經有的也排進清單（逐張重算 sha256 後跳過，用來重建 fetch_log.json）。"
                         "**預設不必加**：待抓清單現在一律以磁碟實際狀態為準，manifest 標為已抓、"
                         "但檔案不在磁碟上的那 86 張預設就會重抓")
    ap.add_argument("--thumb-host", default="",
                    help=f"強制改寫縮圖主機名。預設一律用 {DERIVED_THUMB_HOST}"
                         f"（manifest 裡 231/313 的 thumb_url 就是這個 host，已成功下載的 86 張裡 65 張也是）；"
                         f"若這個 host 在你的網路上不通，用 --thumb-host upload.wikimedia.org 重試")
    ap.add_argument("--mirror-base", default=MIRROR_BASE,
                    help=f"鏡像的 base URL（預設 {MIRROR_BASE}）。"
                         f"指向 wikimedia.org 會被拒絕——鏡像那條路徑不計入 429 預算、"
                         f"步調也只有 {DEFAULT_MIRROR_PACE_S} s，指回 Wikimedia 等於拿掉全部煞車")
    ap.add_argument("--mirror-pace", type=float, default=DEFAULT_MIRROR_PACE_S,
                    help=f"鏡像請求之間的間隔秒數（預設 {DEFAULT_MIRROR_PACE_S}，地板 "
                         f"{MIRROR_PACE_FLOOR_S}）。鏡像不限流，所以可以比 --pace 快；"
                         f"但它同樣是別人出錢的頻寬")
    ap.add_argument("--mirror-only", action="store_true",
                    help="只抓鏡像上拿得到的，**一個請求都不會打到 Wikimedia**。"
                         f"這是出口 IP 已經被封的機器上唯一跑得動的模式（實測 313 張裡 66 張拿得到）。"
                         "它不受「上一趟被擋」的跨趟煞車阻擋，也**不會清掉**那個封鎖紀錄")
    ap.add_argument("--no-mirror", action="store_true",
                    help="跳過鏡像、全部走 Wikimedia（行為回到加鏡像之前）")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    ap.add_argument("--dry-run", action="store_true", help="只列出要抓什麼，不發任何請求")
    ap.add_argument("--verify", action="store_true",
                    help=f"不碰網路：對 {LOG_NAME} 逐筆重算 sha256 與大小，列出對不上的")
    a = ap.parse_args(argv)
    sleep = sleep or time.sleep      # 注入縫（同 fetch_one）；預設行為不變

    # **注入了假的 Wikimedia 抓取器卻沒注入假的鏡像抓取器 → 鏡像一律關掉。**
    # 測試的縫不可以變成「偷偷發真請求」的洞：一支只注入 `fetch=` 的測試如果讓鏡像走真的
    # `http_get_mirror`，那份測試就會在 CI 上對外連線，而且沒有人會發現。
    # 從命令列跑時 `fetch` 是 None，所以 `mirror_fetch` 照樣是真的那一個，行為不變。
    if mirror_fetch is None and fetch is None:
        mirror_fetch = http_get_mirror

    if a.verify:                     # **一個請求都不發**，所以擺在所有網路相關檢查之前
        return cmd_verify(a)

    if a.mirror_only and a.no_mirror:
        print("--mirror-only 與 --no-mirror 互斥：一個是「只走鏡像」、一個是「不走鏡像」",
              file=sys.stderr)
        return 2
    if is_wikimedia_host(a.mirror_base):
        print(f"--mirror-base 不得指向 Wikimedia（{a.mirror_base}）。\n"
              f"鏡像那條路徑刻意不計入 429 預算、步調只有 {DEFAULT_MIRROR_PACE_S} s，"
              f"因為 ftpmirror.your.org 不是 Wikimedia 的 IP。把 base 指回去等於拿掉全部煞車，"
              f"對著已經封鎖我們的 CDN 每秒敲一次。", file=sys.stderr)
        return 2
    if a.mirror_only and mirror_fetch is None:
        # 只會在測試裡發生：注入了 `fetch=` 卻沒注入 `mirror_fetch=`（見上面那條規則），
        # 而 `--mirror-only` 沒有別的來源。說清楚比靜默跑 0 張好。
        print("--mirror-only 需要可用的鏡像抓取器；呼叫端注入了 fetch= 卻沒注入 mirror_fetch=，"
              "鏡像已被安全地關閉（測試的縫不可以變成偷偷發真請求的洞）", file=sys.stderr)
        return 2
    if a.mirror_pace < MIRROR_PACE_FLOOR_S:
        print(f"--mirror-pace 不得低於 {MIRROR_PACE_FLOOR_S} s——那是 Robot policy 的官方地板"
              f"（delay ≥ 1 s、並發 ≤ 1）。鏡像不限流不代表可以無限快，那是別人出錢的頻寬。",
              file=sys.stderr)
        return 2

    if a.thumb_width not in STANDARD_THUMB_WIDTHS:
        print(f"--thumb-width 只能是 Wikimedia 常用寬度 {STANDARD_THUMB_WIDTHS}"
              f"（非常用寬度每張都要現算縮圖，那是真正昂貴的請求，會被 429）", file=sys.stderr)
        return 2
    if a.thumb_width < MIN_THUMB_WIDTH:
        print(f"--thumb-width 不得低於 {MIN_THUMB_WIDTH}：驗證管線只縮不放，"
              f"更小的圖會讓分析跑在比 App 更小的尺度上，數字與既有 86 張不可比", file=sys.stderr)
        return 2
    if a.pace < SAFE_PACE_FLOOR_S:
        print(f"--pace 不得低於 {SAFE_PACE_FLOOR_S} s——那是 Wikimedia 公布的未認證上限"
              f"（每 IP 每小時 500 次）換算出來的地板；預設 {DEFAULT_PACE_S:.0f} s 已經留了一半餘裕。\n"
              f"想更快只有一條合規的路：用認證帳號，或寄信給 bot-traffic@wikimedia.org 談量級。\n"
              f"（全域 429 預算會在 {MAX_TOTAL_429} 次之後停手，但那幾次已經打在**你的**出口 IP 上了，"
              f"而那種懲罰不會隨時間衰減。）", file=sys.stderr)
        return 2

    try:
        doc, plan = build_plan(a)
    except FileNotFoundError:
        print(f"找不到 manifest：{a.manifest}\n"
              f"這個腳本要在 InduSpect/blade_prototype 目錄下跑，或用 --manifest 指定路徑", file=sys.stderr)
        return 2
    except (OSError, ValueError) as e:      # json.JSONDecodeError 是 ValueError 的子類
        print(f"manifest 讀不了、或不是合法的 JSON：{a.manifest}\n"
              f"  {type(e).__name__}: {e}\n"
              f"（多半是傳輸截斷或被編輯壞了；重新 git checkout 一份即可）", file=sys.stderr)
        return 2

    if a.dry_run:
        return cmd_dry_run(a, doc, plan)

    try:
        os.makedirs(a.dir, exist_ok=True)
    except OSError as e:
        print(f"建不出輸出目錄 {a.dir}（{type(e).__name__}: {e}）", file=sys.stderr)
        return 2

    # 上一趟被 SIGKILL／斷電留下的半成品。留著會被收尾的 tar 一起打包帶回去，
    # 讓「帶回來的目錄 = 權威快照」這件事變得模糊（驗證端只讀 c<pageid>.jpg，所以只是雜訊）。
    parts = 0
    try:
        for f in os.listdir(a.dir):
            if f.endswith(".part"):
                try:
                    os.remove(os.path.join(a.dir, f))
                    parts += 1
                except OSError:
                    pass
    except OSError:
        pass
    if parts:
        print(f"清掉 {parts} 個上一趟留下的 .part 暫存檔", file=sys.stderr)

    log_path = os.path.join(a.dir, LOG_NAME)
    log = {"tool": "commons_portable_fetch.py", "started": utcnow(), "updated": utcnow(),
           "manifest": os.path.abspath(a.manifest), "dir": os.path.abspath(a.dir),
           "thumb_width": a.thumb_width, "pace_s": a.pace, "user_agent": UA,
           "planned": len(plan), "aborted": None, "aborted_kind": None,
           "last_aborted": None, "last_aborted_kind": None,
           "mirror_base": a.mirror_base, "mirror_pace_s": a.mirror_pace,
           "mirror_mode": ("only" if a.mirror_only else "off" if a.no_mirror else "first"),
           "mirror_disabled_reason": None, "wikimedia_block": None,
           "files": {}, "events_429": [], "events_mirror": []}
    prev_kind: str | None = None
    if os.path.exists(log_path):       # 續傳：保留上一趟的紀錄與 429 實證
        try:
            with open(log_path, encoding="utf-8") as fh:
                old = json.load(fh)
            log["files"] = old.get("files", {})
            log["events_429"] = old.get("events_429", [])
            log["events_mirror"] = old.get("events_mirror", [])
            log["started"] = old.get("started", log["started"])
            # **上一趟為什麼停的那個欄位不可以被無聲丟掉**——它是跨趟煞車唯一的依據。
            log["last_aborted"] = old.get("aborted")
            log["last_aborted_kind"] = old.get("aborted_kind") or classify_abort(old.get("aborted"))
            # 封鎖狀態是**黏性**的，自己有一格：`--mirror-only` 可以在被擋的機器上正常跑完，
            # 而那一趟會把 `aborted` 覆寫成 None——煞車不能被一趟「根本沒碰 Wikimedia」的抓取解除。
            blocked = wikimedia_block_of(old)
            log["wikimedia_block"] = blocked
            prev_kind = (blocked or {}).get("kind")
        except (OSError, ValueError):
            pass

    if a.new_network:
        # 換了出口 IP：舊 IP 的配額與這一趟無關。標記而不是刪除——events_429 是要寄給
        # bot-traffic@wikimedia.org 的實證，刪掉等於把證據銷毀。
        marked = 0
        for e in log["events_429"]:
            if isinstance(e, dict) and e.get("network_generation") != "previous":
                e["network_generation"] = "previous"
                marked += 1
        if marked:
            print(f"--new-network：把 log 裡 {marked} 次 429 標記成上一個網路的，"
                  f"不併進這一趟的預算（實證仍留在 {LOG_NAME} 裡）", file=sys.stderr)
        prev_kind = None
        log["wikimedia_block"] = None        # **唯一的解除方式**
    elif prev_kind in ("throttled", "blocked") and a.mirror_only:
        # `--mirror-only` 一個請求都不會打到 Wikimedia，所以那個封鎖擋不住它，它也解除不了那個封鎖。
        # 這正是被封的機器上唯一跑得動的模式（實測 313 張裡 66 張拿得到）。
        print(f"注意：這個目錄上一趟因為被限流／被擋而中止（{(log['wikimedia_block'] or {}).get('message')}）。\n"
              f"  --mirror-only 不碰 Wikimedia，所以照跑；那個封鎖紀錄**不會**被這一趟清掉"
              f"（要解除仍然只有 --new-network）。", file=sys.stderr)
    elif prev_kind in ("throttled", "blocked"):
        # **跨趟煞車**。這支腳本的一般 UX 是「中斷後重跑同一行就是續傳」，而畫面停在
        # 「抓到 5/313」時，把它包進 `while ! cmd; do sleep 60; done` 是長下載最自然的寫法——
        # 於是同一個被限流的 IP 會被反覆試探，那正是把懲罰從 300 墊到 600 的形狀。
        print(f"拒跑：上一趟因為被限流／被擋而中止——\n"
              f"  {(log['wikimedia_block'] or {}).get('message')}\n"
              f"在**同一個網路**上重跑只會墊高懲罰（那種懲罰不會隨時間衰減，實測靜默 6 天仍是"
              f" Retry-After 600）。要繼續只有三條路：\n"
              f"  ① 換到另一個出口 IP，然後加 --new-network 再跑同一行；\n"
              f"  ② 加 --mirror-only 先把鏡像上拿得到的抓回來（完全不碰 Wikimedia）；\n"
              f"  ③ 寄信給 bot-traffic@wikimedia.org（把 {LOG_NAME} 的 events_429 附上）。\n"
              f"（`--verify`／`--dry-run` 不發請求，隨時可以跑。）", file=sys.stderr)
        return 2

    carried_429 = recent_429_count(log["events_429"])
    if carried_429 >= MAX_TOTAL_429 and not a.mirror_only:
        print(f"拒跑：最近 {RECENT_429_WINDOW_H:.0f} 小時內這個目錄已經吃掉 {carried_429} 次 429"
              f"（預算 {MAX_TOTAL_429}）。預算是**跨趟**的，重跑同一行不會讓它歸零。\n"
              f"換網路之後加 --new-network，或加 --mirror-only 只走鏡像，"
              f"或寄信給 bot-traffic@wikimedia.org。", file=sys.stderr)
        return 2
    if carried_429 and not a.mirror_only:
        print(f"注意：最近 {RECENT_429_WINDOW_H:.0f} 小時內這個目錄已經吃掉 {carried_429} 次 429，"
              f"這一趟的預算從 {carried_429}/{MAX_TOTAL_429} 起算（不是從 0）", file=sys.stderr)

    # 磁碟上已經有、因此**不在這一趟計畫裡**的那些，照樣記進 log：
    # sha256 是帶回去驗完整性（`--verify`）的唯一依據，漏記就驗不到。
    planned_keys = {str(c["pageid"]) for c in plan}
    for c in selected_candidates(doc):
        key = str(c["pageid"])
        if key in planned_keys:
            continue
        p = os.path.join(a.dir, candidate_filename(c))
        if not existing_file_ok(p):
            continue
        try:
            log["files"][key] = dict(base_record(c), status="skipped_existing",
                                     mirror_status=(log["files"].get(key) or {}).get("mirror_status"),
                                     bytes=os.path.getsize(p), sha256=sha256_of(p))
        except OSError as e:
            print(f"    警告：{candidate_filename(c)} 讀不了（{type(e).__name__}: {e}）", file=sys.stderr)

    # 鏡像這條路的狀態。**與 Wikimedia 那條完全分開**：獨立的步調時鐘、獨立的失敗計數、
    # 獨立的事件清單，而且一次都不碰 `total_429`／`events_429`——那份預算保護的是這個出口 IP
    # 在 **Wikimedia** 眼中的處境，而 ftpmirror.your.org 不是 Wikimedia。
    mirror_on = bool(mirror_fetch) and not a.no_mirror
    mirror_disabled: str | None = None
    mirror_fail_streak = 0
    last_mirror_request = 0.0
    run_mirror_ok = run_mirror_miss = 0
    run_bytes_mirror = run_bytes_wikimedia = 0

    consecutive_failures = 0
    # **全域且跨趟**的 429 預算：每張各自重試成功不算沒事，累計才是實情；
    # 起算值是最近 24 小時內已經吃掉的次數，不是 0（重跑同一行不會讓預算歸零）。
    total_429 = carried_429
    run_429 = 0                  # 這一趟自己吃的（收尾要跟「最近 24 小時累計」分開講）
    clean_since_429 = 0          # 連續幾張沒有 429 → 夠多就把步調減半回去
    base_pace = a.pace           # 使用者給的原始步調，也是自適應減速的回復下限
    run_ok = run_failed = 0
    run_bytes = 0                # 只算這一趟真的下載的位元組（log 裡還有上一趟的紀錄）
    last_request = 0.0
    aborted: str | None = None
    abort_kind: str | None = None
    touched: set[str] = set()    # 這一趟真的處理過的 key（中止時要把沒輪到的記成 not_attempted）
    recent_failures: list[dict] = []   # 最近幾筆失敗紀錄，中止訊息由它推導而不是寫死
    print(f"要抓 {len(plan)} 張 → {a.dir}（{a.thumb_width} px、間隔 {a.pace} s、並發 1）", file=sys.stderr)
    if mirror_on:
        look = mirror_outlook(plan, log)
        print(f"鏡像先行：{a.mirror_base}（凍結在 {MIRROR_FREEZE}、間隔 {a.mirror_pace} s、"
              f"不計入 429 預算）；預計可得 {look['expected_mirror']} 張"
              f"{'（--mirror-only：其餘這一趟不抓）' if a.mirror_only else '，其餘回退到 Wikimedia 縮圖'}",
              file=sys.stderr)
        if a.mirror_dropped:
            print(f"  另有 {a.mirror_dropped} 張已知鏡像上沒有，已從清單移除（鏡像凍結，404 是永久的）",
                  file=sys.stderr)
    elif a.no_mirror:
        print("--no-mirror：全部走 Wikimedia（鏡像那條捷徑關掉了）", file=sys.stderr)
    if getattr(a, "demoted", 0):
        print(f"其中 {a.demoted} 張在這個目錄裡已經連續失敗 ≥ {FAIL_STREAK_DEMOTE} 次，"
              f"已排到清單尾端（名額先給抓得到的；它們的 reason 在 {LOG_NAME}）", file=sys.stderr)

    def eta_line(done: int) -> str:
        left = len(plan) - done
        return f"    剩 {left} 張，以現在的步調（{a.pace:.0f} s）約 {left * a.pace / 60:.0f} 分鐘"

    try:
        for i, c in enumerate(plan, 1):
            key = str(c["pageid"])
            fname = candidate_filename(c)
            path = os.path.join(a.dir, fname)
            base = base_record(c)
            touched.add(key)
            # 這個目錄裡它已經連續失敗幾次（要在覆寫紀錄之前讀）。失敗 +1、成功歸零；
            # 累到 FAIL_STREAK_DEMOTE 就由 `demote_repeat_failures` 排到下一趟的清單尾端。
            prev_streak = (log["files"].get(key) or {}).get("fail_streak") or 0

            prev_mirror = (log["files"].get(key) or {}).get("mirror_status")

            if existing_file_ok(path):     # 建完計畫之後才出現的（例如同時開了另一個視窗）
                try:
                    log["files"][key] = dict(base, status="skipped_existing",
                                             mirror_status=prev_mirror,
                                             bytes=os.path.getsize(path), sha256=sha256_of(path))
                except OSError as e:
                    log["files"][key] = dict(base, status="skipped_existing",
                                             mirror_status=prev_mirror,
                                             reason=f"讀不了：{type(e).__name__}: {e}")
                write_log(log_path, log)
                consecutive_failures = 0   # 中間夾了確定沒問題的處理，就不是「連續」失敗
                continue

            # ---- 鏡像先行 --------------------------------------------------
            # 已知 404 的不再問（鏡像凍結在 2013-03，那個 404 是永久的）；推不出路徑的直接走 Wikimedia。
            mirror_status = prev_mirror
            mres: dict | None = None
            if mirror_on and not mirror_disabled and prev_mirror != "miss":
                murl = mirror_url_for(c, a.mirror_base)
                if murl:
                    mwait = a.mirror_pace - (time.time() - last_mirror_request)
                    if mwait > 0:
                        sleep(mwait)
                    last_mirror_request = time.time()
                    mres = fetch_mirror_one(murl, path, a.timeout, fetch=mirror_fetch)

            if mres is not None and mres["status"] == "ok":
                # **抓到的是原圖，這是對的**：鏡像上沒有縮圖可選，而原圖 EXIF 完整，
                # 對 `real_pose_validation.py` 反而更好（它只縮不放）。
                # `thumb_width` 記 0 是實話——這一張不是縮圖；`source` 才是要看的那一欄。
                mirror_fail_streak = 0
                rec = dict(base, source="mirror", source_url=murl, thumb_how="mirror_original",
                           mirror_status="hit", fetched_at=utcnow(), thumb_width=0,
                           status="ok", bytes=mres["bytes"], sha256=mres["sha256"],
                           http_status=mres.get("http_status"), fail_streak=0)
                log["files"][key] = rec
                write_log(log_path, log)
                consecutive_failures = 0
                run_ok += 1
                run_mirror_ok += 1
                run_bytes += rec["bytes"]
                run_bytes_mirror += rec["bytes"]
                print(f"  + [{i}/{len(plan)}] {fname} {rec['bytes'] // 1024} KB [鏡像原圖] "
                      f"{c.get('model')} f35={c.get('focal_35mm')}", file=sys.stderr)
                continue

            if mres is not None:
                st = mres["status"]
                if st == "miss":
                    mirror_status = "miss"
                    mirror_fail_streak = 0
                    run_mirror_miss += 1
                elif st == "unavailable":
                    # 鏡像自己說不。**不中止整趟**——鏡像只是捷徑，不是這支腳本要保護的對象；
                    # 但也不再問它，剩下的走 Wikimedia。
                    mirror_disabled = mres["reason"]
                    log["events_mirror"].append({"at": utcnow(), "url": murl,
                                                 "http_status": mres.get("http_status"),
                                                 "reason": mres["reason"]})
                    print(f"    鏡像關閉：{mres['reason']}", file=sys.stderr)
                else:
                    mirror_fail_streak += 1
                    log["events_mirror"].append({"at": utcnow(), "url": murl,
                                                 "http_status": mres.get("http_status"),
                                                 "reason": mres.get("reason")})
                    if mirror_fail_streak >= MIRROR_MAX_FAILURES:
                        mirror_disabled = (f"連續 {mirror_fail_streak} 次失敗"
                                           f"（最後一次：{mres.get('reason')}）")
                        print(f"    鏡像關閉：{mirror_disabled}——這一趟剩下的走 Wikimedia",
                              file=sys.stderr)

            if a.mirror_only:
                # **這個模式不回退到 Wikimedia**，一個請求都不准打過去。
                if mirror_disabled:
                    aborted = (f"鏡像不可用（{mirror_disabled}），而 --mirror-only 不回退到 Wikimedia。"
                               f"把 --mirror-only 拿掉才會走 Wikimedia——但這台機器的出口 IP "
                               f"可能就是因為被擋才在用這個模式。")
                    abort_kind = "failures"
                    break
                if mirror_status == "miss":
                    # **只有真的收到 404 才記成 miss**（那是永久的、下一趟會被整個略過）。
                    # 鏡像連不上、推不出路徑都不算——把那些記成 miss 會讓它們永遠不再被嘗試。
                    log["files"][key] = dict(base, status="mirror_miss", mirror_status="miss",
                                             reason=f"鏡像上沒有（媒體檔凍結在 {MIRROR_FREEZE}），"
                                                    f"這一張只能走 Wikimedia",
                                             fail_streak=prev_streak)
                    write_log(log_path, log)
                    print(f"  - [{i}/{len(plan)}] {fname} 鏡像上沒有（{MIRROR_FREEZE} 之後上傳）",
                          file=sys.stderr)
                    continue
                reason = (mres.get("reason") if mres else "推不出鏡像路徑（manifest 的 url 不是 commons 路徑）")
                log["files"][key] = dict(base, status="failed", reason=reason,
                                         mirror_status=mirror_status,
                                         failure_kind=(mres or {}).get("failure_kind", "manifest"),
                                         fail_streak=prev_streak + 1)
                write_log(log_path, log)
                consecutive_failures += 1
                run_failed += 1
                recent_failures.append(log["files"][key])
                print(f"  x [{i}/{len(plan)}] {fname} {reason}", file=sys.stderr)
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                    aborted = f"連續 {consecutive_failures} 張在鏡像上失敗——先停下來看 {LOG_NAME}"
                    abort_kind = "failures"
                    break
                continue

            url, how = thumb_url_for(c, a.thumb_width, a.thumb_host)
            if not url:
                log["files"][key] = dict(base, status="failed", reason=how,
                                         mirror_status=mirror_status,
                                         failure_kind="manifest",
                                         fail_streak=prev_streak + 1)
                write_log(log_path, log)
                print(f"  x {fname} {how}", file=sys.stderr)
                continue

            wait = a.pace - (time.time() - last_request)
            if wait > 0:
                sleep(wait)
            last_request = time.time()

            try:
                res = fetch_one(url, path, a.timeout, fetch=fetch, sleep=sleep)
            except Blocked as e:
                # **被擋當下的 429 實證要跟著例外一起走**——那正是要寄給 bot-traffic@wikimedia.org 的
                # 東西，而唯一真正需要它的那一趟就是這一趟。順便把這一張記成失敗（否則連碰過都看不出來）。
                ev429 = [x for x in e.events if x.get("http_status") == 429]
                log["events_429"].extend(ev429)
                total_429 += len(ev429)
                run_429 += len(ev429)
                rec = dict(base, source="wikimedia", source_url=e.url or url, thumb_how=how,
                           mirror_status=mirror_status,
                           fetched_at=utcnow(), status="failed", reason=str(e),
                           http_status=e.http_status, failure_kind="http",
                           fail_streak=prev_streak + 1)
                log["files"][key] = rec
                # 這一張**真的失敗了**。不計進 run_failed 的話，全 429 的那一趟收尾會印
                # 「成功 0 張／失敗 0 張」——讀起來像「什麼都沒發生」，而實際上發了請求也吃了 429。
                run_failed += 1
                recent_failures.append(rec)
                write_log(log_path, log)
                raise

            ev429 = [x for x in res.pop("events", []) if x.get("http_status") == 429]
            log["events_429"].extend(ev429)
            total_429 += len(ev429)
            run_429 += len(ev429)
            rec = dict(base, source="wikimedia", source_url=url, thumb_how=how,
                       mirror_status=mirror_status, fetched_at=utcnow(),
                       thumb_width=thumb_width_of(url), **res)
            rec["fail_streak"] = 0 if rec["status"] == "ok" else prev_streak + 1
            log["files"][key] = rec
            write_log(log_path, log)

            if rec["status"] == "ok":
                consecutive_failures = 0
                run_ok += 1
                run_bytes += rec.get("bytes") or 0
                run_bytes_wikimedia += rec.get("bytes") or 0
                print(f"  + [{i}/{len(plan)}] {fname} {rec['bytes'] // 1024} KB "
                      f"{c.get('model')} f35={c.get('focal_35mm')}", file=sys.stderr)
            else:
                consecutive_failures += 1
                run_failed += 1
                recent_failures.append(rec)
                print(f"  x [{i}/{len(plan)}] {fname} {rec.get('reason')}", file=sys.stderr)

            if ev429:
                # 伺服器說太快就**真的變慢**。只防「連續兩次 429」是不夠的：標準的限流形狀是
                # 「每次都 429、重試就過」，那個形狀不減速的話會一路把懲罰墊高（300 → 600 就是這樣來的）。
                clean_since_429 = 0
                old_pace = a.pace
                a.pace = min(a.pace * 2, PACE_MAX_S)
                print(f"    這張吃了 {len(ev429)} 次 429（最近 {RECENT_429_WINDOW_H:.0f} 小時累計 "
                      f"{total_429}/{MAX_TOTAL_429}）→ 步調 {old_pace:.0f} s 改成 {a.pace:.0f} s",
                      file=sys.stderr)
                print(eta_line(i), file=sys.stderr)
            elif rec["status"] == "ok":
                # **減速要能回復**。只加倍不衰減的話，一次暫時性的 429 會把 78 分鐘的活
                # 變成好幾小時（實測 4 次分散的 429 → 步調卡在 240 s、累計等待 20 小時），
                # 而使用者在別人的筆電上看不到進度，最可能的結局是以為當掉了而 Ctrl-C。
                clean_since_429 += 1
                if a.pace > base_pace and clean_since_429 >= PACE_RECOVER_AFTER:
                    clean_since_429 = 0
                    old_pace = a.pace
                    a.pace = max(a.pace / 2, base_pace)
                    print(f"    連續 {PACE_RECOVER_AFTER} 張沒有 429 → "
                          f"步調 {old_pace:.0f} s 減半回 {a.pace:.0f} s", file=sys.stderr)
                    print(eta_line(i), file=sys.stderr)
            if total_429 >= MAX_TOTAL_429:
                aborted = (f"最近 {RECENT_429_WINDOW_H:.0f} 小時累計 {total_429} 次 429"
                           f"（其中這一趟 {run_429} 次，上限 {MAX_TOTAL_429}）——"
                           f"每一張都要重試才過，代表這個出口 IP 也已經在被限流，再跑下去只會被列入黑名單。"
                           f"停手：換一個網路（換好之後加 --new-network 再跑），"
                           f"或寄信給 bot-traffic@wikimedia.org（把 {LOG_NAME} 的 events_429 附上）")
                abort_kind = "throttled"
                break
            if consecutive_failures >= MAX_CONSECUTIVE_FAILURES:
                # 中止訊息由**最近幾筆失敗的 reason** 推導，不是寫死：同一個計數器也會被磁碟錯誤
                # 觸發，而那時候印「先看 http_status」會把人指向一個根本不存在的欄位。
                # **不能照 http_status 分類**：寫檔失敗那一路的 http_status 是 200
                # （伺服器沒問題，是這台機器的磁碟滿了），照 http_status 分會把 ENOSPC
                # 說成「網路中斷或 CDN 擋人」，並把人指向一個那些紀錄根本沒有的欄位。
                kinds = {r.get("failure_kind") or "http" for r in recent_failures[-5:]}
                what = "／".join(FAILURE_KIND_LABEL.get(k, k) for k in sorted(kinds))
                if kinds <= {"local"}:
                    aborted = (f"連續 {consecutive_failures} 張失敗，而且**都不是 HTTP 錯誤**"
                               f"（{what}）；先停下來，看 {LOG_NAME} 裡這幾筆的 reason"
                               f"（那些紀錄沒有 http_status 可看）")
                elif kinds <= {"content"}:
                    aborted = (f"連續 {consecutive_failures} 張失敗，而且伺服器每次都回 200"
                               f"（{what}）——多半是中間有 proxy／攔截頁，或這個網路擋掉了縮圖主機；"
                               f"先停下來，看 {LOG_NAME} 裡這幾筆的 reason")
                else:
                    aborted = (f"連續 {consecutive_failures} 張失敗（{what}）——"
                               f"網路中斷，或 CDN 改用 403/404 擋人；"
                               f"先停下來，重跑之前請先看 {LOG_NAME} 裡的 http_status 與 reason")
                abort_kind = "failures"
                break
    except Blocked as e:
        aborted = (f"{e}——這個出口 IP 已被 Wikimedia 的圖片 CDN 擋住。"
                   "**不要再試探這個 IP**（每次試探都可能墊高懲罰）。"
                   "換一個網路再跑（換好之後加 --new-network），"
                   "或寄信給 bot-traffic@wikimedia.org 說明量級與用途。")
        abort_kind = "blocked"
    except KeyboardInterrupt:
        aborted = "使用者中斷（Ctrl-C）"
        abort_kind = "interrupt"
    except OSError as e:
        # 磁碟滿／唯讀／沒權限。**不能讓它帶著 traceback 穿出去**——那樣連 summary 都寫不出來，
        # 使用者拿到的是一堆 jpg 加一個 traceback，對不出帳。
        aborted = f"磁碟錯誤：{type(e).__name__}: {e}（已抓到的影像與紀錄都還在）"
        abort_kind = "disk"

    # 中止時把**這一趟計畫裡還沒輪到**的補記成 not_attempted：否則 `summarise` 的那一格
    # 永遠是 0（死鍵），而 `--verify` 也看不出「這一趟還差哪些」。已經成功落地的不動。
    if aborted:
        for c in plan:
            key = str(c.get("pageid"))
            if key in touched:
                continue
            old_rec = log["files"].get(key) or {}
            if old_rec.get("status") in ("ok", "skipped_existing"):
                continue
            log["files"][key] = dict(base_record(c), status="not_attempted",
                                     reason="這一趟中止時還沒輪到",
                                     mirror_status=old_rec.get("mirror_status"),
                                     fail_streak=old_rec.get("fail_streak") or 0,
                                     last_reason=old_rec.get("reason"))

    log["aborted"] = aborted
    log["aborted_kind"] = abort_kind
    log["total_429"] = total_429
    log["run_429"] = run_429
    log["pace_s"] = a.pace           # 被 429 加倍過的話，這裡留下的是最後的步調
    log["mirror_enabled"] = mirror_on
    log["mirror_disabled_reason"] = mirror_disabled
    log["run_mirror_ok"] = run_mirror_ok
    log["run_mirror_miss"] = run_mirror_miss
    # **封鎖狀態是黏性的**：只有這一趟真的被 Wikimedia 擋才寫，而只有 --new-network 會清掉。
    # `--mirror-only` 跑完不會碰到這裡（它不打 Wikimedia），所以上一趟的封鎖原樣留著。
    if abort_kind in ("throttled", "blocked"):
        log["wikimedia_block"] = {"kind": abort_kind, "message": aborted, "at": utcnow()}
    log["summary"] = summarise(log, run_bytes, run_bytes_mirror, run_bytes_wikimedia)
    write_log(log_path, log)

    s = log["summary"]
    sel = selected_candidates(doc)
    on_disk = sum(1 for c in sel if existing_file_ok(os.path.join(a.dir, candidate_filename(c))))
    print("\n" + "=" * 68, file=sys.stderr)
    if aborted:
        print(f"中止：{aborted}", file=sys.stderr)
    print(f"這一趟：成功 {run_ok} 張／失敗 {run_failed} 張／下載 {human_bytes(run_bytes)}"
          f"（計畫 {len(plan)} 張、沒輪到 {s['not_attempted']} 張）", file=sys.stderr)
    if mirror_on or run_mirror_ok:
        # 原圖比縮圖大一個量級，混在一起講的話「打了多少 Wikimedia」就看不出來。
        print(f"  其中鏡像 {run_mirror_ok} 張（{human_bytes(run_bytes_mirror)}，原圖）"
              f"／Wikimedia {run_ok - run_mirror_ok} 張（{human_bytes(run_bytes_wikimedia)}，縮圖）"
              f"；鏡像回 404 的 {run_mirror_miss} 張"
              f"{'（--mirror-only：這些只能之後在沒被擋的網路上走 Wikimedia）' if a.mirror_only else '已回退到 Wikimedia'}",
              file=sys.stderr)
        if mirror_disabled:
            print(f"  鏡像在這一趟中途關閉：{mirror_disabled}", file=sys.stderr)
    print(f"目錄累計：ok {s['ok']}／已有跳過 {s['skipped_existing']}／失敗 {s['failed']}"
          f"／沒輪到 {s['not_attempted']}（目錄共 {human_bytes(s['bytes'])}）", file=sys.stderr)
    print(f"目錄裡現在有 {on_disk} 張，入選總數 {len(sel)} → 還缺 {len(sel) - on_disk} 張",
          file=sys.stderr)
    if log["events_429"]:
        print(f"這一趟被 429 {run_429} 次（最近 {RECENT_429_WINDOW_H:.0f} 小時累計 {total_429}／"
              f"log 裡總共 {len(log['events_429'])} 次）；"
              f"細節在 {LOG_NAME} 的 events_429（寄信給 bot-traffic@wikimedia.org 時附上它）",
              file=sys.stderr)
    stuck = sum(1 for r in log["files"].values()
                if (r.get("fail_streak") or 0) >= FAIL_STREAK_DEMOTE)
    if stuck:
        print(f"{stuck} 張已連續失敗 ≥{FAIL_STREAK_DEMOTE} 次，下一趟會排到最後"
              f"（不佔 --limit／--per-model 的名額）；它們的 reason 在 {LOG_NAME}", file=sys.stderr)
    if run_failed and not aborted:
        print("失敗的可以直接重跑同一行指令續傳（已抓到的會跳過）", file=sys.stderr)

    # **中止且沒抓完時不要印打包指令**：那一段暗示「可以收工了」，而抓到 5/313 就被擋停的那一趟
    # 印出來會讓使用者真的把 5 張帶回去。抓完了（即使結尾是 Ctrl-C）照印。
    finished = (s["ok"] + s["skipped_existing"]) >= len(sel)
    if a.mirror_only and not finished:
        # **鏡像模式跑完 ≠ 抓完**：鏡像凍結在 2013-03，剩下的只能走 Wikimedia。
        # 照印「打包帶回去」會讓使用者把 66 張當成 313 張帶走。
        print(f"\n鏡像能給的都拿完了（目錄裡 {on_disk}／{len(sel)} 張）。"
              f"剩下 {len(sel) - on_disk} 張鏡像上沒有（{MIRROR_FREEZE} 之後上傳），"
              f"要在**沒有被擋的網路**上跑同一行、但**不加** --mirror-only：", file=sys.stderr)
        print(f"  python3 scripts/commons_portable_fetch.py --manifest {a.manifest} "
              f"--dir {a.dir} --pace {DEFAULT_PACE_S:.0f}", file=sys.stderr)
        print(f"  （已經抓到的會跳過；鏡像上已知 404 的那些也不會再問一次鏡像）", file=sys.stderr)
    elif not aborted or finished:
        print("\n下一步——把整個目錄打包帶回去：", file=sys.stderr)
        print(f"  tar czf commons_turbines.tar.gz --exclude='*.part' -C {a.dir} .", file=sys.stderr)
        print("  # 解到 InduSpect 容器的 scratchpad，再跑：", file=sys.stderr)
        print("  python3 scripts/real_pose_validation.py run --manifest data/commons_turbines_manifest.json \\",
              file=sys.stderr)
        print("      --dir <scratch>/commons_turbines --out data/commons_pose_results.json", file=sys.stderr)
        print("  python3 scripts/real_pose_validation.py report   # 重新產 REAL_POSE_VALIDATION.md",
              file=sys.stderr)
        print(f"  （{LOG_NAME} 一起帶回去；帶回去之前可以先 `--verify` 重算一遍 sha256，"
              f"manifest 的 file 欄位不補也行，驗證端找不到時會 fallback 到 c<pageid>.jpg）",
              file=sys.stderr)
    else:
        print(f"\n這一趟沒跑完（還缺 {len(sel) - on_disk} 張），**不要現在打包**——"
              f"先照上面的中止原因處理。", file=sys.stderr)
        if abort_kind in ("throttled", "blocked"):
            print("  被限流／被擋：同一個網路上重跑會被拒（rc=2）。換一個出口 IP 之後，"
                  "在同一行指令加 --new-network 續傳。", file=sys.stderr)
        else:
            print("  處理完之後重跑同一行指令就是續傳（已抓到的會跳過）。", file=sys.stderr)
    return 0 if not aborted else 1


if __name__ == "__main__":
    raise SystemExit(main())
