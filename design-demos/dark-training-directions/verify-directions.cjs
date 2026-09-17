const { chromium } = require('playwright');
const path = require('path');
const { pathToFileURL } = require('url');

(async () => {
  const root = __dirname;
  const browser = await chromium.launch({
    headless: true,
    executablePath: 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  });
  const results = [];
  for (const name of ['a', 'b', 'c']) {
    const page = await browser.newPage({ viewport: { width: 1500, height: 1080 }, deviceScaleFactor: 1 });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(pathToFileURL(path.join(root, name + '.html')).href, { waitUntil: 'load' });
    await page.waitForFunction(() => Array.from(document.images).every(image => image.complete && image.naturalWidth > 0));

    const devices = await page.locator('.device').count();
    await page.locator('.duration').first().locator('button').nth(2).click();
    const durationActive = await page.locator('.duration').first().locator('button').nth(2).evaluate(node => node.classList.contains('active'));
    await page.locator('.scan').click();
    const scanText = await page.locator('.scan').textContent();
    const overflowCount = await page.evaluate(() =>
      Array.from(document.querySelectorAll('.screen,.app,.controls,.device-body'))
        .filter(node => node.scrollWidth > node.clientWidth + 1).length
    );

    const output = path.join(root, 'screenshots', name + '.png');
    await page.screenshot({ path: output, fullPage: true });
    results.push({ name, devices, durationActive, scanText, overflowCount, errors });
    await page.close();
  }
  await browser.close();
  console.log(JSON.stringify(results, null, 2));
})();