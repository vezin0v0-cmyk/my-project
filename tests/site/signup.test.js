// Проверка кабинета в «настоящем» режиме: сайт ходит в Supabase, а Supabase здесь — имитация.
const { chromium, devices } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const DOCS = path.resolve(__dirname, '../../docs');
const OUT = path.join(process.env.NOVA_SHOTS || path.join(require('os').tmpdir(), 'nova-site'), 'signup');
fs.mkdirSync(OUT, { recursive: true });
const SB = 'https://test-nova.supabase.co';
const results = [];
const check = (name, ok, extra) => { results.push((ok ? 'PASS ' : 'FAIL ') + name + (ok || extra === undefined ? '' : ' :: ' + JSON.stringify(extra))); };

// --- статический сервер с подставленными ключами ---
const server = http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/') p = '/app.html';
  const file = path.join(DOCS, p);
  if (!file.startsWith(DOCS) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
  let body = fs.readFileSync(file);
  if (p === '/app.html') {
    let s = body.toString('utf8');
    s = s.split('https://udnjvgvdiyfafsiqdkox.supabase.co').join(SB);
    s = s.replace(/supabaseUrl: '[^']*'/, "supabaseUrl: '" + SB + "'").replace(/supabaseKey: '[^']*'/, "supabaseKey: 'sb_publishable_test'");
    if (!s.includes(SB)) throw new Error('AUTH not replaced');
    body = Buffer.from(s, 'utf8');
  }
  const type = p.endsWith('.html') ? 'text/html; charset=utf-8' : p.endsWith('.js') ? 'application/javascript' : p.endsWith('.jpg') ? 'image/jpeg' : 'application/octet-stream';
  res.writeHead(200, { 'content-type': type });
  res.end(body);
});

// --- имитация Supabase Auth ---
const users = {};       // email -> { id, password, name, confirmed, code, sentAt }
const mails = [];       // { email, code }
const calls = [];
let codeSeq = 0;
let offline = false;
const CODES = ['482913', '615204', '790388', '133742', '908172'];
function b64url(o) { return Buffer.from(JSON.stringify(o)).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_'); }
function userObj(u, withIdentities = true) {
  return {
    id: u.id, aud: 'authenticated', role: 'authenticated', email: u.email,
    email_confirmed_at: u.confirmed ? new Date().toISOString() : null,
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: { name: u.name, email: u.email, email_verified: !!u.confirmed },
    identities: withIdentities ? [{ id: u.id, user_id: u.id, provider: 'email', identity_data: { email: u.email, sub: u.id } }] : [],
    created_at: new Date().toISOString(), updated_at: new Date().toISOString()
  };
}
function session(u) {
  const now = Math.floor(Date.now() / 1000);
  const jwt = b64url({ alg: 'HS256', typ: 'JWT' }) + '.' + b64url({ sub: u.id, email: u.email, aud: 'authenticated', role: 'authenticated', exp: now + 3600, iat: now, session_id: 's-' + u.id }) + '.c2ln';
  return { access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: 'rt-' + u.id, user: userObj(u) };
}
function sendMail(u) { u.code = CODES[codeSeq++ % CODES.length]; u.sentAt = Date.now(); mails.push({ email: u.email, code: u.code }); }
const CORS = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS' };
function reply(route, status, body) {
  return route.fulfill({ status, headers: { ...CORS, 'content-type': 'application/json' }, body: body === undefined ? '' : JSON.stringify(body) });
}
function err(route, status, code, msg) { return reply(route, status, { code: status, error_code: code, msg }); }

async function handle(route) {
  const req = route.request();
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers: CORS });
  if (offline) return route.abort('internetdisconnected');
  const url = new URL(req.url());
  const ep = url.pathname.replace('/auth/v1', '');
  let body = {}; try { body = JSON.parse(req.postData() || '{}'); } catch (e) {}
  calls.push(req.method() + ' ' + ep + url.search);
  const email = (body.email || '').toLowerCase();
  const u = users[email];
  if (ep === '/signup') {
    if (u && u.confirmed) return reply(route, 200, userObj(u, false));
    if (u) {
      if (Date.now() - u.sentAt < 60000) return err(route, 429, 'over_email_send_rate_limit', 'For security purposes, you can only request this after ' + Math.ceil((60000 - (Date.now() - u.sentAt)) / 1000) + ' seconds.');
      sendMail(u); return reply(route, 200, userObj(u));
    }
    if ((body.password || '').length < 8) return err(route, 422, 'weak_password', 'Password should be at least 8 characters.');
    const nu = users[email] = { id: 'u' + (Object.keys(users).length + 1), email, password: body.password, name: (body.data || {}).name, confirmed: false };
    sendMail(nu);
    return reply(route, 200, userObj(nu));
  }
  if (ep === '/verify') {
    if (!u || body.token !== u.code || body.type !== 'email') return err(route, 403, 'otp_expired', 'Token has expired or is invalid');
    u.confirmed = true; u.code = null;
    return reply(route, 200, session(u));
  }
  if (ep === '/resend') {
    if (!u) return reply(route, 200, {});
    if (Date.now() - u.sentAt < 60000 && !u.allowResend) return err(route, 429, 'over_email_send_rate_limit', 'For security purposes, you can only request this after ' + Math.ceil((60000 - (Date.now() - u.sentAt)) / 1000) + ' seconds.');
    u.allowResend = false;
    sendMail(u); return reply(route, 200, {});
  }
  if (ep === '/token') {
    if (!u || u.password !== body.password) return err(route, 400, 'invalid_credentials', 'Invalid login credentials');
    if (!u.confirmed) return err(route, 400, 'email_not_confirmed', 'Email not confirmed');
    return reply(route, 200, session(u));
  }
  if (ep === '/logout') return reply(route, 204);
  if (ep === '/user') {
    const id = ((req.headers()['authorization'] || '').split('.')[1]);
    return reply(route, 200, userObj(Object.values(users)[0]));
  }
  return err(route, 404, 'not_found', 'not found ' + ep);
}

