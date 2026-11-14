// Профиль: фото, имя, о себе, цвет. Настоящий режим — с имитацией Supabase (auth + storage), и демо-режим.
const { chromium, devices } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const DOCS = path.resolve(__dirname, '../../docs');
const OUT = path.join(process.env.NOVA_SHOTS || path.join(require('os').tmpdir(), 'nova-site'), 'profile');
let PHOTO = null; // снимок с узором: создаётся в начале проверки, чтобы не хранить фото в проекте
fs.mkdirSync(OUT, { recursive: true });
const SB = 'https://test-nova.supabase.co';
const results = [];
const check = (name, ok, extra) => { results.push((ok ? 'PASS ' : 'FAIL ') + name + (ok || extra === undefined ? '' : ' :: ' + JSON.stringify(extra).slice(0, 300))); };

let MODE = 'real';
const server = http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/') p = '/app.html';
  const file = path.join(DOCS, p);
  if (!file.startsWith(DOCS) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
  let body = fs.readFileSync(file);
  if (p === '/app.html') {
    let s = body.toString('utf8');
    const url = MODE === 'real' ? SB : '', key = MODE === 'real' ? 'sb_publishable_test' : '';
    s = s.split('https://udnjvgvdiyfafsiqdkox.supabase.co').join(SB);
    s = s.replace(/supabaseUrl: '[^']*'/, "supabaseUrl: '" + url + "'").replace(/supabaseKey: '[^']*'/, "supabaseKey: '" + key + "'");
    body = Buffer.from(s, 'utf8');
  }
  const type = p.endsWith('.html') ? 'text/html; charset=utf-8' : p.endsWith('.js') ? 'application/javascript' : p.endsWith('.jpg') ? 'image/jpeg' : 'application/octet-stream';
  res.writeHead(200, { 'content-type': type });
  res.end(body);
});

