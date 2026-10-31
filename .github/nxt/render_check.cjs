#!/usr/bin/env node
/* render_check - load a resource's NUI page headless and fail on script errors.

     node render_check.cjs [output.png]

   Reads `ui_page` from fxmanifest.lua in the current folder, opens that file in
   headless Chromium with the FiveM-only globals stubbed, waits for it to
   settle, saves a screenshot and exits 1 if the page threw an uncaught error.
   Network calls to the resource (https://<resource>/...) are answered with an
   empty JSON object, so a page that only fails because the game is not there
   still passes. A resource with no ui_page passes with a note.

   Needs the `playwright` package (resolved through NODE_PATH in CI).
   Canonical copy: Jakobe93/nxt-md tools/. Do not edit the vendored copy.      */
const fs = require('fs');
const path = require('path');

const out = process.argv[2] || 'nxt-render.png';
const manifest = fs.existsSync('fxmanifest.lua') ? fs.readFileSync('fxmanifest.lua', 'utf8') : '';
const code = manifest.replace(/--\[\[[\s\S]*?\]\]/g, '').replace(/--.*$/gm, '');
// a loading screen ('loadscreen') is a page too
const m = code.match(/^\s*(?:ui_page|loadscreen)\s*\(?\s*['"]([^'"]+)['"]/m);
if (!m) {
  console.log('render: no ui_page or loadscreen in fxmanifest.lua - nothing to render');
  process.exit(0);
}
const page_file = path.resolve(m[1]);
if (!fs.existsSync(page_file)) {
  console.log(`::error file=fxmanifest.lua::page '${m[1]}' does not exist - build the UI and commit it`);
  process.exit(1);
}

(async () => {
  const { chromium } = require('playwright');
  const browser = await chromium.launch(process.env.NXT_CHROMIUM ? { executablePath: process.env.NXT_CHROMIUM } : {});
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e && e.message ? e.message : e)));
  await page.addInitScript(() => {
    window.GetParentResourceName = () => 'nxt-render-check';
    window.invokeNative = () => {};
    window.nuiHandoverData = window.nuiHandoverData || {};
  });
  await page.route('**/*', (route) => {
    const url = route.request().url();
    if (url.startsWith('file:') || url.startsWith('data:') || url.startsWith('blob:')) return route.continue();
    if (/^(https?|nui):\/\/(cfx-nui-)?[\w.-]*nxt-render-check\//.test(url) || url.startsWith('nui://')) {
      return route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
    }
    return route.abort();
  });
  await page.goto('file://' + page_file, { waitUntil: 'load', timeout: 30000 });
  await page.waitForTimeout(2000);
  await page.screenshot({ path: out });
  await browser.close();
  if (errors.length) {
    for (const e of errors) console.log(`::error file=${m[1]}::uncaught script error: ${e.split('\n')[0]}`);
    console.log(`render: ${m[1]} threw ${errors.length} uncaught error(s); screenshot at ${out}`);
    process.exit(1);
  }
  console.log(`render: ${m[1]} loaded with no uncaught errors; screenshot at ${out}`);
})().catch((e) => {
  console.log(`::error::render check could not run: ${e.message}`);
  process.exit(1);
});