async function flow(ctxOpts, tag, base) {
  for (const k of Object.keys(users)) delete users[k];
  mails.length = 0; calls.length = 0;
  const b = await chromium.launch();
  const ctx = await b.newContext(ctxOpts);
  await ctx.route(SB + '/**', handle);
  const p = await ctx.newPage();
  const errors = [];
  p.on('pageerror', e => errors.push(e.message));
  p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push('console: ' + m.text()); });
  await p.goto(base + '/app.html');
  await p.waitForTimeout(900);
  check(tag + ' chip shows real mode', (await p.textContent('#mode-chip')) === 'Аккаунт Nova');
  check(tag + ' foot shows real text', (await p.textContent('#mode-foot')).includes('зашифрованном'));
  check(tag + ' library loaded', await p.evaluate(() => !!(window.supabase && window.supabase.createClient)));

  // регистрация
  await p.click('#view-login a[href="#register"]');
  await p.waitForSelector('#view-register:not([hidden])');
  await p.waitForTimeout(1300);
  await p.fill('#r-name', 'Вадим');
  await p.fill('#r-email', 'vadim@mail.ru');
  await p.fill('#r-pass', 'Nova2026!pass');
  await p.fill('#r-pass2', 'Nova2026!pass');
  await p.click('#terms-label i');
  await p.click('#form-register [type=submit]');
  await p.waitForSelector('#view-verify:not([hidden])', { timeout: 6000 });
  check(tag + ' signup sent one mail', mails.length === 1 && mails[0].email === 'vadim@mail.ru', mails);
  check(tag + ' signup carried name', users['vadim@mail.ru'] && users['vadim@mail.ru'].name === 'Вадим');
  await p.waitForSelector('.toast', { timeout: 4000 });
  await p.waitForTimeout(700);
  const toastText = await p.textContent('.toast');
  check(tag + ' mail toast without code', toastText.includes('Письмо отправлено') && !/\d{6}/.test(toastText), toastText);
  check(tag + ' no demo code toast', (await p.$('.toast .code')) === null);
  check(tag + ' subtitle says 6 digits', (await p.textContent('#v-sub')).includes('6-значный'));
  check(tag + ' resend timer ~59s', /00:5\d/.test(await p.textContent('#resend')), await p.textContent('#resend'));
  await p.screenshot({ path: `${OUT}/${tag}-1-verify.png` });

  // неверный код
  await p.click('#otp input:nth-of-type(1)');
  await p.keyboard.type('111111');
  await p.waitForTimeout(2800);
  const e1 = await p.textContent('#otp-err');
  check(tag + ' wrong code -> russian error', e1.includes('Код не подошёл или устарел'), e1);
  await p.screenshot({ path: `${OUT}/${tag}-2-wrong.png` });

  // повторная отправка (сервер разрешает сразу, чтобы не ждать минуту)
  users['vadim@mail.ru'].allowResend = true;
  await p.evaluate(() => { document.querySelector('#resend').disabled = false; });
  const oldCode = mails[0].code;
  await p.click('#resend');
  await p.waitForTimeout(800);
  check(tag + ' resend sent new mail', mails.length === 2 && mails[1].code !== oldCode, mails);
  check(tag + ' resend timer restarted', /через 00:5\d/.test(await p.textContent('#resend')));

  // старый код больше не подходит
  await p.click('#otp input:nth-of-type(1)');
  await p.keyboard.type(oldCode);
  await p.waitForTimeout(2800);
  check(tag + ' old code rejected', (await p.textContent('#otp-err')).includes('не подошёл'));

  // верный код (вставкой целиком)
  await p.evaluate((c) => {
    const dt = new DataTransfer(); dt.setData('text', c);
    document.querySelector('#otp input').dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
  }, mails[1].code);
  await p.waitForTimeout(1000);
  await p.screenshot({ path: `${OUT}/${tag}-3-orbit.png` });
  await p.waitForTimeout(1600);
  check(tag + ' success state', await p.$eval('#card', el => el.classList.contains('success')));
  check(tag + ' success shows name from server', (await p.textContent('#v-email')).includes('Вадим'));
  await p.screenshot({ path: `${OUT}/${tag}-4-success.png` });
  await p.waitForTimeout(1600);
  await p.click('#verify-btn');
  await p.waitForSelector('#dash:not([hidden])', { timeout: 5000 });
  await p.waitForTimeout(900);
  check(tag + ' greeting has name', (await p.textContent('#greet')).includes('Вадим'));
  check(tag + ' dash chip real', (await p.textContent('#dash-chip')).includes('почта подтверждена'));
  const stored = await p.evaluate(() => Object.keys(localStorage).filter(k => k.startsWith('sb-')));
  check(tag + ' session stored', stored.length === 1, stored);
  await p.screenshot({ path: `${OUT}/${tag}-5-dash.png` });

  // перезагрузка: сессия сохраняется
  await p.reload();
  await p.waitForTimeout(1500);
  check(tag + ' reload keeps dashboard', await p.isVisible('#dash'));

  // выход
  await p.locator('[data-logout]:visible').first().click();
  await p.waitForSelector('#view-login:not([hidden])', { timeout: 5000 });
  await p.waitForTimeout(500);
  check(tag + ' logout called server', calls.some(c => c.startsWith('POST /logout')), calls);
  const stored2 = await p.evaluate(() => Object.keys(localStorage).filter(k => k.startsWith('sb-')));
  check(tag + ' session removed', stored2.length === 0, stored2);

  // повторная регистрация на ту же почту
  await p.waitForTimeout(800);
  await p.click('#view-login a[href="#register"]');
  await p.waitForSelector('#view-register:not([hidden])');
  await p.waitForTimeout(1300);
  await p.fill('#r-name', 'Вадим');
  await p.fill('#r-email', 'vadim@mail.ru');
  await p.fill('#r-pass', 'Nova2026!pass');
  await p.fill('#r-pass2', 'Nova2026!pass');
  await p.click('#terms-label i');
  await p.click('#form-register [type=submit]');
  await p.waitForTimeout(900);
  const regErr = await p.textContent('#form-register .field:nth-of-type(2) .err');
  check(tag + ' duplicate email message', regErr.includes('уже зарегистрирована'), regErr);
  check(tag + ' duplicate stays on register', await p.isVisible('#view-register'));

  // вход: неверный пароль, потом верный
  await p.click('#view-register a[href="#login"]');
  await p.waitForSelector('#view-login:not([hidden])');
  await p.waitForTimeout(1300);
  await p.fill('#l-email', 'vadim@mail.ru');
  await p.fill('#l-pass', 'wrongpass1');
  await p.click('#form-login [type=submit]');
  await p.waitForTimeout(900);
  const lErr = await p.$$eval('#form-login .err', els => els.map(e => e.textContent).join('|'));
  check(tag + ' wrong password message', lErr.includes('Неверная почта или пароль'), lErr);
  await p.screenshot({ path: `${OUT}/${tag}-6-wrongpass.png` });

  // нет интернета
  offline = true;
  await p.fill('#l-pass', 'Nova2026!pass');
  await p.click('#form-login [type=submit]');
  await p.waitForTimeout(2500);
  const offToast = await p.$$eval('.toast', els => els.map(e => e.textContent).join('|'));
  check(tag + ' offline message', offToast.includes('Нет связи с сервером'), offToast);
  check(tag + ' button restored after error', !(await p.$eval('#form-login [type=submit]', b => b.disabled)));
  offline = false;

  await p.click('#form-login [type=submit]');
  await p.waitForSelector('#dash:not([hidden])', { timeout: 6000 });
  check(tag + ' login ok', (await p.textContent('#greet')).includes('Вадим'));
  // без «Запомнить меня» сессия только в sessionStorage
  const where = await p.evaluate(() => ({ local: Object.keys(localStorage).filter(k => k.startsWith('sb-')).length, session: Object.keys(sessionStorage).filter(k => k.startsWith('sb-')).length }));
  check(tag + ' not remembered -> sessionStorage', where.local === 0 && where.session === 1, where);
  await p.locator('[data-logout]:visible').first().click();
  await p.waitForSelector('#view-login:not([hidden])', { timeout: 5000 });

  // аккаунт без подтверждённой почты: вход ведёт на ввод кода
  users['petya@mail.ru'] = { id: 'u9', email: 'petya@mail.ru', password: 'Petya2026!x', name: 'Петя', confirmed: false, code: '000111', sentAt: Date.now() - 120000 };
  await p.waitForTimeout(800);
  await p.fill('#l-email', 'petya@mail.ru');
  await p.fill('#l-pass', 'Petya2026!x');
  await p.click('#form-login [type=submit]');
  await p.waitForSelector('#view-verify:not([hidden])', { timeout: 6000 });
  await p.waitForTimeout(400);
  check(tag + ' unconfirmed -> new mail', mails.length > 0 && mails[mails.length - 1].email === 'petya@mail.ru', mails);
  const t2 = await p.$$eval('.toast', els => els.map(e => e.textContent).join('|'));
  check(tag + ' unconfirmed toast', t2.includes('Почта ещё не подтверждена'), t2);
  check(tag + ' verify shows petya email', (await p.textContent('#v-email')) === 'petya@mail.ru');
  await p.click('#otp input:nth-of-type(1)');
  await p.keyboard.type(mails[mails.length - 1].code);
  await p.waitForTimeout(2600);
  check(tag + ' petya verified', await p.$eval('#card', el => el.classList.contains('success')));
  check(tag + ' petya name from server', (await p.textContent('#v-email')).includes('Петя'));

  const overflow = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  check(tag + ' no horizontal overflow (' + overflow + ')', overflow <= 0);
  check(tag + ' no JS errors', errors.length === 0, errors);
  await b.close();
}

(async () => {
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + server.address().port;
  try {
    await flow({ ...devices['iPhone 13'] }, 'phone', base);
    await flow({ viewport: { width: 1360, height: 860 }, deviceScaleFactor: 1 }, 'desktop', base);
  } catch (e) { results.push('CRASH ' + e.message.split('\n')[0]); }
  server.close();
  console.log(results.join('\n'));
  const failed = results.filter(r => !r.startsWith('PASS')).length;
  console.log(failed ? 'SOME FAILED' : 'ALL PASS');
  process.exitCode = failed ? 1 : 0;
})();
