import assert from 'node:assert/strict';
import * as browser from './browser.mjs';

assert.equal(typeof browser.needsInvitation, 'function', 'Restored rooms without an invitation must be detected');
const origin = 'https://current.trycloudflare.com';
assert.equal(browser.needsInvitation({live: true, invite: null}, origin), true);
assert.equal(browser.needsInvitation({live: true, invite: 'https://old.trycloudflare.com/r/9589#v=old'}, origin), true);
assert.equal(browser.needsInvitation({live: true, invite: origin + '/r/9589#v=current'}, origin), false);
assert.equal(browser.needsInvitation({live: false, invite: null}, origin), false);

const actualFetch = globalThis.fetch;
const closed = [];
try {
  globalThis.fetch = async url => {
    if (String(url).endsWith('/json/list')) return {json: async () => [
      {id: 'local-host', type: 'page', url: 'http://localhost:8787/?debug=1'},
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
console.log('PASS: missing/stale invites and stopping only Piik Host pages');
