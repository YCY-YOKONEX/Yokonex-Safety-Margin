const fs = require('node:fs');
const path = require('node:path');
const root = __dirname;
const source = fs.readFileSync(path.join(root, 'prototype.template.html'), 'utf8');
const image = 'data:image/png;base64,' + fs.readFileSync(path.join(root, 'assets/pose-demo.png')).toString('base64');
const font = 'data:font/otf;base64,' + fs.readFileSync(path.join(root, '../build/app/intermediates/assets/debug/mergeDebugAssets/flutter_assets/fonts/MaterialIcons-Regular.otf')).toString('base64');
const variants = [
  ['a', 'A · 极简黑白', '画面居中，时长直选。黑白层级，操作最直接。'],
  ['b', 'B · 沉浸取景', '画区工具贴近取景区，底部集中开始和时长。薄荷绿标记操作。'],
  ['c', 'C · 石墨控制台', '时长置顶，画区工具在下。石墨灰底，浅黄色突出关键操作。'],
];
for (const [id, title, description] of variants) {
  const html = source.replaceAll('__VARIANT__', id).replaceAll('__TITLE__', title).replaceAll('__DESCRIPTION__', description).replaceAll('__IMAGE__', image).replaceAll('__FONT__', font);
  fs.writeFileSync(path.join(root, `dark-${id}.html`), html);
}
console.log('Built 3 self-contained prototypes.');
