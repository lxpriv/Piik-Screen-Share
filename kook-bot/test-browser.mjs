import assert from 'node:assert/strict';
import * as browser from './browser.mjs';
import {copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';

assert.equal(typeof browser.needsInvitation, 'function', 'Restored rooms without an invitation must be detected');
const origin = 'https://current.trycloudflare.com';
const localOrigin = `http://localhost:${browser.localPort()}`;
assert.equal(browser.needsInvitation({live: true, invite: null}, origin), true);
assert.equal(browser.needsInvitation({live: true, invite: 'https://old.trycloudflare.com/r/9589#v=old'}, origin), true);
assert.equal(browser.needsInvitation({live: true, invite: origin + '/r/9589#v=current'}, origin), false);
assert.equal(browser.needsInvitation({live: false, invite: null}, origin), false);

const actualFetch = globalThis.fetch;
const closed = [];
try {
  globalThis.fetch = async url => {
    if (String(url).endsWith('/json/list')) return {json: async () => [
      {id: 'local-host', type: 'page', url: localOrigin + '/?debug=1'},
      {id: 'public-host', type: 'page', url: origin + '/'},
      {id: 'viewer', type: 'page', url: origin + '/r/9589'},
      {id: 'unrelated', type: 'page', url: 'https://example.com/'},
    ]};
    closed.push(String(url).split('/').pop());
    return {ok: true};
  };
  const result = await browser.stopHostPages(origin);
  assert.deepEqual(closed, ['local-host', 'public-host'], 'Stop must close capture pages and preserve viewers/other tabs');
  assert.equal(result.closed, 2);
} finally { globalThis.fetch = actualFetch; }
try {
  globalThis.fetch = async () => { throw new TypeError('fetch failed', {cause: {code: 'ECONNREFUSED'}}); };
  assert.deepEqual(await browser.stopHostPages(origin), {closed: 0}, 'An already closed browser must count as stopped');
  let calls = 0;
  globalThis.fetch = async url => {
    calls++;
    if (String(url).endsWith('/json/list')) return {json: async () => calls === 1
      ? [{id: 'closing-host', type: 'page', url: localOrigin + '/'}] : []};
    return {ok: false}; // The user closed the tab after it was enumerated.
  };
  assert.deepEqual(await browser.stopHostPages(origin), {closed: 1}, 'A concurrently closed Host must not block shutdown');
  calls = 0;
  globalThis.fetch = async () => {
    throw new TypeError('fetch failed', {cause: {code: ++calls === 1 ? 'ECONNRESET' : 'ECONNREFUSED'}});
  };
  assert.deepEqual(await browser.stopHostPages(origin), {closed: 0}, 'A browser exiting during enumeration must be rechecked');
  globalThis.fetch = async url => String(url).endsWith('/json/list')
    ? {json: async () => [{id: 'still-live', type: 'page', url: localOrigin + '/'}]}
    : {ok: false};
  await assert.rejects(browser.stopHostPages(origin), /could not close/i, 'A Host that remains open must still block shutdown');
  globalThis.fetch = async () => { throw new TypeError('Uncertain debugger failure'); };
  await assert.rejects(browser.stopHostPages(origin), /Uncertain debugger failure/, 'Unknown capture state must not be reported stopped');
} finally { globalThis.fetch = actualFetch; }
console.log('PASS: missing/stale invites and stopping only Piik Host pages');
const portTest = mkdtempSync(join(tmpdir(), 'piik-port-'));
try {
  mkdirSync(join(portTest, 'piik', 'server'), {recursive:true});
  mkdirSync(join(portTest, 'kook-bot'));
  copyFileSync(new URL('./browser.mjs', import.meta.url), join(portTest, 'kook-bot', 'browser.mjs'));
  writeFileSync(join(portTest, 'piik', 'server', '.env'), 'PORT=17887\n');
  const configuredBrowser = await import(pathToFileURL(join(portTest,'kook-bot','browser.mjs')).href);
  const configuredClosed = [];
  globalThis.fetch = async url => {
    if(String(url).endsWith('/json/list')) return {json:async()=>[
      {id:'configured-host',type:'page',url:'http://localhost:17887/'},
      {id:'other-service',type:'page',url:'http://localhost:8787/'}
    ]};
    configuredClosed.push(String(url).split('/').pop());return {ok:true};
  };
  await configuredBrowser.stopHostPages();
  assert.deepEqual(configuredClosed,['configured-host'],'Browser inspection and shutdown must follow PORT from .env');
  writeFileSync(join(portTest,'piik','server','.env'),'PORT=99999\n');
  await assert.rejects(configuredBrowser.stopHostPages(),/port/i,'An invalid configured port must fail visibly');
  console.log('PASS: configured local port is respected and invalid ports are rejected');
} finally {
  globalThis.fetch=actualFetch;
  rmSync(portTest,{recursive:true,force:true});
}
