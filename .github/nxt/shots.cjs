#!/usr/bin/env node
/* shots - render a resource's UI with sample data, and build before/after sheets.

     node .github/nxt/shots.cjs capture <outdir>
     node .github/nxt/shots.cjs compare <beforeDir> <afterDir> <out.png>
     node .github/nxt/shots.cjs before-after [--base origin/main] <out.png>

   capture       opens every screen listed in .github/nxt-shots.json and saves
                 <outdir>/<name>.png.
   compare       pixel-compares two capture folders. Identical screens are only
                 listed; for each one that differs, the changed area is cropped
                 and placed NOW next to AFTER on one sheet.
   before-after  does the whole thing: checks the base out into a temporary
                 worktree, builds and captures both, compares, cleans up.

   The recipe (.github/nxt-shots.json) belongs to the resource and is kept by its
   thread. See nxt-md tools/README-shots.md for the fields.

   Needs the `playwright` package (resolved through NODE_PATH, as render_check.cjs).
   Canonical copy: Jakobe93/nxt-md tools/. Do not edit the vendored copy.          */
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { spawn, spawnSync } = require('child_process');

const CONFIG = '.github/nxt-shots.json';
const MIME = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.html': 'text/html',
  '.json': 'application/json', '.png': 'image/png', '.webp': 'image/webp', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };

