// 以 Playwright 擷取 InduSpect Flutter Web 的關鍵功能畫面
// 用法：node shoot.mjs <baseUrl> <outDir>
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const { chromium } = pw;
import fs from 'fs';
import { execFileSync } from 'child_process';

const BASE = process.argv[2] || 'http://127.0.0.1:8080';
const OUT = process.argv[3] || './shots';
fs.mkdirSync(OUT, { recursive: true });

const VIEWPORT = { width: 412, height: 892 }; // 近似 Pixel 直立

async function settle(page, ms = 2500) {
  await page.waitForTimeout(ms);
}

/** 啟用 Flutter 語意樹，讓畫面元素進入 DOM（可用文字選取器） */
async function enableSemantics(page) {
  try {
    const ph = page.locator('flt-semantics-placeholder');
    if (await ph.count()) {
      await ph.first().click({ force: true, timeout: 3000 });
      await page.waitForTimeout(1200);
      return true;
    }
  } catch (e) {
    console.log('  (semantics placeholder 不可點:', e.message.split('\n')[0], ')');
  }
  return false;
}

async function shot(page, name, note) {
  const path = `${OUT}/${name}.png`;
  await page.screenshot({ path });
  const size = (fs.statSync(path).size / 1024).toFixed(0);
  console.log(`  ✓ ${name}.png (${size} KB) — ${note}`);
}

/** 列出目前語意樹中可見的文字（除錯 / 驗證畫面確實變了） */
async function dumpTexts(page, limit = 14) {
  const texts = await page.evaluate(() => {
    const out = [];
    document.querySelectorAll('flt-semantics').forEach((el) => {
      const label = el.getAttribute('aria-label') || el.textContent || '';
      const t = label.trim();
      if (t && t.length < 40) out.push(t);
    });
    return [...new Set(out)];
  });
  console.log('  texts:', texts.slice(0, limit).join(' | ') || '(無語意節點)');
  return texts;
}

async function clickByText(page, text) {
  // 先試語意樹（aria-label），再試任意含該文字的元素
  const bySem = page.locator(`flt-semantics[aria-label*="${text}"]`);
  if (await bySem.count()) {
    await bySem.first().click({ force: true });
    return true;
  }
  const byText = page.getByText(text, { exact: false });
  if (await byText.count()) {
    await byText.first().click({ force: true });
    return true;
  }
  return false;
}

