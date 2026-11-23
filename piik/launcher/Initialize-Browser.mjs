import {setTimeout as delay} from 'node:timers/promises';
import {existsSync, mkdirSync, writeFileSync} from 'node:fs';
import {evaluate, localPort} from '../../kook-bot/browser.mjs';

// Configure a fresh installation through Piik's own UI, without copying a Host identity.
const deadline = Date.now() + 20000;
const marker = new URL('../data/private-default.ready', import.meta.url);
const origins = new Set([`http://localhost:${localPort()}`, `http://127.0.0.1:${localPort()}`]);
while (true) {
  try {
    const pages = await (await fetch('http://127.0.0.1:9227/json/list', {signal: AbortSignal.timeout(2000)})).json();
    const page = pages.find(page => {
      if (page.type !== 'page') return false;
      try { const url = new URL(page.url); return origins.has(url.origin) && url.pathname === '/'; }
      catch { return false; }
    });
    if (page && await evaluate(page, `(() => {
      const key = 'piik:host-creation-profile:v1';
      const saved = JSON.parse(localStorage.getItem(key) || 'null');
      if (${existsSync(marker)} && saved && ['open','private'].includes(saved.codeEntryPolicy)) return true;
      const button = document.querySelector('button[aria-label="私密"], button[aria-label="Private"]');
      if (!button) {
        if (saved?.codeEntryPolicy === 'private' && !saved.roomPassword) return true;
        if (!saved || saved.codeEntryPolicy !== 'private') {
          localStorage.setItem(key, JSON.stringify({codeEntryPolicy:'private',roomPassword:null}));
          location.reload();
        }
        return false;
      }
      if (button.getAttribute('aria-pressed') !== 'true') button.click();
      const updated = JSON.parse(localStorage.getItem(key) || 'null');
      return button.getAttribute('aria-pressed') === 'true' && updated?.codeEntryPolicy === 'private' && !updated.roomPassword;
    })()`)) {
      mkdirSync(new URL('../data/', import.meta.url), {recursive: true});
      writeFileSync(marker, 'Private default configured.\n');
      console.log('Piik browser ready; new installations default to private, password-free sharing.');
      break;
    }
  } catch { /* The browser may still be starting. */ }
  if (Date.now() > deadline) throw new Error('Could not initialize the dedicated sharing browser. Close it and retry Start.');
  await delay(300);
}