function die(msg) { console.log('shots: ' + msg); process.exit(1); }
function loadConfig(root) {
  const f = path.join(root, CONFIG);
  if (!fs.existsSync(f)) die(`no ${CONFIG} in ${root} - this resource has no render recipe yet`);
  try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (e) { die(`${CONFIG} is not valid JSON: ${e.message}`); }
}
function launch() {
  const { chromium } = require('playwright');
  return chromium.launch(process.env.NXT_CHROMIUM ? { executablePath: process.env.NXT_CHROMIUM } : {});
}
function staticServer(dir) {
  const srv = http.createServer((q, r) => {
    let u = decodeURIComponent(q.url.split('?')[0]); if (u.endsWith('/')) u += 'index.html';
    const file = path.join(dir, u);
    if (!file.startsWith(dir)) { r.writeHead(403); return r.end(); }
    fs.readFile(file, (e, b) => { if (e) { r.writeHead(404); return r.end(); }
      r.writeHead(200, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' }); r.end(b); });
  });
  return new Promise((res) => srv.listen(0, '127.0.0.1', () => res(srv)));
}
async function waitFor(url, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const ok = await new Promise((res) => { const q = http.get(url, (r) => { r.resume(); res(true); }); q.on('error', () => res(false)); q.setTimeout(1500, () => { q.destroy(); res(false); }); });
    if (ok) return true;
    await new Promise((r) => setTimeout(r, 400));
  }
  return false;
}

// ---- capture -------------------------------------------------------------------
async function runSteps(page, steps) {
  for (const s of steps || []) {
    if (s.click) await page.locator(s.click).first().click();
    else if (s.hover) await page.locator(s.hover).first().hover();
    else if (s.press) await page.keyboard.press(s.press);
    else if (s.fill) await page.locator(s.fill[0]).first().fill(s.fill[1]);
    else if (s.message) await page.evaluate((m) => window.postMessage(m, '*'), s.message);
    else if (s.eval) await page.evaluate(s.eval);
    else if (s.waitFor) await page.waitForSelector(s.waitFor);
    if (s.wait || !s.waitFor) await page.waitForTimeout(s.wait || 250);
  }
}

async function capture(root, outdir) {
  const cfg = loadConfig(root);
  fs.mkdirSync(outdir, { recursive: true });
  const [w, h] = cfg.viewport || [1920, 1080];
  let srv = null, dev = null, base;
  if (cfg.start) {                       // a dev server the recipe starts (e.g. vite)
    dev = spawn('bash', ['-c', cfg.start], { cwd: root, detached: true, stdio: 'ignore' });
    base = cfg.url;
    if (!(await waitFor(base, 60000))) { try { process.kill(-dev.pid); } catch {} die(`dev server did not answer at ${base}`); }
  } else if (cfg.serve) {                // a folder served over http (pages that load modules or fetch files)
    srv = await staticServer(path.resolve(root, cfg.serve));
    base = `http://127.0.0.1:${srv.address().port}/${cfg.page || ''}`;
  } else {                               // a single built file opened directly
    const file = path.resolve(root, cfg.page);
    if (!fs.existsSync(file)) die(`${cfg.page} does not exist - build the UI first`);
    base = 'file://' + file;
  }
  const browser = await launch();
  const problems = [];
  try {
    for (const sc of cfg.screens || []) {
      const page = await browser.newPage({ viewport: { width: w, height: h } });
      const errs = []; page.on('pageerror', (e) => errs.push(String(e.message || e).split('\n')[0]));
      if (cfg.reducedMotion !== false) await page.emulateMedia({ reducedMotion: 'reduce' });
      if (cfg.time) await page.clock.setFixedTime(new Date(cfg.time));   // Date is frozen, timers still run
      if (cfg.nui) await page.addInitScript(() => { window.GetParentResourceName = () => 'nxt-shots'; window.invokeNative = () => {}; });
      for (const js of [cfg.init, sc.init]) if (js) await page.addInitScript(js);
      await page.goto(base + (sc.query || ''), { waitUntil: 'load', timeout: 30000 });
      const settle = (ms) => page.waitForTimeout(ms);
      await settle(cfg.settle || 1500);
      await page.addStyleTag({ content: `*{animation:none!important;transition:none!important;caret-color:transparent!important}${cfg.backdrop ? `html{background:${cfg.backdrop}!important}` : ''}${cfg.css || ''}` });
      try {
        await runSteps(page, (cfg.steps || []).concat(sc.steps || []));
        await settle(sc.settle || 500);
        const opt = { path: path.join(outdir, sc.name + '.png') };
        if (Array.isArray(sc.clip)) opt.clip = { x: sc.clip[0], y: sc.clip[1], width: sc.clip[2], height: sc.clip[3] };
        if (typeof sc.clip === 'string') await page.locator(sc.clip).first().screenshot(opt); else await page.screenshot(opt);
        console.log(`  ${sc.name}${errs.length ? '  (note: page error: ' + errs[0] + ')' : ''}`);
      } catch (e) { console.log(`  ${sc.name}  FAILED: ${String(e.message).split('\n')[0]}`); problems.push(sc.name); }
      await page.close();
    }
  } finally {
    await browser.close(); if (srv) srv.close(); if (dev) { try { process.kill(-dev.pid); } catch {} }
  }
  console.log(`shots: ${(cfg.screens || []).length - problems.length}/${(cfg.screens || []).length} screens captured to ${outdir}`);
  return problems.length ? 1 : 0;
}

// ---- compare -------------------------------------------------------------------
async function compare(beforeDir, afterDir, out) {
  const names = fs.readdirSync(afterDir).filter((f) => f.endsWith('.png') && fs.existsSync(path.join(beforeDir, f))).sort();
  if (!names.length) die('no screens with the same name in both folders');
  const b64 = (f) => 'data:image/png;base64,' + fs.readFileSync(f).toString('base64');
  const browser = await launch();
  const page = await browser.newPage({ viewport: { width: 1600, height: 900 } });
  const rows = [];
  for (const n of names) {
    const r = await page.evaluate(async ([a, b]) => {
      const load = (s) => new Promise((res) => { const i = new Image(); i.onload = () => res(i); i.src = s; });
      const [ia, ib] = [await load(a), await load(b)];
      if (ia.width !== ib.width || ia.height !== ib.height) return { size: true, w: ib.width, h: ib.height };
      const px = (i) => { const c = document.createElement('canvas'); c.width = i.width; c.height = i.height; const x = c.getContext('2d'); x.drawImage(i, 0, 0); return x.getImageData(0, 0, i.width, i.height).data; };
      const da = px(ia), db = px(ib); let x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1, max = 0;
      for (let y = 0; y < ia.height; y++) for (let x = 0; x < ia.width; x++) { const k = (y * ia.width + x) * 4;
        const d = Math.max(Math.abs(da[k] - db[k]), Math.abs(da[k + 1] - db[k + 1]), Math.abs(da[k + 2] - db[k + 2]));
        if (d > 3) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; } if (d > max) max = d; }
      return { w: ia.width, h: ia.height, box: x1 < 0 ? null : [x0, y0, x1 + 1, y1 + 1], max };
    }, [b64(path.join(beforeDir, n)), b64(path.join(afterDir, n))]);
    rows.push({ name: n.replace(/\.png$/, ''), ...r });
  }
  const pad = 40, changed = rows.filter((r) => r.size || r.box);
  for (const r of rows) console.log(`  ${r.name}: ${r.size ? 'size changed' : r.box ? `changed in ${r.box.join(',')} (max ${r.max}/255)` : 'identical'}`);
  if (!changed.length) { await browser.close(); console.log('shots: every screen is identical - no sheet written'); return 0; }
  const blocks = changed.map((r) => {
    const box = r.size ? [0, 0, r.w, r.h] : [Math.max(0, r.box[0] - pad), Math.max(0, r.box[1] - pad), Math.min(r.w, r.box[2] + pad), Math.min(r.h, r.box[3] + pad)];
    const [cw, ch] = [box[2] - box[0], box[3] - box[1]], wide = cw > 900;
    const crop = (dir) => `<div class="crop" style="width:${cw}px;height:${ch}px"><img src="${b64(path.join(dir, r.name + '.png'))}" style="margin:-${box[1]}px 0 0 -${box[0]}px"></div>`;
    return `<section><h2>${r.name}</h2><div class="pair${wide ? ' stack' : ''}"><div><h3>NOW</h3>${crop(beforeDir)}</div><div><h3 class="after">AFTER</h3>${crop(afterDir)}</div></div></section>`;
  }).join('');
  const same = rows.filter((r) => !r.size && !r.box).map((r) => r.name);
  await page.setContent(`<style>body{margin:0;padding:24px;background:#0b0d12;color:#fff;font:700 22px/1.2 system-ui,sans-serif;width:max-content}
    h2{margin:0 0 12px;font-size:22px;color:#8a93a6;text-transform:uppercase;letter-spacing:.06em}h3{margin:0 0 8px;font-size:20px}.after{color:#8fe3f5}
    section{margin-bottom:36px}.pair{display:flex;gap:24px}.pair.stack{flex-direction:column}.crop{overflow:hidden;outline:1px solid #222a3a}.crop img{display:block}
    p{font-weight:400;font-size:17px;color:#8a93a6;margin:0}#sheet{display:inline-block;padding:24px;background:#0b0d12}body{padding:0}</style><div id="sheet">${blocks}${same.length ? `<p>Identical: ${same.join(', ')}</p>` : ''}</div>`);
  await page.waitForTimeout(300);
  await page.locator('#sheet').screenshot({ path: out });
  await browser.close();
  console.log(`shots: ${changed.length} of ${rows.length} screens changed; sheet written to ${out}`);
  return 0;
}

// ---- before-after ----------------------------------------------------------------
async function beforeAfter(root, base, out) {
  const cfg = loadConfig(root);
  const sh = (cmd, cwd) => spawnSync('bash', ['-c', cmd], { cwd, stdio: 'inherit' }).status === 0;
  const git = (...a) => spawnSync('git', ['-C', root, ...a], { encoding: 'utf8' });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'nxt-shots-'));
  const wt = path.join(tmp, 'base'), bdir = path.join(tmp, 'before'), adir = path.join(tmp, 'after');
  const fork = git('merge-base', base, 'HEAD').stdout.trim();
  if (!fork) die(`cannot find where this branch left ${base}`);
  if (git('worktree', 'add', '--detach', wt, fork).status !== 0) die('could not create a worktree for the base');
  let rc = 1;
  try {
    // the base uses this branch's recipe, so a new or changed recipe still works on old code
    fs.mkdirSync(path.join(wt, '.github'), { recursive: true });
    fs.copyFileSync(path.join(root, CONFIG), path.join(wt, CONFIG));
    console.log(`shots: BEFORE (${fork.slice(0, 7)})`);
    if (cfg.build && !sh(cfg.build, wt)) die('the build failed on the base');
    await capture(wt, bdir);
    console.log('shots: AFTER (working tree)');
    if (cfg.build && !sh(cfg.build, root)) die('the build failed on this branch');
    await capture(root, adir);
    rc = await compare(bdir, adir, path.resolve(out));
  } finally {
    git('worktree', 'remove', '--force', wt);
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  return rc;
}

(async () => {
  const a = process.argv.slice(2), root = process.cwd();
  if (a[0] === 'capture' && a[1]) return capture(root, path.resolve(a[1]));
  if (a[0] === 'compare' && a[3]) return compare(path.resolve(a[1]), path.resolve(a[2]), path.resolve(a[3]));
  if (a[0] === 'before-after') {
    const i = a.indexOf('--base'); const base = i > 0 ? a[i + 1] : 'origin/main';
    const out = a.filter((x, k) => k > 0 && x !== '--base' && (i < 0 || k !== i + 1))[0];
    if (out) return beforeAfter(root, base, out);
  }
  console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0].replace(/^#!.*\n\/\* /, ''));
  return 2;
})().then((rc) => process.exit(rc || 0)).catch((e) => { console.log('shots: could not run: ' + e.message); process.exit(1); });
