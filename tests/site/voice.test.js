// Кабинет: конструктор голосовых команд (свой voice.json). Демо-режим — без сервера аккаунтов.
const { chromium, devices } = require('playwright');
const http = require('http');
const fs = require('fs');
const path = require('path');

const DOCS = path.resolve(__dirname, '../../docs');
const ROOT = path.resolve(__dirname, '../..');
const OUT = path.join(process.env.NOVA_SHOTS || path.join(require('os').tmpdir(), 'nova-site'), 'voice');
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const check = (name, ok, extra) => { results.push((ok ? 'PASS ' : 'FAIL ') + name + (ok || extra === undefined ? '' : ' :: ' + JSON.stringify(extra).slice(0, 300))); };
const DEFAULT = JSON.parse(fs.readFileSync(path.join(ROOT, 'voice.json'), 'utf8'));

const server = http.createServer((req, res) => {
  let p = decodeURIComponent(req.url.split('?')[0]);
  if (p === '/') p = '/app.html';
  const file = path.join(DOCS, p);
  if (!file.startsWith(DOCS) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
  let body = fs.readFileSync(file);
  if (p === '/app.html') {
    body = Buffer.from(body.toString('utf8').replace(/supabaseUrl: '[^']*'/, "supabaseUrl: ''").replace(/supabaseKey: '[^']*'/, "supabaseKey: ''"), 'utf8');
  }
  res.writeHead(200, { 'content-type': p.endsWith('.html') ? 'text/html; charset=utf-8' : p.endsWith('.js') ? 'application/javascript' : 'application/octet-stream' });
  res.end(body);
});

async function hibpNone(route) { return route.fulfill({ status: 200, headers: { 'access-control-allow-origin': '*', 'content-type': 'text/plain' }, body: '0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n' }); }

async function register(p) {
  await p.goto(p.__base + '/app.html#register');
  await p.waitForSelector('#view-register:not([hidden])');
  await p.waitForTimeout(400);
  await p.fill('#r-name', 'Вадим');
  await p.fill('#r-email', 'vadim@mail.ru');
  await p.fill('#r-pass', 'Nova2026pass');
  await p.fill('#r-pass2', 'Nova2026pass');
  await p.click('#terms-label i');
  await p.click('#form-register [type=submit]');
  await p.waitForSelector('.toast .code', { timeout: 6000 });
  const code = (await p.textContent('.toast .code')).replace(/\s/g, '');
  await p.click('#otp input:nth-of-type(1)');
  await p.keyboard.type(code);
  await p.waitForSelector('#verify-btn:has-text("Перейти в кабинет")', { timeout: 8000 });
  await p.click('#verify-btn');
  await p.waitForSelector('#dash:not([hidden])', { timeout: 5000 });
  await p.waitForTimeout(600);
}

async function add(p, say, kind, value) {
  await p.fill('#v-say', say);
  await p.selectOption('#v-kind', kind);
  await p.fill('#v-value', value);
  await p.click('#v-add [type=submit]');
  await p.waitForTimeout(150);
  return (await p.textContent('#v-err')).trim();
}

async function shown(p) {
  await p.click('#v-show');
  await p.waitForSelector('.modal textarea');
  const text = await p.$eval('.modal textarea', t => t.value);
  await p.click('.modal [data-close]');
  return text;
}

// Те же правила, что у Read-NovaVoiceConfig в Nova: иначе Nova Голос файл не примет.
function novaProblems(doc) {
  const problems = [];
  if (!/^[а-яё]+$/.test(doc.wakeWord)) problems.push('wakeWord');
  if (typeof doc.speak !== 'boolean') problems.push('speak');
  for (const c of doc.commands) {
    if (!Array.isArray(c.say) || !c.say.length) problems.push('say');
    for (const s of c.say || []) if (!/^[а-яё ]+$/.test(s)) problems.push('phrase ' + s);
    if (['do', 'run', 'keys'].filter(k => c[k]).length !== 1) problems.push('kinds ' + JSON.stringify(c));
  }
  return problems;
}

(async () => {
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = 'http://127.0.0.1:' + server.address().port;
  for (const [tag, opts] of [['phone', { ...devices['iPhone 13'] }], ['desktop', { viewport: { width: 1360, height: 860 }, deviceScaleFactor: 1, acceptDownloads: true }]]) {
    const b = await chromium.launch();
    const ctx = await b.newContext({ ...opts, acceptDownloads: true });
    await ctx.route('https://api.pwnedpasswords.com/**', hibpNone);
    const p = await ctx.newPage(); p.__base = base;
    const errors = [];
    p.on('pageerror', e => errors.push(e.message));
    p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push('console: ' + m.text()); });
    const T = tag;
    try {
      await register(p);
      // Готовые сборки в конструкторе
      await p.$eval('#builder', el => el.scrollIntoView());
      check(T + ' presets shown', (await p.$$('#presets button')).length === 4);
      await p.click('#presets [data-preset="gaming"]');
      await p.waitForTimeout(150);
      const cfgText = await (async () => { await p.click('[data-show-config]'); await p.waitForSelector('.modal textarea'); const v = await p.$eval('.modal textarea', t => t.value); await p.click('.modal [data-close]'); return v; })();
      const cfg = JSON.parse(cfgText);
      check(T + ' gaming preset: power + runtimes', cfg.tweaks['high-performance-power'] === true && cfg.tweaks['game-priority'] === true && cfg.installApps['Microsoft.VCRedist.2015+.x64'] === true && cfg.installApps['Microsoft.DirectX'] === true, cfg.tweaks);
      check(T + ' gaming preset highlighted', await p.$eval('#presets [data-preset="gaming"]', b => b.classList.contains('active')));
      await p.click('#presets [data-preset="laptop"]');
      await p.waitForTimeout(150);
      const lap = JSON.parse(await (async () => { await p.click('[data-show-config]'); await p.waitForSelector('.modal textarea'); const v = await p.$eval('.modal textarea', t => t.value); await p.click('.modal [data-close]'); return v; })());
      check(T + ' laptop preset keeps battery', lap.tweaks['high-performance-power'] === false && lap.tweaks['power-throttling-off'] === false && lap.tweaks['background-apps-off'] === true);
      await p.click('#presets [data-preset="default"]');
      await p.waitForTimeout(150);
      check(T + ' default preset resets', (await p.textContent('#changed')).includes('по умолчанию'));

      await p.$eval('#voice', el => el.scrollIntoView());
      const builtIn = await p.$$eval('#v-list input[data-vkey]', els => els.length);
      check(T + ' built-in commands listed', builtIn === DEFAULT.commands.length, builtIn);
      check(T + ' starts as default', (await p.textContent('#v-changed')).includes('по умолчанию'));

      // выключаем «выключи компьютер»
      await p.click('#v-list label:has(input[data-vkey="выключи компьютер"]) .txt');
      check(T + ' toggle off counts as change', (await p.textContent('#v-changed')).includes('изменено: 1'));

      // ошибки
      check(T + ' wake word in phrase refused', (await add(p, 'нова открой ютуб', 'run', 'youtube.com')).includes('говорить не нужно'));
      check(T + ' latin phrase refused', (await add(p, 'open youtube', 'run', 'youtube.com')).includes('русские буквы'));
      check(T + ' comma refused', (await add(p, 'открой, ютуб', 'run', 'youtube.com')).includes('русские буквы'));
      check(T + ' built-in phrase refused', (await add(p, 'пауза', 'run', 'youtube.com')).includes('уже есть'));
      check(T + ' word unknown to the model refused', (await add(p, 'открой дискорд', 'run', 'discord://')).includes('не знает'));
      check(T + ' bad keys refused', (await add(p, 'диспетчер', 'keys', 'ctrl+???')).includes('клавиши'));
      check(T + ' quotes refused', (await add(p, 'блокнот', 'run', 'notepad.exe" -x')).includes('кавычек'));
      check(T + ' empty value refused', (await add(p, 'блокнот', 'run', '')).includes('сайт или программу'));

      // добавляем свои
      check(T + ' site added', (await add(p, '  Открой   Ютуб ', 'run', 'youtube.com')) === '');
      check(T + ' keys added', (await add(p, 'диспетчер', 'keys', 'Ctrl + Shift + Esc')) === '');
      check(T + ' program added', (await add(p, 'блокнот', 'run', 'notepad.exe')) === '');
      check(T + ' installer added', (await add(p, 'установщик', 'run', 'setup.msi')) === '');
      check(T + ' site path added', (await add(p, 'мой канал', 'run', 'www.youtube.com/@nova')) === '');
      check(T + ' duplicate custom refused', (await add(p, 'открой ютуб', 'run', 'vk.com')).includes('уже есть'));
      // HTML в значении показывается как текст
      check(T + ' html value added as text', (await add(p, 'проверка', 'run', '<img src=x onerror=window.__xss=1>')) === '');
      await p.waitForTimeout(200);
      check(T + ' no html injected', !(await p.evaluate(() => window.__xss)) && (await p.$$('#voice img')).length === 0);
      check(T + ' custom rows', (await p.$$('#v-custom .vcmd')).length === 6);
      await p.click('#v-custom .vcmd:has-text("проверка") button');
      check(T + ' custom deleted', (await p.$$('#v-custom .vcmd')).length === 5);

      await p.click('label.check:has(#v-speak) i');
      const doc = JSON.parse(await shown(p));
      const says = doc.commands.map(c => c.say[0]);
      check(T + ' disabled command left out', !says.includes('выключи компьютер') && says.includes('пауза'), says);
      const yt = doc.commands.find(c => c.say[0] === 'открой ютуб');
      check(T + ' site gets https', yt && yt.run === 'https://youtube.com', yt);
      const tm = doc.commands.find(c => c.say[0] === 'диспетчер');
      check(T + ' keys normalized', tm && tm.keys === 'ctrl+shift+esc', tm);
      const np = doc.commands.find(c => c.say[0] === 'блокнот');
      check(T + ' exe left as is', np && np.run === 'notepad.exe', np);
      const msi = doc.commands.find(c => c.say[0] === 'установщик');
      check(T + ' msi not turned into a site', msi && msi.run === 'setup.msi', msi);
      const ch = doc.commands.find(c => c.say[0] === 'мой канал');
      check(T + ' site with path gets https', ch && ch.run === 'https://www.youtube.com/@nova', ch);
      check(T + ' speak off', doc.speak === false);
      check(T + ' count', doc.commands.length === DEFAULT.commands.length - 1 + 5, doc.commands.length);
      check(T + ' keeps wake word and info', doc.wakeWord === DEFAULT.wakeWord && doc._info === DEFAULT._info && doc.delaySeconds === DEFAULT.delaySeconds);
      check(T + ' Nova would accept it', novaProblems(doc).length === 0, novaProblems(doc));

      if (tag === 'desktop') {
        const [dl] = await Promise.all([p.waitForEvent('download'), p.click('#v-download')]);
        const file = path.join(OUT, 'voice.json');
        await dl.saveAs(file);
        check(T + ' download name', dl.suggestedFilename() === 'voice.json', dl.suggestedFilename());
        const got = JSON.parse(fs.readFileSync(file, 'utf8'));
        check(T + ' download content', got.commands.length === doc.commands.length && got.speak === false);
      }

      // после перезагрузки страницы всё на месте
      await p.reload();
      await p.waitForSelector('#dash:not([hidden])', { timeout: 5000 });
      await p.waitForTimeout(400);
      check(T + ' kept after reload', (await p.$$('#v-custom .vcmd')).length === 5 && !(await p.$eval('#v-speak', c => c.checked)));
      check(T + ' toggle kept', !(await p.$eval('#v-list input[data-vkey="выключи компьютер"]', c => c.checked)));

      // подделанное хранилище: неправильные команды не загружаются
      await p.evaluate(() => {
        localStorage.setItem('nova.voice', JSON.stringify({ off: { 'пауза': 'yes', 'несуществующая': true, '__proto__': true }, speak: 'no', custom: [
          { say: '<b>x</b>', kind: 'run', value: 'a.exe' }, { say: 'ок', kind: 'evil', value: 'x' }, { say: 'нормальная', kind: 'keys', value: 'win+d' }] }));
      });
      await p.reload();
      await p.waitForSelector('#dash:not([hidden])', { timeout: 5000 });
      await p.waitForTimeout(400);
      const rows = await p.$$eval('#v-custom .vcmd b', els => els.map(e => e.textContent));
      check(T + ' tampered storage filtered', rows.length === 1 && rows[0].includes('нормальная'), rows);
      check(T + ' tampered flags ignored', await p.$eval('#v-list input[data-vkey="пауза"]', c => c.checked) && await p.$eval('#v-speak', c => c.checked));
      check(T + ' unknown commands not counted', (await p.textContent('#v-changed')).includes('изменено: 1'), await p.textContent('#v-changed'));

      await p.click('#v-reset');
      await p.waitForTimeout(200);
      check(T + ' reset', (await p.$$('#v-custom .vcmd')).length === 0 && (await p.textContent('#v-changed')).includes('по умолчанию'));
      await p.$eval('#voice', el => el.scrollIntoView());
      await p.waitForTimeout(300);
      await p.screenshot({ path: `${OUT}/${T}-voice.png` });
    } catch (e) { results.push('CRASH ' + T + ' ' + e.message.split('\n')[0]); await p.screenshot({ path: `${OUT}/${T}-crash.png` }); }
    const overflow = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    check(T + ' no horizontal overflow (' + overflow + ')', overflow <= 0);
    check(T + ' no JS errors', errors.length === 0, errors);
    await b.close();
  }
  server.close();
  console.log(results.join('\n'));
  const bad = results.filter(r => !r.startsWith('PASS'));
  console.log(bad.length ? '\nFAILED: ' + bad.length : '\nALL PASS');
  process.exit(bad.length ? 1 : 0);
})();
