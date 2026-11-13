// Аккаунт: «Забыли пароль?», смена пароля, удаление аккаунта. Настоящий режим с имитацией Supabase и демо-режим.
const { chromium, devices } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const DOCS = path.resolve(__dirname, '../../docs');
const OUT = path.join(process.env.NOVA_SHOTS || path.join(require('os').tmpdir(), 'nova-site'), 'account');
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
const users = {}; const calls = []; const files = {}; const mails = [];
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
let sessionNo = 0;
function session(u, method, authAt) {
  const now = Math.floor(Date.now() / 1000);
  const sid = 's' + (++sessionNo);
  u.sessions = (u.sessions || []).concat(sid);
  const jwt = b64url({ alg: 'HS256', typ: 'JWT' }) + '.' + b64url({ sub: u.id, email: u.email, aud: 'authenticated', role: 'authenticated', exp: now + 3600, iat: now, session_id: sid, amr: [{ method, timestamp: authAt || now }] }) + '.c2ln';
  return { access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: 'rt-' + sid, user: userObj(u) };
}
function claims(req) {
  const a = req.headers()['authorization'] || '';
  try { return JSON.parse(Buffer.from(a.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString()); } catch (e) { return {}; }
}
const byId = id => Object.values(users).find(x => x.id === id);
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS' };
const reply = (route, status, body) => route.fulfill({ status, headers: { ...CORS, 'content-type': 'application/json' }, body: body === undefined ? '' : JSON.stringify(body) });
const err = (route, status, code, msg) => reply(route, status, { code: status, error_code: code, msg });

async function handle(route) {
  const req = route.request();
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
  const url = new URL(req.url());
  calls.push(req.method() + ' ' + url.pathname + url.search);
  let body = {}; try { body = JSON.parse(req.postData() || '{}'); } catch (e) {}
  if (url.pathname.startsWith('/storage/v1/')) {
    const sp = url.pathname.replace('/storage/v1/object/', '');
    const sub = claims(req).sub;
    if (req.method() === 'DELETE' && sp === 'avatars') {
      (body.prefixes || []).forEach(p => { if (sub && p.split('/')[0] === sub) delete files[p]; });
      return reply(route, 200, []);
    }
    return reply(route, 404, { message: 'no ' + sp });
  }
  if (url.pathname === '/rest/v1/rpc/delete_my_account') {
    // Как supabase/account.sql: только свой аккаунт и только сразу после ввода пароля.
    const c = claims(req), me = byId(c.sub);
    const fresh = (c.amr || []).some(a => a.timestamp > Date.now() / 1000 - 600);
    if (!me) return reply(route, 401, { code: '28000', message: 'not authenticated' });
    if (!fresh) return reply(route, 400, { code: '28000', message: 'reauthentication required' });
    if (files[me.id + '/avatar.jpg']) return reply(route, 409, { message: 'avatar must be removed first' });
    delete users[me.email];
    return route.fulfill({ status: 204, headers: CORS });
  }
  const ep = url.pathname.replace('/auth/v1', '');
  const email = (body.email || '').toLowerCase();
  const u = users[email];
  if (ep === '/signup') {
    const nu = users[email] = { id: '7f1c2a90-0000-4000-8000-00000000000' + (Object.keys(users).length + 1), email, password: body.password, meta: Object.assign({}, body.data), confirmed: false, code: '482913' };
    return reply(route, 200, userObj(nu));
  }
  if (ep === '/recover') {
    // Настоящий сервер не говорит, есть ли такой аккаунт: ответ одинаковый.
    if (u) { u.recovery = '771204'; mails.push({ email, kind: 'recovery' }); }
    return reply(route, 200, {});
  }
  if (ep === '/verify') {
    if (body.type === 'recovery') {
      if (!u || body.token !== u.recovery) return err(route, 403, 'otp_expired', 'Token has expired or is invalid');
      u.recovery = null; return reply(route, 200, session(u, 'otp'));
    }
    if (!u || body.token !== u.code) return err(route, 403, 'otp_expired', 'Token has expired or is invalid');
    u.confirmed = true; return reply(route, 200, session(u, 'otp'));
  }
  if (ep === '/token') {
    if (!u || u.password !== body.password) return err(route, 400, 'invalid_credentials', 'Invalid login credentials');
    return reply(route, 200, session(u, 'password'));
  }
  if (ep === '/user' && req.method() === 'PUT') {
    const me = byId(claims(req).sub);
    if (!me) return err(route, 401, 'bad_jwt', 'invalid JWT');
    if (body.password) {
      if (body.password === me.password) return err(route, 422, 'same_password', 'New password should be different from the old password.');
      me.password = body.password;
      mails.push({ email: me.email, kind: 'password-changed' });
    }
    Object.entries(body.data || {}).forEach(([k, v]) => { me.meta[k] = v; });
    return reply(route, 200, userObj(me));
  }
  if (ep === '/user') {
    const me = byId(claims(req).sub);
    return me ? reply(route, 200, userObj(me)) : err(route, 401, 'bad_jwt', 'invalid JWT');
  }
  if (ep === '/logout') {
    const c = claims(req), me = byId(c.sub);
    if (me && url.searchParams.get('scope') === 'others') me.sessions = me.sessions.filter(s => s === c.session_id);
    return reply(route, 204);
  }
  return err(route, 404, 'not_found', 'not found ' + ep);
}

const toasts = p => p.$$eval('.toast', els => els.map(e => e.textContent).join(' | '));
async function typeCode(p, code) {
  await p.click('#otp input:nth-of-type(1)');
  await p.keyboard.type(code);
}

async function register(p) {
  await p.goto(p.__base + '/app.html#register');
  await p.waitForSelector('#view-register:not([hidden])');
  await p.waitForTimeout(400);
  await p.fill('#r-name', 'Вадим');
  await p.fill('#r-email', 'vadim@mail.ru');
  await p.fill('#r-pass', 'Nova2026pass');
  await p.fill('#r-pass2', 'Nova2026pass');
  await p.click('#terms-label i');
  check(p.__tag + ' terms checkbox ticks', await p.$eval('#form-register [name=terms]', c => c.checked));
  check(p.__tag + ' terms link to privacy page', (await p.getAttribute('#terms-label a', 'href')) === 'privacy.html');
  await p.click('#form-register [type=submit]');
  await p.waitForSelector('#view-verify:not([hidden])', { timeout: 6000 });
  let code = '482913';
  if (MODE === 'demo') {
    await p.waitForSelector('.toast .code', { timeout: 6000 });
    code = (await p.textContent('.toast .code')).replace(/\s/g, '');
  }
  await typeCode(p, code);
  await p.waitForSelector('#verify-btn:has-text("Перейти в кабинет")', { timeout: 8000 });
  await p.click('#verify-btn');
  await p.waitForSelector('#dash:not([hidden])', { timeout: 5000 });
  await p.waitForTimeout(600);
}

async function logout(p) {
  await p.locator('[data-logout]:visible').first().click();
  await p.waitForSelector('#view-login:not([hidden])', { timeout: 5000 });
  await p.waitForTimeout(1300);
}

async function forgotFlow(p, T) {
  // Прямой заход на «новый пароль» без кода — нельзя.
  await p.goto(p.__base + '/app.html#newpass');
  await p.waitForTimeout(1500);
  check(T + ' #newpass without code -> login', !(await p.isHidden('#view-login')) && await p.isHidden('#view-newpass'));

  await p.fill('#l-email', 'vadim@mail.ru');
  await p.click('#view-login a[href="#forgot"]');
  await p.waitForSelector('#view-forgot:not([hidden])', { timeout: 4000 });
  await p.waitForTimeout(700);
  check(T + ' forgot prefilled from login', (await p.inputValue('#f-email')) === 'vadim@mail.ru');
  await p.fill('#f-email', 'плохая почта');
  await p.click('#form-forgot [type=submit]');
  check(T + ' forgot bad email error', (await p.textContent('#view-forgot .err')).includes('Введи почту'));
  await p.fill('#f-email', 'vadim@mail.ru');
  await p.screenshot({ path: `${OUT}/${T}-1-forgot.png` });
  await p.click('#form-forgot [type=submit]');
  await p.waitForSelector('#view-verify:not([hidden])', { timeout: 6000 });
  await p.waitForTimeout(700);
  check(T + ' verify title says new password', (await p.textContent('#v-title')).includes('нового пароля'));
  check(T + ' back link goes to forgot', (await p.getAttribute('#v-back', 'href')) === '#forgot');
  let code = '771204';
  if (MODE === 'real') {
    check(T + ' recovery mail sent', mails.some(m => m.kind === 'recovery' && m.email === 'vadim@mail.ru'));
    check(T + ' toast does not confirm account exists', (await toasts(p)).includes('Если аккаунт с почтой'), await toasts(p));
    await typeCode(p, '000000');
    await p.waitForFunction(() => document.querySelector('#otp-err').textContent.length > 0, null, { timeout: 6000 });
    check(T + ' wrong recovery code rejected', (await p.textContent('#otp-err')).includes('Код не подошёл'), await p.textContent('#otp-err'));
    await p.waitForTimeout(800);
  } else {
    await p.waitForSelector('.toast .code', { timeout: 6000 });
    check(T + ' demo toast says new password code', (await toasts(p)).includes('Код для нового пароля'));
    code = (await p.textContent('.toast .code')).replace(/\s/g, '');
  }
  await p.screenshot({ path: `${OUT}/${T}-2-code.png` });
  await typeCode(p, code);
  await p.waitForSelector('#view-newpass:not([hidden])', { timeout: 9000 });
  await p.waitForTimeout(700);
  check(T + ' newpass shows email', (await p.textContent('#np-email')) === 'vadim@mail.ru');
  await p.fill('#np-pass', 'onlyletters');
  await p.fill('#np-pass2', 'onlyletters');
  await p.click('#form-newpass [type=submit]');
  check(T + ' newpass weak rejected', (await p.textContent('#view-newpass .err')).includes('латинские буквы'));
  await p.fill('#np-pass', 'Nova2027new');
  await p.fill('#np-pass2', 'Nova2027neW');
  await p.click('#form-newpass [type=submit]');
  check(T + ' newpass mismatch rejected', (await p.$$eval('#view-newpass .err', e => e.map(x => x.textContent).join('|'))).includes('не совпадают'));
  await p.fill('#np-pass2', 'Nova2027new');
  await p.screenshot({ path: `${OUT}/${T}-3-newpass.png` });
  await p.click('#form-newpass [type=submit]');
  await p.waitForSelector('#dash:not([hidden])', { timeout: 6000 });
  await p.waitForTimeout(500);
  check(T + ' password changed toast', (await toasts(p)).includes('Пароль изменён'), await toasts(p));
  if (MODE === 'real') {
    const me = users['vadim@mail.ru'];
    check(T + ' server password updated', me.password === 'Nova2027new');
    check(T + ' other sessions closed', calls.some(c => c.startsWith('POST /auth/v1/logout?scope=others')) && me.sessions.length === 1, me.sessions);
    check(T + ' changed-notification mail', mails.some(m => m.kind === 'password-changed'));
  }
  // Повторный заход на #newpass после смены — уже нельзя.
  await p.evaluate(() => { location.hash = 'newpass'; });
  await p.waitForTimeout(1300);
  check(T + ' #newpass closed after change', await p.isHidden('#view-newpass') && !(await p.isHidden('#dash')));

  if (MODE === 'real') {
    // Незнакомая почта: ответ такой же, как для своей.
    await logout(p);
    const before = mails.length;
    await p.goto(p.__base + '/app.html#forgot');
    await p.waitForSelector('#view-forgot:not([hidden])');
    await p.waitForTimeout(500);
    await p.fill('#f-email', 'nobody@mail.ru');
    await p.click('#form-forgot [type=submit]');
    await p.waitForSelector('#view-verify:not([hidden])', { timeout: 6000 });
    await p.waitForTimeout(600);
    check(T + ' unknown email: same screen, no mail', mails.length === before && (await toasts(p)).includes('Если аккаунт с почтой nobody@mail.ru есть'));
    // Вход: старый пароль не подходит, новый подходит.
    await p.goto(p.__base + '/app.html#login');
    await p.waitForSelector('#view-login:not([hidden])');
    await p.waitForTimeout(700);
    await p.fill('#l-email', 'vadim@mail.ru');
    await p.fill('#l-pass', 'Nova2026pass');
    await p.click('#form-login [type=submit]');
    await p.waitForFunction(() => /Неверная/.test(document.querySelector('#view-login').textContent), null, { timeout: 5000 });
    check(T + ' old password no longer works', true);
    await p.fill('#l-pass', 'Nova2027new');
    await p.click('#form-login [type=submit]');
    await p.waitForSelector('#dash:not([hidden])', { timeout: 6000 });
    check(T + ' new password works', true);
    await p.waitForTimeout(600);
  }
}

async function changePasswordFlow(p, T) {
  await p.locator('[data-profile]:visible').first().click();
  await p.waitForSelector('.profile-modal');
  await p.waitForTimeout(400);
  await p.screenshot({ path: `${OUT}/${T}-4-profile.png` });
  await p.click('[data-pane="pass"]');
  check(T + ' pass pane open', !(await p.isHidden('#pane-pass')) && await p.isHidden('.p-form'));
  await p.click('[data-pass-ok]');
  check(T + ' empty current rejected', (await p.textContent('#pane-pass .err')).includes('текущий пароль'));
  await p.fill('#pp-cur', 'Nova2027new');
  await p.fill('#pp-new', 'Nova2027new');
  await p.fill('#pp-new2', 'Nova2027new');
  await p.click('[data-pass-ok]');
  check(T + ' same password rejected', (await p.$$eval('#pane-pass .err', e => e.map(x => x.textContent).join('|'))).includes('отличаться'));
  if (MODE === 'real') {
    await p.fill('#pp-cur', 'WrongPass1');
    await p.fill('#pp-new', 'Nova2028best');
    await p.fill('#pp-new2', 'Nova2028best');
    await p.click('[data-pass-ok]');
    await p.waitForFunction(() => /неверный/.test(document.querySelector('#pane-pass').textContent), null, { timeout: 5000 });
    check(T + ' wrong current password rejected', users['vadim@mail.ru'].password === 'Nova2027new');
  }
  await p.fill('#pp-cur', 'Nova2027new');
  await p.fill('#pp-new', 'Nova2028best');
  await p.fill('#pp-new2', 'Nova2028best');
  await p.screenshot({ path: `${OUT}/${T}-5-change.png` });
  await p.click('[data-pass-ok]');
  await p.waitForSelector('.profile-modal', { state: 'detached', timeout: 6000 });
  await p.waitForTimeout(300);
  check(T + ' change toast', (await toasts(p)).includes('Пароль изменён'));
  if (MODE === 'real') check(T + ' server has new password', users['vadim@mail.ru'].password === 'Nova2028best');
}

async function deleteFlow(p, T) {
  let me = users['vadim@mail.ru'];
  if (MODE === 'real') files[me.id + '/avatar.jpg'] = Buffer.from('jpeg');
  await p.locator('[data-profile]:visible').first().click();
  await p.waitForSelector('.profile-modal');
  await p.waitForTimeout(300);
  await p.click('[data-pane="del"]');
  check(T + ' delete pane open', !(await p.isHidden('#pane-del')));
  await p.click('[data-pane-back]:visible');
  check(T + ' back returns to profile', !(await p.isHidden('.p-form')) && await p.isHidden('#pane-del'));
  await p.click('[data-pane="del"]');
  await p.click('[data-del-ok]');
  check(T + ' delete needs password', (await p.textContent('#pane-del .err')).includes('Введи пароль'));
  if (MODE === 'real') {
    const rpcBefore = calls.filter(c => c.includes('delete_my_account')).length;
    await p.fill('#pd-pass', 'WrongPass1');
    await p.click('[data-del-ok]');
    await p.waitForFunction(() => /неверный/.test(document.querySelector('#pane-del').textContent), null, { timeout: 5000 });
    check(T + ' wrong password: nothing deleted', !!users['vadim@mail.ru'] && calls.filter(c => c.includes('delete_my_account')).length === rpcBefore && !!files[me.id + '/avatar.jpg']);
  }
  await p.fill('#pd-pass', 'Nova2028best');
  await p.screenshot({ path: `${OUT}/${T}-6-delete.png` });
  await p.click('[data-del-ok]');
  await p.waitForSelector('#view-register:not([hidden])', { timeout: 8000 });
  await p.waitForTimeout(600);
  check(T + ' deleted toast', (await toasts(p)).includes('Аккаунт удалён'), await toasts(p));
  const stored = await p.evaluate(() => [localStorage.getItem('nova.user'), sessionStorage.getItem('nova.user'), localStorage.getItem('nova.activity')]);
  check(T + ' local session cleared', stored.every(x => x === null), stored);
  if (MODE === 'real') {
    const iDel = calls.findIndex(c => c.startsWith('DELETE /storage/v1/object/avatars'));
    const iRpc = calls.findIndex(c => c.startsWith('POST /rest/v1/rpc/delete_my_account'));
    check(T + ' photo removed before account', iDel > -1 && iRpc > iDel, calls.slice(-8));
    check(T + ' account gone on server', !users['vadim@mail.ru'] && !files[me.id + '/avatar.jpg']);
    const keys = await p.evaluate(() => Object.keys(localStorage).filter(k => k.startsWith('sb-')));
    check(T + ' supabase session removed', keys.length === 0, keys);
    await p.goto(p.__base + '/app.html#login');
    await p.waitForSelector('#view-login:not([hidden])');
    await p.waitForTimeout(700);
    await p.fill('#l-email', 'vadim@mail.ru');
    await p.fill('#l-pass', 'Nova2028best');
    await p.click('#form-login [type=submit]');
    await p.waitForFunction(() => /Неверная/.test(document.querySelector('#view-login').textContent), null, { timeout: 5000 });
    check(T + ' cannot log in after delete', true);
  } else {
    const prof = await p.evaluate(() => JSON.parse(localStorage.getItem('nova.profiles') || '{}'));
    check(T + ' demo profile wiped', !prof['vadim@mail.ru'], prof);
  }
}

module.exports = { server, handle, users, files, SB };
if (require.main === module) (async () => {
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + server.address().port;
  for (const mode of ['real', 'demo']) {
    MODE = mode;
    for (const [tag, opts] of [['phone', { ...devices['iPhone 13'] }], ['desktop', { viewport: { width: 1360, height: 860 }, deviceScaleFactor: 1 }]]) {
      for (const k of Object.keys(users)) delete users[k];
      for (const k of Object.keys(files)) delete files[k];
      calls.length = 0; mails.length = 0;
      const b = await chromium.launch();
      const ctx = await b.newContext(opts);
      await ctx.route(SB + '/**', handle);
      const p = await ctx.newPage(); p.__base = base;
      const T = mode + '-' + tag; p.__tag = T;
      const errors = [];
      p.on('pageerror', e => errors.push(e.message));
      p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push('console: ' + m.text()); });
      try {
        await register(p);
        await logout(p);
        await forgotFlow(p, T);
        await changePasswordFlow(p, T);
        await deleteFlow(p, T);
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