// --- имитация Supabase ---
const users = {}; const mails = []; const calls = []; const files = {};
function b64url(o) { return Buffer.from(JSON.stringify(o)).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_'); }
function userObj(u) {
  return {
    id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email,
    email_confirmed_at: u.confirmed ? '2026-11-13T10:00:00Z' : null,
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: Object.assign({ email: u.email, email_verified: !!u.confirmed }, u.meta),
    identities: [{ id: u.id, user_id: u.id, provider: 'email', identity_data: { email: u.email, sub: u.id } }],
    created_at: '2026-11-13T10:00:00Z', updated_at: new Date().toISOString()
  };
}
function session(u) {
  const now = Math.floor(Date.now() / 1000);
  const jwt = b64url({ alg: 'HS256', typ: 'JWT' }) + '.' + b64url({ sub: u.id, email: u.email, aud: 'authenticated', role: 'authenticated', exp: now + 3600, iat: now, session_id: 's-' + u.id }) + '.c2ln';
  return { access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: 'rt-' + u.id, user: userObj(u) };
}
function subFrom(req) {
  const a = req.headers()['authorization'] || '';
  try { return JSON.parse(Buffer.from(a.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString()).sub; } catch (e) { return null; }
}
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS' };
const reply = (route, status, body) => route.fulfill({ status, headers: { ...CORS, 'content-type': 'application/json' }, body: body === undefined ? '' : JSON.stringify(body) });
const err = (route, status, code, msg) => reply(route, status, { code: status, error_code: code, msg });

async function handle(route) {
  const req = route.request();
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
  const url = new URL(req.url());
  calls.push(req.method() + ' ' + url.pathname);
  if (url.pathname.startsWith('/storage/v1/')) {
    const sp = url.pathname.replace('/storage/v1/object/', '');
    if (req.method() === 'GET' && sp.startsWith('public/avatars/')) {
      const f = files[sp.replace('public/avatars/', '')];
      if (!f) return route.fulfill({ status: 404, headers: CORS, body: 'not found' });
      return route.fulfill({ status: 200, headers: { ...CORS, 'content-type': 'image/jpeg' }, body: f });
    }
    const sub = subFrom(req);
    if (req.method() === 'POST' && sp.startsWith('avatars/')) {
      const p = sp.replace('avatars/', '');
      if (!sub || p.split('/')[0] !== sub) return route.fulfill({ status: 403, headers: { ...CORS, 'content-type': 'application/json' }, body: JSON.stringify({ statusCode: '403', error: 'Unauthorized', message: 'new row violates row-level security policy' }) });
      const buf = req.postDataBuffer();
      const start = buf.indexOf(Buffer.from([0xff, 0xd8, 0xff]));
      const end = buf.lastIndexOf(Buffer.from([0xff, 0xd9]));
      files[p] = buf.slice(start, end + 2);
      return reply(route, 200, { Key: 'avatars/' + p, Id: 'f1' });
    }
    if (req.method() === 'DELETE' && sp === 'avatars') {
      const body = JSON.parse(req.postData() || '{}');
      (body.prefixes || []).forEach(p => { if (sub && p.split('/')[0] === sub) delete files[p]; });
      return reply(route, 200, []);
    }
    return reply(route, 404, { message: 'no ' + sp });
  }
  const ep = url.pathname.replace('/auth/v1', '');
  let body = {}; try { body = JSON.parse(req.postData() || '{}'); } catch (e) {}
  const email = (body.email || '').toLowerCase();
  const u = users[email];
  if (ep === '/signup') {
    const nu = users[email] = { id: '7f1c2a90-0000-4000-8000-00000000000' + (Object.keys(users).length + 1), email, password: body.password, meta: Object.assign({}, body.data), confirmed: false, code: '482913' };
    mails.push({ email, code: nu.code });
    return reply(route, 200, userObj(nu));
  }
  if (ep === '/verify') {
    if (!u || body.token !== u.code) return err(route, 403, 'otp_expired', 'Token has expired or is invalid');
    u.confirmed = true; return reply(route, 200, session(u));
  }
  if (ep === '/token') {
    if (!u || u.password !== body.password) return err(route, 400, 'invalid_credentials', 'Invalid login credentials');
    return reply(route, 200, session(u));
  }
  if (ep === '/user' && req.method() === 'PUT') {
    const sub = subFrom(req);
    const me = Object.values(users).find(x => x.id === sub);
    if (!me) return err(route, 401, 'bad_jwt', 'invalid JWT');
    Object.entries(body.data || {}).forEach(([k, v]) => { if (v === null) delete me.meta[k]; else me.meta[k] = v; });
    return reply(route, 200, userObj(me));
  }
  if (ep === '/user') {
    const me = Object.values(users).find(x => x.id === subFrom(req));
    return me ? reply(route, 200, userObj(me)) : err(route, 401, 'bad_jwt', 'invalid JWT');
  }
  if (ep === '/logout') return reply(route, 204);
  return err(route, 404, 'not_found', 'not found ' + ep);
}

async function makePhoto() {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1200, height: 900 } });
  await p.setContent('<body style="margin:0;height:900px;background:repeating-linear-gradient(45deg,#f5b54a 0 14px,#2b1a5a 14px 31px)">' +
    '<div style="position:absolute;left:380px;top:230px;width:420px;height:420px;border-radius:50%;background:radial-gradient(#fff,#3a8 60%,#123)"></div>' +
    '<p style="position:absolute;left:60px;top:40px;font:bold 90px sans-serif;color:#fff">Nova test</p></body>');
  const buf = await p.screenshot({ type: 'jpeg', quality: 92 });
  await b.close();
  return buf;
}

async function register(p) {
  await p.goto(p.__base + '/app.html#register');
  await p.waitForSelector('#view-register:not([hidden])');
  await p.waitForTimeout(400);
  await p.fill('#r-name', 'Вадим');
  await p.fill('#r-email', 'vadim@mail.ru');
  await p.fill('#r-pass', 'Nova2026!pass');
  await p.fill('#r-pass2', 'Nova2026!pass');
  await p.click('#terms-label i');
  await p.click('#form-register [type=submit]');
  await p.waitForSelector('#view-verify:not([hidden])', { timeout: 6000 });
  let code = '482913';
  if (MODE === 'demo') {
    await p.waitForSelector('.toast .code', { timeout: 6000 });
    code = (await p.textContent('.toast .code')).replace(/\s/g, '');
  }
  await p.click('#otp input:nth-of-type(1)');
  await p.keyboard.type(code);
  await p.waitForSelector('#verify-btn:has-text("Перейти в кабинет")', { timeout: 8000 });
  await p.click('#verify-btn');
  await p.waitForSelector('#dash:not([hidden])', { timeout: 5000 });
  await p.waitForTimeout(800);
}

