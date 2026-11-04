// usage: node render.mjs <outdir> <t1,t2,...|all> [fps] [dur]
import { spawn } from 'node:child_process';
import { writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
const [outDir, which='all', fpsS='30', durS='21.5'] = process.argv.slice(2);
mkdirSync(outDir, { recursive: true });
const port = 9333;
const prof = mkdtempSync(path.join(tmpdir(), 'bragchrome-'));
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${prof}`, '--hide-scrollbars', '--force-device-scale-factor=1', '--allow-file-access-from-files', 'about:blank'], { stdio: 'ignore' });
let ver; for (let i=0;i<60;i++) { try { ver = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); if (ver.length) break; } catch {} await new Promise(r=>setTimeout(r,250)); }
const ws = new WebSocket(ver.find(x=>x.type==='page').webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(); const events = [];
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); } else events.push(d); };
const send = (method, params={}) => new Promise(r => { const i=++id; pend.set(i, r); ws.send(JSON.stringify({id:i, method, params})); });
await send('Emulation.setDeviceMetricsOverride', { width:1920, height:1080, deviceScaleFactor:1, mobile:false });
await send('Page.enable');
await send('Page.navigate', { url: 'file://' + path.resolve('video.html') + (process.env.WEB ? '?web' : '') });
await new Promise(r=>setTimeout(r,1500));
await send('Runtime.evaluate', { expression: 'window.ready', awaitPromise: true });
const fps = +fpsS, dur = +durS;
const times = which === 'all' ? Array.from({length: Math.round(fps*dur)}, (_,i)=>i/fps) : which.split(',').map(Number);
let n = 0;
for (const t of times) {
  await send('Runtime.evaluate', { expression: `render(${t}); new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))`, awaitPromise: true });
  const r = await send('Page.captureScreenshot', { format: which==='all' ? 'png' : 'jpeg', quality: 90 });
  const name = which === 'all' ? `f${String(n).padStart(4,'0')}.png` : `t${t.toFixed(2)}.jpg`;
  writeFileSync(path.join(outDir, name), Buffer.from(r.result.data, 'base64')); n++;
}
ws.close(); chrome.kill();
console.log('frames', n);
