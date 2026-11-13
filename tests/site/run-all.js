// Все проверки сайта подряд: защита страниц, регистрация, профиль, пароль и удаление аккаунта, макет.
// Запуск: npm ci && npx playwright install chromium && node run-all.js
// Скриншоты кладутся в папку из NOVA_SHOTS (по умолчанию — временная папка системы).
const { spawnSync } = require('child_process');
const path = require('path');

const tests = ['security', 'signup', 'profile', 'account', 'mockup'];
const failed = [];
for (const name of tests) {
  console.log('\n=== ' + name + ' ===');
  const r = spawnSync(process.execPath, [path.join(__dirname, name + '.test.js')], { stdio: 'inherit', timeout: 10 * 60 * 1000 });
  if (r.status !== 0) failed.push(name);
}
if (failed.length) {
  console.log('\nНе прошли: ' + failed.join(', '));
  process.exit(1);
}
console.log('\nСайт: все проверки пройдены');
