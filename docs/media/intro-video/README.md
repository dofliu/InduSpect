# 3 分鐘專案介紹影片 — 產出流程

本目錄保存介紹影片的**可重現來源**（投影片、旁白、腳本）。
影片檔本身（約 34 MB）不入版控，請放到 Release assets 或雲端硬碟。

| 檔案 | 用途 |
|------|------|
| `deck.html` | 11 張投影片來源（1920×1080/張），引用 `../screenshots/` 的真實 App 截圖 |
| `narration.md` | 旁白腳本，逐段對齊投影片切換點（供配音或現場口述） |
| `narration.srt` | 字幕檔（29 條），可掛載或燒進影片 |
| `tools/shoot.mjs` | 由 Flutter Web 建置產物擷取 App 真實畫面 |
| `tools/render_deck.mjs` | 將每張投影片渲染為 3840×2160 PNG（2x） |
| `tools/assemble.py` | ffmpeg 合成 180.0 秒 1080p H.264（交叉淡入 + 緩慢推近） |

規格：1920×1080 / 30fps / **180.0 秒** / H.264 + yuv420p / 無聲。

---

## 重新產出

### 0. 前置

```bash
# Flutter SDK、Node 22（含 playwright）、Python 3.11
pip install imageio-ffmpeg     # 提供完整靜態 ffmpeg（含 libx264 / xfade / zoompan）
```

### 1. 擷取 App 真實畫面

```bash
cd flutter_app && touch .env && flutter build web --release
cd build/web && npx http-server -p 8080 -s --cors &

cd docs/media/intro-video/tools
CANVASKIT_DIR=<repo>/flutter_app/build/web/canvaskit \
  node shoot.mjs http://127.0.0.1:8080 <repo>/docs/media/screenshots
```

擷取：主頁、設定、使用說明、歷史紀錄（手機直立 412×892 @2x）。

> **環境注意**：離線／受限網路環境下有兩個坑，`shoot.mjs` 已內建處理——
> ① Flutter Web 預設從 `www.gstatic.com` 抓 CanvasKit，不可達時整頁空白 → 腳本改餵建置產物內的本機 canvaskit（需 `CANVASKIT_DIR`）；
> ② 中文字型 fallback 來自 `fonts.gstatic.com`，取不到會變成豆腐字 → 腳本攔截該網域並交由 `curl`（吃 `HTTPS_PROXY`）代取。
>
> **已知限制**：`FormInspectionScreen` 在 Web 上會因 `sqflite` / `path_provider` 無 Web 實作而初始化失敗（產品目標為 Android，不影響實機）。因此檢測流程頁無法用 Web 擷圖，投影片以 App 內建「使用說明」頁替代呈現五步驟。

### 2. 渲染投影片

```bash
cd docs/media && npx http-server -p 8081 -s --cors &
cd intro-video/tools
node render_deck.mjs http://127.0.0.1:8081/intro-video/deck.html ./frames
```

4K 渲染再由 ffmpeg 降採樣到 1080p，避免推近時文字變模糊。

### 3. 合成影片

```bash
python3 assemble.py ./frames ./InduSpect_intro_3min.mp4
```

每張投影片秒數定義在 `assemble.py` 的 `DURATIONS`（總和須為 180）。

---

## 內容更新須知

- 影片中的數字（測試數量、法規條數、判定案例）皆為實測值。改動程式後請重跑測試並同步 `deck.html` 第 8 張的數據與終端輸出。
- 換 App 截圖：重跑步驟 1 即可，`deck.html` 以檔名引用。
- 影片為無聲版本（此環境無可用中文 TTS）。配音後可用 `ffmpeg -i video.mp4 -i voice.m4a -c:v copy -shortest out.mp4` 合軌。
