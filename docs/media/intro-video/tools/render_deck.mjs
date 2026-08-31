// 將 deck.html 的每一張投影片渲染為 3840×2160 PNG（2x），
// 之後由 ffmpeg 降採樣到 1080p，讓文字保持銳利。
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const { chromium } = pw;
import fs from 'fs';
import { execFileSync } from 'child_process';

const BASE = process.argv[2] || 'http://127.0.0.1:8081/deck.html';
const OUT = process.argv[3] || './frames';
fs.mkdirSync(OUT, { recursive: true });

const cleanEnv = { ...process.env };
for (const k of ['HTTPS_PROXY', 'HTTP_PROXY', 'https_proxy', 'http_proxy']) delete cleanEnv[k];

const browser = await chromium.launch({
  env: cleanEnv,
  args: ['--font-render-hinting=none', '--force-color-profile=srgb'],
});
const ctx = await browser.newContext({
  viewport: { width: 1920, height: 1080 },
  deviceScaleFactor: 2,
  locale: 'zh-TW',
});

// Google Fonts（CSS + woff2）→ 由 curl 經代理取回
const cache = new Map();
await ctx.route(/https:\/\/fonts\.(googleapis|gstatic)\.com\/.*/, async (route) => {
  const url = route.request().url();
  try {
    if (!cache.has(url)) {
      const buf = execFileSync(
        'curl',
        ['-sL', '--max-time', '30', '-A', 'Mozilla/5.0 Chrome/140 Safari/537.36', url],
        { maxBuffer: 96 * 1024 * 1024 },
      );
      cache.set(url, buf);
    }
    await route.fulfill({
      status: 200,
      body: cache.get(url),
      headers: {
        'content-type': url.includes('googleapis') ? 'text/css; charset=utf-8' : 'font/woff2',
        'access-control-allow-origin': '*',
      },
    });
  } catch (e) {
    console.log('  [font] 失敗', url.slice(-40));
    await route.abort();
  }
});

const page = await ctx.newPage();
await page.goto(BASE, { waitUntil: 'networkidle', timeout: 90000 });
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(2500);

const ids = await page.evaluate(() =>
  [...document.querySelectorAll('section.slide')].map((s) => s.id),
);
console.log(`共 ${ids.length} 張投影片：${ids.join(', ')}`);

for (let i = 0; i < ids.length; i++) {
  const id = ids[i];
  const el = page.locator(`#${id}`);
  await el.scrollIntoViewIfNeeded();
  await page.waitForTimeout(350);
  const name = `${OUT}/slide-${String(i + 1).padStart(2, '0')}.png`;
  await el.screenshot({ path: name });
  const box = await el.boundingBox();
  console.log(
    `  ✓ ${name}  ${(fs.statSync(name).size / 1024 / 1024).toFixed(2)} MB  (CSS ${box.width}×${box.height})`,
  );
}

await browser.close();
console.log('完成');
