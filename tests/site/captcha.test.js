// Защита от ботов (Cloudflare Turnstile): с ключом сайт передаёт серверу одноразовый токен при регистрации,
// входе, «Забыли пароль?» и повторном письме; без ключа всё как раньше (это проверяют остальные тесты).
const { chromium } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const DOCS = path.resolve(__dirname, '../../docs');
const SB = 'https://test-nova.supabase.co';
const results = [];
const check = (name, ok, extra) => { results.push((ok ? 'PASS ' : 'FAIL ') + name + (ok || extra === undefined ? '' : ' :: ' + JSON.stringify(extra).slice(0, 300))); };

const server = http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/') p = '/app.html';
  const file = path.join(DOCS, p);
  if (!file.startsWith(DOCS) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
  let body = fs.readFileSync(file);
  if (p === '/app.html') {
    let s = body.toString('utf8').split('https://udnjvgvdiyfafsiqdkox.supabase.co').join(SB);
    s = s.replace(/supabaseKey: '[^']*'/, "supabaseKey: 'sb_publishable_test'").replace(/captchaSiteKey: '[^']*'/, "captchaSiteKey: 'test-site-key'");
    body = Buffer.from(s, 'utf8');
  }
  res.writeHead(200, { 'content-type': p.endsWith('.html') ? 'text/html; charset=utf-8' : p.endsWith('.js') ? 'application/javascript' : 'application/octet-stream' });
  res.end(body);
});

const bodies = {};
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS' };
async function handle(route) {
  const req = route.request();
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
  const ep = new URL(req.url()).pathname.replace('/auth/v1', '');
  let body = {}; try { body = JSON.parse(req.postData() || '{}'); } catch (e) {}
  bodies[ep] = body;
  const json = (status, b) => route.fulfill({ status, headers: { ...CORS, 'content-type': 'application/json' }, body: JSON.stringify(b) });
  if (ep === '/signup') return json(200, { id: 'u1', aud: 'authenticated', email: body.email, email_confirmed_at: null, app_metadata: {}, user_metadata: { name: 'Вадим' }, identities: [{ id: 'u1' }], created_at: new Date().toISOString() });
  if (ep === '/recover') return json(200, {});
  if (ep === '/token') return json(400, { code: 400, error_code: 'invalid_credentials', msg: 'Invalid login credentials' });
  return json(404, { msg: 'not found' });
}

// Поддельный Turnstile: выдаёт токены tok-1, tok-2… или падает, если так попросить.
const FAKE = `window.turnstile = { n: 0, fail: false,
  render: function (el, o) { this.o = o; el.setAttribute('data-sitekey', o.sitekey); return 'w1'; },
  execute: function () { var t = this; setTimeout(function () { if (t.fail) t.o['error-callback'](); else { t.n++; t.o.callback('tok-' + t.n); } }, 20); },
  reset: function () {} };`;

async function hibpNone(route) { return route.fulfill({ status: 200, headers: { 'access-control-allow-origin': '*', 'content-type': 'text/plain' }, body: '0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n' }); }

(async () => {
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + server.address().port;
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1280, height: 860 } });
  await ctx.route(SB + '/**', handle);
  await ctx.route('https://api.pwnedpasswords.com/**', hibpNone);
  let scriptLoads = 0;
  await ctx.route('https://challenges.cloudflare.com/**', route => { scriptLoads++; return route.fulfill({ status: 200, headers: { 'content-type': 'application/javascript' }, body: FAKE }); });
  const p = await ctx.newPage();
  const errors = [];
  p.on('pageerror', e => errors.push(e.message));
  p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push('console: ' + m.text()); });
  try {
    // Регистрация
    await p.goto(base + '/app.html#register');
    await p.waitForSelector('#view-register:not([hidden])');
    await p.waitForTimeout(400);
    await p.fill('#r-name', 'Вадим');
    await p.fill('#r-email', 'vadim@mail.ru');
    await p.fill('#r-pass', 'Nova2026pass');
    await p.fill('#r-pass2', 'Nova2026pass');
    await p.click('#terms-label i');
    await p.click('#form-register [type=submit]');
    await p.waitForSelector('#view-verify:not([hidden])', { timeout: 8000 });
    const sg = bodies['/signup'] || {};
    check('signup sends captcha token', sg.gotrue_meta_security && sg.gotrue_meta_security.captcha_token === 'tok-1', sg.gotrue_meta_security);
    check('turnstile script loaded once from Cloudflare (CSP allows it)', scriptLoads === 1, scriptLoads);
    check('widget got the site key', (await p.getAttribute('.captcha', 'data-sitekey')) === 'test-site-key');

    // «Забыли пароль?»
    await p.evaluate(() => { sessionStorage.clear(); location.hash = '#forgot'; });
    await p.waitForSelector('#view-forgot:not([hidden])');
    await p.waitForTimeout(1300);
    await p.fill('#form-forgot [name=email]', 'vadim@mail.ru');
    await p.click('#form-forgot [type=submit]');
    await p.waitForSelector('#view-verify:not([hidden])', { timeout: 8000 });
    const rc = bodies['/recover'] || {};
    check('recovery sends a fresh captcha token', rc.gotrue_meta_security && rc.gotrue_meta_security.captcha_token === 'tok-2', rc.gotrue_meta_security);

    // Вход
    await p.evaluate(() => { location.hash = '#login'; });
    await p.waitForSelector('#view-login:not([hidden])');
    await p.waitForTimeout(1300);
    await p.fill('#l-email', 'vadim@mail.ru');
    await p.fill('#l-pass', 'Wrong2026pass');
    await p.click('#form-login [type=submit]');
    await p.waitForTimeout(1500);
    const tk = bodies['/token'] || {};
    check('login sends a fresh captcha token', tk.gotrue_meta_security && tk.gotrue_meta_security.captcha_token === 'tok-3', tk.gotrue_meta_security);

    // Проверка не прошла — понятное сообщение
    await p.evaluate(() => { window.turnstile.fail = true; });
    delete bodies['/token'];
    await p.click('#form-login [type=submit]');
    await p.waitForTimeout(1500);
    const t = await p.$$eval('.toast', els => els.map(e => e.textContent).join(' | '));
    check('captcha failure: clear message, nothing sent', t.includes('я не робот') && !bodies['/token'], t);
  } catch (e) { results.push('CRASH ' + e.message.split('\n')[0]); }
  check('no JS errors', errors.length === 0, errors);
  await b.close();
  server.close();
  console.log(results.join('\n'));
  const bad = results.filter(r => !r.startsWith('PASS'));
  console.log(bad.length ? '\nFAILED: ' + bad.length : '\nALL PASS');
  process.exit(bad.length ? 1 : 0);
})();