async function profileFlow(p, tag) {
  // открыть профиль: из меню (ПК) или нижней панели (телефон)
  await p.locator('[data-profile]:visible').first().click();
  await p.waitForSelector('.profile-modal', { timeout: 3000 });
  await p.waitForTimeout(400);
  check(tag + ' profile opens with name', (await p.inputValue('#p-name')) === 'Вадим');
  check(tag + ' shows email', (await p.textContent('.p-mail')) === 'vadim@mail.ru');
  check(tag + ' remove hidden without photo', await p.$eval('[data-unphoto]', b => b.hidden));
  await p.screenshot({ path: `${OUT}/${tag}-1-profile.png` });

  // фото
  await p.setInputFiles('.profile-modal input[type=file]', { name: 'photo.jpg', mimeType: 'image/jpeg', buffer: PHOTO });
  await p.waitForSelector('.crop:not([hidden]) canvas', { timeout: 4000 });
  await p.waitForTimeout(300);
  const cv = await p.$('.crop canvas');
  const bb = await cv.boundingBox();
  await p.$eval('.crop input[type=range]', r => { r.value = '1.6'; r.dispatchEvent(new Event('input')); });
  await p.mouse.move(bb.x + bb.width / 2, bb.y + bb.height / 2);
  await p.mouse.down();
  await p.mouse.move(bb.x + bb.width / 2 + 40, bb.y + bb.height / 2 + 10, { steps: 6 });
  await p.mouse.up();
  await p.waitForTimeout(200);
  await p.screenshot({ path: `${OUT}/${tag}-2-crop.png` });
  await p.click('[data-crop-ok]');
  await p.waitForTimeout(300);
  check(tag + ' preview has photo', await p.$eval('#p-ava', el => el.classList.contains('has-img') && !!el.querySelector('img')));
  check(tag + ' remove visible with photo', !(await p.$eval('[data-unphoto]', b => b.hidden)));

  // имя, о себе, цвет
  await p.fill('#p-name', 'Вадим Nova');
  await p.fill('#p-bio', 'Играю в CS2 и настраиваю Windows под себя');
  check(tag + ' bio counter', (await p.textContent('#p-count')) === '41/120', await p.textContent('#p-count'));
  await p.click('.swatches button[title="Небо"]');
  check(tag + ' color selected', await p.$eval('.swatches button[title="Небо"]', b => b.getAttribute('aria-checked') === 'true'));
  await p.screenshot({ path: `${OUT}/${tag}-3-edited.png` });
  await p.click('[data-save]');
  await p.waitForSelector('.profile-modal', { state: 'detached', timeout: 6000 });
  await p.waitForTimeout(800);
  check(tag + ' greeting new name', (await p.textContent('#greet')).includes('Вадим'));
  check(tag + ' sidebar name', (await p.$$eval('.u-name', els => els.map(e => e.textContent))).every(t => t === 'Вадим Nova'));
  check(tag + ' bio shown', (await p.textContent('#u-bio')) === 'Играю в CS2 и настраиваю Windows под себя');
  const imgs = await p.$$eval('.u-ava img', els => els.map(e => ({ src: e.src.slice(0, 60), ok: e.complete && e.naturalWidth > 0, w: e.naturalWidth })));
  check(tag + ' avatars show photo (' + imgs.length + ')', imgs.length >= 2 && imgs.every(i => i.ok), imgs);
  check(tag + ' photo is 384px', imgs.length && imgs[0].w === 384, imgs);
  const toastText = await p.$$eval('.toast', els => els.map(e => e.textContent).join('|'));
  check(tag + ' saved toast', toastText.includes('Профиль сохранён'), toastText);
  await p.screenshot({ path: `${OUT}/${tag}-4-dash.png` });

  if (MODE === 'real') {
    const me = users['vadim@mail.ru'];
    check(tag + ' uploaded to own folder', !!files[me.id + '/avatar.jpg'] && files[me.id + '/avatar.jpg'].length > 5000, Object.keys(files));
    check(tag + ' metadata saved', me.meta.name === 'Вадим Nova' && me.meta.color === 'sky' && me.meta.bio.startsWith('Играю') && me.meta.avatar_url.startsWith(SB + '/storage/v1/object/public/avatars/' + me.id + '/avatar.jpg?v='), me.meta);
  }

  // после перезагрузки всё на месте
  await p.reload();
  await p.waitForTimeout(1500);
  check(tag + ' reload keeps name', (await p.$$eval('.u-name', els => els.map(e => e.textContent))).every(t => t === 'Вадим Nova'));
  check(tag + ' reload keeps photo', await p.$$eval('.u-ava img', els => els.length >= 2 && els.every(e => e.complete && e.naturalWidth > 0)));

  // убрать фото
  await p.locator('[data-profile]:visible').first().click();
  await p.waitForSelector('.profile-modal');
  check(tag + ' reopened keeps color', await p.$eval('.swatches button[title="Небо"]', b => b.getAttribute('aria-checked') === 'true'));
  await p.click('[data-unphoto]');
  check(tag + ' preview back to initials', (await p.textContent('#p-ava')).trim() === 'ВN');
  await p.click('[data-save]');
  await p.waitForSelector('.profile-modal', { state: 'detached', timeout: 6000 });
  await p.waitForTimeout(500);
  check(tag + ' avatar back to initials', (await p.$$eval('.u-ava', els => els.map(e => e.textContent))).every(t => t === 'ВN'));
  if (MODE === 'real') {
    const me = users['vadim@mail.ru'];
    check(tag + ' file deleted', !files[me.id + '/avatar.jpg'] && me.meta.avatar_url === '', { files: Object.keys(files), meta: me.meta });
  }

  // пустое имя не сохраняется, Escape закрывает
  await p.locator('[data-profile]:visible').first().click();
  await p.waitForSelector('.profile-modal');
  await p.fill('#p-name', ' ');
  await p.click('[data-save]');
  check(tag + ' empty name error', (await p.textContent('.profile-modal .err')).includes('2 буквы'));
  await p.keyboard.press('Escape');
  check(tag + ' escape closes', (await p.$('.profile-modal')) === null);
}

