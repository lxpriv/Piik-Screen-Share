import assert from 'node:assert/strict';
import {copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';

const here = dirname(fileURLToPath(import.meta.url));
const root = mkdtempSync(join(here, '..', 'piik', 'data', 'watch-test-'));
const bot = join(root, 'kook-bot');
const data = join(bot, 'data');
const piik = join(root, 'piik', 'data');
mkdirSync(data, {recursive: true});
mkdirSync(piik, {recursive: true});
for (const name of ['watch.mjs', 'bot.mjs', 'browser.mjs']) copyFileSync(join(here, name), join(bot, name));
const config = {bot_token: 'test-only', guild_name: 'test-guild', channel_name: 'test-channel', channel_id: 'channel'};
writeFileSync(join(bot, 'config.local.json'), JSON.stringify(config));
writeFileSync(join(bot, 'messages.json'), JSON.stringify({start: ['[Join]({invite})'], end: ['Ended']}));
for (const name of ['server', 'tunnel']) writeFileSync(join(piik, `${name}.pid`), String(process.pid));
writeFileSync(join(piik, 'public-url.txt'), 'https://example.com');
writeFileSync(join(piik, 'kook-user-id.txt'), '12345678');
const invitation = 'https://example.com/r/1234#v=test';
const originalFetch = globalThis.fetch;
const originalSocket = globalThis.WebSocket;
let updates = 0;
let creates = 0;
let probes = 0;
let scenario = 'probe-errors';
globalThis.WebSocket = class {
  constructor() { queueMicrotask(() => this.onopen()); }
  send() { queueMicrotask(() => this.onmessage({data: JSON.stringify({id: 1, result: {result: {value: {sharing: true, live: true, invite: invitation}}}})})); }
  close() {}
};
globalThis.fetch = async (value, options) => {
  const url = new URL(value);
  if (url.pathname === '/json/list') {
    // A temporary debugger error must not expire the running share.
    if (scenario === 'probe-errors') {
      if (++probes === 3) writeFileSync(join(data, 'stop-request.txt'), String(process.pid));
      throw new Error('Transient browser probe failure');
    }
    return Response.json([{type: 'page', url: 'http://localhost:8787/', webSocketDebuggerUrl: 'ws://test'}]);
  }
  if (url.pathname === '/healthz') return Response.json({status: 'ok'});
  let responseData;
  if (url.pathname.endsWith('/guild/list')) responseData = {items: [{id: 'guild', name: 'test-guild'}]};
  else if (url.pathname.endsWith('/channel/view')) responseData = {id: 'channel', guild_id: 'guild', name: 'test-channel', type: 1};
  else if (url.pathname.endsWith('/user/view')) responseData = {id: '12345678', nickname: 'Test member', bot: false};
  else if (url.pathname.endsWith('/message/create')) {
    creates++;
    // Request shutdown while the send is in flight, before its returned ID can be saved.
    writeFileSync(join(bot, 'data', 'stop-request.txt'), String(process.pid));
    await delay(150);
    responseData = {msg_id: 'pending-message'};
  } else if (url.pathname.endsWith('/message/update')) {
    assert.equal(scenario, 'sending', 'Browser probe errors must not expire a live invitation');
    assert.equal(JSON.parse(options.body).msg_id, 'pending-message');
    updates++;
    responseData = {};
  } else throw new Error(`Unexpected test request: ${url.pathname}`);
  return Response.json({code: 0, data: responseData});
};
try {
  const stateFile = join(data, 'last-message.json');
  writeFileSync(stateFile, JSON.stringify({messageId: 'existing-live-message', key: `channel\n${invitation}`}));
  await import(pathToFileURL(join(bot, 'watch.mjs')).href + '?probe-errors');
  assert.equal(probes, 3);
  assert.equal(updates, 0);
  assert.equal(JSON.parse(readFileSync(stateFile, 'utf8')).expiredAt, undefined);
  assert.ok(!process.exitCode, 'Watcher unexpectedly failed');
  rmSync(stateFile);
  rmSync(join(data, 'stop-request.txt'));
  scenario = 'sending';
  await import(pathToFileURL(join(bot, 'watch.mjs')).href + '?sending');
  assert.equal(JSON.parse(readFileSync(stateFile, 'utf8')).messageId, 'pending-message');
  const {expire} = await import(pathToFileURL(join(bot, 'bot.mjs')));
  await expire({config, stateFile});
  assert.equal(creates, 1);
  assert.equal(updates, 1);
  assert.ok(JSON.parse(readFileSync(stateFile, 'utf8')).expiredAt);
  console.log('PASS: transient browser probe errors preserve sharing; shutdown during a send saves its ID for expiry. No real network requests.');
} finally {
  globalThis.fetch = originalFetch;
  globalThis.WebSocket = originalSocket;
  rmSync(root, {recursive: true, force: true});
}
