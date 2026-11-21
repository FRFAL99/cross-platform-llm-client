// Renders the OneLM app icon ("off the edge": a tilted phone with a glowing
// core breaking out of its corner) to every platform's PNGs.
//
//   node tool/icon/make_icons.js
//
// Needs Node and Playwright with Chromium (`npm i -g playwright && npx playwright
// install chromium`). Writes into android/, ios/, macos/, web/ and
// assets/icons/. Edit the colours or shapes below and run it again.

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '..', '..');

const C = {
  ground: '#171A2B',
  shell: '#2B3150',
  screen: '#353C60',
  accent: '#4FD1C5',
};

// The mark in a 192×192 box. `scale` shrinks it around the centre for
// formats that crop to a safe zone (Android adaptive, web maskable).
function mark(scale = 1, { glow = true } = {}) {
  return `
  <g transform="translate(96 96) scale(${scale}) translate(-96 -96)">
    <g transform="rotate(-12 94 96)">
      <rect x="58" y="32" width="72" height="128" rx="22" fill="${C.shell}"/>
      <rect x="66" y="48" width="56" height="100" rx="12" fill="${C.screen}"/>
      <rect x="86" y="38" width="16" height="5" rx="2.5" fill="${C.screen}"/>
    </g>
    ${glow ? '<circle cx="128" cy="70" r="48" fill="url(#glow)"/>' : ''}
    <circle cx="128" cy="70" r="28" fill="${C.accent}"/>
  </g>`;
}

const defs = `
  <defs>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0.55" stop-color="${C.accent}" stop-opacity="0.35"/>
      <stop offset="1" stop-color="${C.accent}" stop-opacity="0"/>
    </radialGradient>
  </defs>`;

// Full-bleed square: iOS (the system rounds it), web maskable.
const square = (scale = 1) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192">${defs}
  <rect width="192" height="192" fill="${C.ground}"/>${mark(scale)}</svg>`;

// Rounded tile: Android legacy launchers, web, in-app.
const rounded = (pad = 0) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${-pad} ${-pad} ${192 + 2 * pad} ${192 + 2 * pad}">${defs}
  <rect width="192" height="192" rx="44" fill="${C.ground}"/>${mark()}</svg>`;

// Android adaptive icon foreground (transparent, 108dp canvas: the mark
// must stay inside the central 66dp).
const foreground = () => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192">${defs}${mark(0.66)}</svg>`;

// Android 13 themed icon: one-colour silhouette.
const monochrome = () => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192">
  <defs><mask id="gap"><rect width="192" height="192" fill="#fff"/><circle cx="128" cy="70" r="36" fill="#000"/></mask></defs>
  <g transform="translate(96 96) scale(0.66) translate(-96 -96)">
    <g mask="url(#gap)"><g transform="rotate(-12 94 96)"><rect x="58" y="32" width="72" height="128" rx="22" fill="#fff" fill-opacity="0.6"/></g></g>
    <circle cx="128" cy="70" r="29" fill="#fff"/>
  </g></svg>`;

const outputs = [];
const add = (file, size, svg, transparent = false) => outputs.push({ file, size, svg, transparent });

// Android legacy + adaptive
const densities = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
for (const [d, k] of Object.entries(densities)) {
  add(`android/app/src/main/res/mipmap-${d}/ic_launcher.png`, 48 * k, rounded(), true);
  add(`android/app/src/main/res/mipmap-${d}/ic_launcher_foreground.png`, 108 * k, foreground(), true);
  add(`android/app/src/main/res/mipmap-${d}/ic_launcher_monochrome.png`, 108 * k, monochrome(), true);
}

// iOS (opaque, square)
const iosDir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
const ios = JSON.parse(fs.readFileSync(path.join(ROOT, iosDir, 'Contents.json'), 'utf8'));
const seen = new Set();
for (const img of ios.images) {
  if (!img.filename || seen.has(img.filename)) continue;
  seen.add(img.filename);
  const px = Math.round(parseFloat(img.size) * parseInt(img.scale));
  add(`${iosDir}/${img.filename}`, px, square());
}

// macOS (rounded tile with the standard margin)
const macDir = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
for (const px of [16, 32, 64, 128, 256, 512, 1024]) {
  add(`${macDir}/app_icon_${px}.png`, px, rounded(19), true);
}

// Web
add('web/favicon.png', 32, rounded(), true);
add('web/icons/Icon-192.png', 192, rounded(), true);
add('web/icons/Icon-512.png', 512, rounded(), true);
add('web/icons/Icon-maskable-192.png', 192, square(0.8));
add('web/icons/Icon-maskable-512.png', 512, square(0.8));

// In-app (Settings, license page) and the master files
add('assets/icons/appicon.png', 512, rounded(), true);
add('tool/icon/icon-1024.png', 1024, square());

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 1 });
  for (const o of outputs) {
    await page.setViewportSize({ width: o.size, height: o.size });
    await page.setContent(
      `<html><body style="margin:0;background:transparent">` +
        o.svg.replace('<svg ', `<svg width="${o.size}" height="${o.size}" `) +
        `</body></html>`,
    );
    await page.screenshot({
      path: path.join(ROOT, o.file),
      omitBackground: o.transparent,
      clip: { x: 0, y: 0, width: o.size, height: o.size },
    });
  }
  fs.writeFileSync(path.join(ROOT, 'tool/icon/icon.svg'), square());
  await browser.close();
  console.log(`Wrote ${outputs.length} icons.`);
})();