(async () => {
  PHOTO = await makePhoto();
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + server.address().port;
  for (const mode of ['real', 'demo']) {
    MODE = mode;
    for (const [tag, opts] of [['phone', { ...devices['iPhone 13'] }], ['desktop', { viewport: { width: 1360, height: 860 }, deviceScaleFactor: 1 }]]) {
      for (const k of Object.keys(users)) delete users[k];
      for (const k of Object.keys(files)) delete files[k];
      const b = await chromium.launch();
      const ctx = await b.newContext(opts);
      await ctx.route(SB + '/**', handle);
      const p = await ctx.newPage(); p.__base = base;
      const errors = [];
      p.on('pageerror', e => errors.push(e.message));
      p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push('console: ' + m.text()); });
      const T = mode + '-' + tag;
      try {
        await register(p);
        await profileFlow(p, T);
      } catch (e) { results.push('CRASH ' + T + ' ' + e.message.split('\n')[0]); await p.screenshot({ path: `${OUT}/${T}-crash.png` }); }
      const overflow = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      check(T + ' no horizontal overflow (' + overflow + ')', overflow <= 0);
      check(T + ' no JS errors', errors.length === 0, errors);
      await b.close();
    }
  }
  server.close();
  console.log(results.join('\n'));
  const failed = results.filter(r => !r.startsWith('PASS')).length;
  console.log(failed ? 'SOME FAILED' : 'ALL PASS');
  process.exitCode = failed ? 1 : 0;
})();
