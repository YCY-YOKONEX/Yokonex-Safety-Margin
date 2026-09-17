const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const runtime = 'C:/Users/Administrator/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/';
const { chromium } = require(runtime + 'playwright');
const sharp = require(runtime + 'sharp');

(async () => {
  const browser = await chromium.launch({ headless: true, channel: 'chrome' });
  const page = await browser.newPage({ viewport: { width: 1280, height: 1040 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  const local = name => pathToFileURL(path.join(__dirname, name)).href;
  const out = path.join(__dirname, 'screenshots');
  fs.mkdirSync(out, { recursive: true });
  const checks = [];
  await page.goto(local('index.html'));
  await page.waitForTimeout(900);
  await page.screenshot({ path: path.join(out, 'comparison.png'), fullPage: true });
  for (const id of ['a', 'b', 'c']) {
    await page.setViewportSize({ width: 1536, height: 940 });
    await page.goto(local(`dark-${id}.html`));
    await page.waitForTimeout(400);
    assert.equal(await page.locator('.app').count(), 4);
    const assets = await page.locator('img').evaluateAll(images => images.every(i => i.complete && i.naturalWidth === 1024));
    assert(assets, 'image must decode');
    assert(await page.evaluate(() => document.fonts.check('23px Material')));
    await page.screenshot({ path: path.join(out, `${id}-screens.png`), fullPage: true });
    const app = page.locator('.app').first();
    await app.getByRole('button', { name: '更多设置', exact: true }).click();
    assert.equal(await app.locator('details').getAttribute('open'), null);
    await app.getByLabel('游戏时长', { exact: true }).fill('7');
    await app.locator('summary').click();
    await app.getByLabel('异常持续', { exact: true }).fill('1');
    await app.getByLabel('重复间隔', { exact: true }).fill('1');
    await app.getByRole('button', { name: '保存', exact: true }).click();
    assert.equal(await app.locator('.sheet').count(), 0);
    await app.getByRole('button', { name: '开始游戏', exact: true }).click();
    await page.locator('.mode-switch select').first().selectOption('outside');
    await page.waitForTimeout(2200);
    const count = Number(await app.locator('.stat strong').innerText());
    assert(count >= 1, 'sustained anomaly must emit');
    await app.getByRole('button', { name: '暂停', exact: true }).click();
    const remaining = await app.locator('.timer').innerText();
    await page.waitForTimeout(1100);
    assert.equal(await app.locator('.timer').innerText(), remaining);
    assert.equal(Number(await app.locator('.stat strong').innerText()), count);
    await app.getByRole('button', { name: '继续游戏', exact: true }).click();
    await app.getByRole('button', { name: '结束', exact: true }).click();
    assert.equal(await app.locator('.event').count(), count);
    await app.getByRole('button', { name: '再来一局', exact: true }).click();
    await app.getByRole('button', { name: '切换摄像头', exact: true }).click();
    assert(await app.getByRole('button', { name: '开始游戏', exact: true }).isDisabled());
    for (const name of ['矩形画区', '自由圈画']) {
      await app.getByRole('button', { name, exact: true }).click();
      await page.waitForTimeout(100);
      const box = await app.locator('canvas').boundingBox();
      await page.mouse.move(box.x + box.width * .24, box.y + box.height * .3);
      await page.mouse.down();
      await page.mouse.move(box.x + box.width * .85, box.y + box.height * .3, { steps: 5 });
      await page.mouse.move(box.x + box.width * .85, box.y + box.height * .85, { steps: 5 });
      if (name === '自由圈画') await page.mouse.move(box.x + box.width * .24, box.y + box.height * .85, { steps: 5 });
      await page.mouse.up();
      assert(await app.getByRole('button', { name: '开始游戏', exact: true }).isEnabled(), `${id}: ${name} drawing enables start`);
    }
    for (const width of [320, 390]) {
      await page.setViewportSize({ width, height: 844 });
      await page.goto(local(`dark-${id}.html`) + '?single');
      await page.waitForTimeout(250);
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'no horizontal overflow');
      const bounds = await page.locator('.app').first().evaluate(el => {
        const r = el.getBoundingClientRect();
        return [...el.querySelectorAll('button')].every(b => {
          const q = b.getBoundingClientRect();
          return q.left >= r.left && q.right <= r.right + 1 && q.top >= r.top && q.bottom <= r.bottom + 1;
        });
      });
      assert(bounds, 'controls fit surface');
      await page.screenshot({ path: path.join(out, `${id}-${width}.png`), fullPage: true });
    }
    checks.push(`${id}: four screens, assets, settings, anomaly, pause, result, restart, camera reset, two drawing modes, 320/390px layout`);
  }
  assert.deepEqual(errors, []);
  const stats = await sharp(path.join(out, 'comparison.png')).stats();
  assert(stats.channels.slice(0, 3).every(c => c.stdev > 25), 'nonblank screenshot');
  fs.writeFileSync(path.join(__dirname, 'verification.json'), JSON.stringify({ checkedAt: new Date().toISOString(), checks, pageErrors: errors, screenshots: fs.readdirSync(out) }, null, 2));
  console.log(JSON.stringify({ checks, pageErrors: errors }, null, 2));
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