(async () => {
  // Chromium 不走代理（此環境的 relay 不接受 plain-HTTP，會擋掉本機 App 伺服器）。
  // 外部資源改用攔截：
  //   - www.gstatic.com/flutter-canvaskit/** → 餵本機建置產物裡的 canvaskit
  //   - fonts.gstatic.com/**                → 交由 curl（吃 HTTPS_PROXY）取回 Noto CJK fallback
  const cleanEnv = { ...process.env };
  for (const k of ['HTTPS_PROXY', 'HTTP_PROXY', 'https_proxy', 'http_proxy', 'ALL_PROXY', 'all_proxy']) {
    delete cleanEnv[k];
  }
  const browser = await chromium.launch({
    args: ['--font-render-hinting=none', '--force-color-profile=srgb'],
    env: cleanEnv,
  });
  const ctx = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: 2,
    locale: 'zh-TW',
    ignoreHTTPSErrors: true,
    // 預先寫入 SharedPreferences（web = localStorage，前綴 flutter.）
    // 放入示範用假 key，讓歡迎卡顯示「已設定」狀態而非試用倒數；不會發出任何 API 呼叫
    storageState: {
      cookies: [],
      origins: [
        {
          origin: BASE.replace(/\/$/, ''),
          localStorage: [
            { name: 'flutter.gemini_api_key', value: 'demo-key-for-screenshots' },
            { name: 'flutter.selected_model', value: 'gemini-3.6-flash' },
            { name: 'flutter.usage_count', value: '0' },
          ],
        },
      ],
    },
  });
  // CanvasKit：CDN 不可達 → 用本機建置產物（build/web/canvaskit/...）
  const CANVASKIT_DIR = process.env.CANVASKIT_DIR;
  const MIME = { '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json' };
  await ctx.route(/https:\/\/www\.gstatic\.com\/flutter-canvaskit\/.*/, async (route) => {
    const url = new URL(route.request().url());
    // /flutter-canvaskit/<engineRevision>/<rest...>
    const rest = url.pathname.split('/').slice(3).join('/');
    const local = `${CANVASKIT_DIR}/${rest}`;
    if (CANVASKIT_DIR && fs.existsSync(local)) {
      const ext = local.slice(local.lastIndexOf('.'));
      console.log(`  [canvaskit] 本機供應 ${rest}`);
      await route.fulfill({
        status: 200,
        body: fs.readFileSync(local),
        headers: {
          'content-type': MIME[ext] || 'application/octet-stream',
          'access-control-allow-origin': '*',
        },
      });
    } else {
      console.log('  [canvaskit] 找不到本機檔案:', local);
      await route.abort();
    }
  });

  // 外部字型（Roboto / Noto CJK fallback）→ 由 curl 經代理取回
  const fontCache = new Map();
  await ctx.route(/https:\/\/fonts\.(gstatic|googleapis)\.com\/.*/, async (route) => {
    const url = route.request().url();
    try {
      if (!fontCache.has(url)) {
        const buf = execFileSync('curl', ['-sL', '--max-time', '25', url], {
          maxBuffer: 64 * 1024 * 1024,
        });
        fontCache.set(url, buf);
        console.log(`  [font] ${(buf.length / 1024).toFixed(0)} KB ← ${url.slice(-52)}`);
      }
      await route.fulfill({
        status: 200,
        body: fontCache.get(url),
        headers: {
          'content-type': url.includes('css') ? 'text/css' : 'font/ttf',
          'access-control-allow-origin': '*',
        },
      });
    } catch (e) {
      console.log('  [font] 取得失敗:', url.slice(-48), e.message.split('\n')[0]);
      await route.abort();
    }
  });

  const page = await ctx.newPage();
  page.on('console', (m) => {
    const t = m.text();
    if (/error|exception|failed/i.test(t)) console.log('  [browser]', t.slice(0, 160));
  });

  console.log(`→ 載入 ${BASE}`);
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 90000 });
  await settle(page, 5000);
  await enableSemantics(page);
  await settle(page, 1500);

  console.log('[1] Dashboard');
  await dumpTexts(page);
  await shot(page, '01-dashboard', '主頁：2 大入口 + 統計 + 最近檢測');

  // 命名路由（Flutter web 預設 hash 策略）
  for (const [hash, name, note] of [
    ['#/settings', '02-settings', '設定：API Key + 模型選擇（GA 版）'],
    ['#/guide', '03-guide', '使用說明'],
    ['#/history', '04-history', '歷史紀錄：搜尋 / 編輯 / 重新分享'],
  ]) {
    console.log(`[${name}] ${hash}`);
    await page.goto(`${BASE}/${hash}`, { waitUntil: 'domcontentloaded' });
    await settle(page, 3000);
    await enableSemantics(page);
    await settle(page, 1200);
    await dumpTexts(page);
    await shot(page, name, note);
  }

  // 核心檢測流程（非命名路由，需從主頁點入）
  console.log('[5] 檢測流程 Step 1');
  await page.goto(BASE, { waitUntil: 'networkidle' });
  await settle(page, 4000);
  await enableSemantics(page);
  await settle(page, 1500);
  // 語意樹不可用 → 直接點「開始檢測」全寬卡片中心（CSS px；截圖為 2x）
  await page.mouse.click(VIEWPORT.width / 2, 390);
  await settle(page, 3500);
  await enableSemantics(page);
  await settle(page, 1200);
  await dumpTexts(page);
  await shot(page, '05-inspection-step1', '核心：上傳定檢表（5 步驟流程起點）');

  await browser.close();
  console.log('\n完成。輸出目錄：' + OUT);
})().catch((e) => {
  console.error('FAILED:', e);
  process.exit(1);
});
