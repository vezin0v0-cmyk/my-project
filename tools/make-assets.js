// Рисует обои и логотип Nova из tools/assets/wallpaper.html.
// Нужны Node.js, Playwright и ffmpeg:  node tools/make-assets.js
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const PAGE = 'file://' + path.join(__dirname, 'assets', 'wallpaper.html');
const OUT = path.join(ROOT, 'assets');

async function render(browser, query, width, height, file) {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
  await page.goto(PAGE + '?' + query);
  await page.waitForFunction(() => document.title === 'ready');
  await page.screenshot({ path: file });
  await page.close();
}

(async () => {
  fs.mkdirSync(path.join(OUT, 'wallpaper'), { recursive: true });
  fs.mkdirSync(path.join(OUT, 'oem'), { recursive: true });
  const browser = await chromium.launch();
  const tmpWall = path.join(OUT, 'wallpaper', 'tmp.png');
  const tmpLogo = path.join(OUT, 'oem', 'tmp.png');
  await render(browser, 'w=3840&h=2160', 3840, 2160, tmpWall);
  await render(browser, 'mode=logo&w=120&h=120', 120, 120, tmpLogo);
  await browser.close();
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', tmpWall, '-q:v', '3', path.join(OUT, 'wallpaper', 'nova-dark.jpg')]);
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', tmpLogo, '-pix_fmt', 'bgr24', path.join(OUT, 'oem', 'nova-logo.bmp')]);
  fs.unlinkSync(tmpWall);
  fs.unlinkSync(tmpLogo);
  console.log('Готово: assets/wallpaper/nova-dark.jpg и assets/oem/nova-logo.bmp');
})();
