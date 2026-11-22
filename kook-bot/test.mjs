import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Catches: sending a stale tunnel URL, selecting another guild's same-name channel,
// resending an unchanged invitation, or treating KOOK's JSON error as success.
const bot = await import('./bot.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND') return {};
  throw error;
});
assert.equal(typeof bot.publish, 'function', 'Missing invitation publisher');
assert.equal(typeof bot.renderMessage, 'function', 'Message text needs an editable template');
const templates = {start: ['自定义开播', '[进房]({invite})'], end: ['自定义结束']};
assert.equal(bot.renderMessage('start', 'https://new.trycloudflare.com/r/8988#v=example', templates), '自定义开播\n[进房](https://new.trycloudflare.com/r/8988#v=example)');
assert.equal(bot.renderMessage('end', '', templates), '自定义结束');
assert.throws(() => bot.renderMessage('start', 'https://example.com', {start: ['漏了入口']}), /invite/);
assert.throws(() => bot.renderMessage('end', '', {end: ['结束了，旧链接 https://example.com']}), /link|URL/i);
const dir = mkdtempSync(join(tmpdir(), 'piik-kook-test-'));
try {
  const inviteFile = join(dir, 'invite-url.txt');
  const publicFile = join(dir, 'public-url.txt');
  const stateFile = join(dir, 'last-message.json');
  const ownerFile = join(dir, 'kook-user-id.txt');
  writeFileSync(ownerFile, '12345678');
  writeFileSync(publicFile, 'https://new.trycloudflare.com\n');
  writeFileSync(inviteFile, 'https://old.trycloudflare.com/r/8988');
  const config = {bot_token: 'test-token', guild_name: '吉吉电竞', channel_name: 'link_test', channel_id: ''};
  const messages = [];
  const updates = [];
  let nickname = '当前服务器昵称';
  let ownerLookups = 0;
  const request = async (path, body) => {
    if (path.startsWith('/guild/list')) return {items: [{id: 'g1', name: '吉吉电竞'}, {id: 'g2', name: '另一服务器'}], meta: {page_total: 1}};
    if (path.startsWith('/channel/list')) {
      assert.ok(path.includes('guild_id=g1'));
      return {items: [{id: 'c1', name: 'link_test', guild_id: 'g1', type: 1, is_category: false, parent_id: 'p1'}], meta: {page_total: 1}};
    }
    if (path === '/channel/view?target_id=c1') return {id: 'c1', guild_id: 'g1', name: 'link_test', type: 1, is_category: false};
    if (path === '/user/view?user_id=12345678&guild_id=g1') { ownerLookups++; return {id: '12345678', username: '账号名称', nickname, bot: false}; }
    if (path === '/message/create') { messages.push(body); return {msg_id: 'm1'}; }
    if (path === '/message/update') { updates.push(body); return []; }
    throw new Error(`Unexpected API request: ${path}`);
  };
  const options = {config, inviteFile, publicFile, stateFile, ownerFile, request};
  await assert.rejects(() => bot.publish(options), /stale|match/i);
  assert.equal(messages.length, 0);
  writeFileSync(inviteFile, 'https://new.trycloudflare.com/r/8988#v=example');
  const sent = await bot.publish(options);
  assert.equal(sent.status, 'sent');
  assert.equal(messages[0].target_id, 'c1');
  assert.equal(messages[0].type, 9);
  const clickable = messages[0].content.match(/\[[^\]\n]+\]\((https:\/\/[^\s)]+)\)/);
  assert.equal(clickable?.[1], 'https://new.trycloudflare.com/r/8988#v=example', 'Invitation must be a clickable KMarkdown link preserving the complete grant');
  assert.ok(messages[0].content.includes('用浏览器打开'), 'Invitation should explain KOOK browser opening');
  assert.ok(!messages[0].content.includes('test-token'));
  assert.ok(messages[0].content.includes(nickname), 'Use the current server nickname, not the account username');
  assert.equal((await bot.publish(options)).status, 'unchanged');
  assert.equal(messages.length, 1);
  const previous = readFileSync(stateFile, 'utf8');
  writeFileSync(inviteFile, 'https://new.trycloudflare.com/r/8999');
  await assert.rejects(() => bot.publish({...options, request: async (path, body) => {
    if (path === '/message/create') throw new Error('KOOK denied the message');
    return request(path, body);
  }}), /denied/);
  assert.equal(JSON.parse(readFileSync(stateFile, 'utf8')).key, JSON.parse(previous).key, 'Failed send must not record the new unsent invitation');
  writeFileSync(stateFile, previous);
  await assert.rejects(() => bot.publish({...options, config: {...config, bot_token: ''}}), /token/i);
  await assert.rejects(() => bot.publish({...options, request: async (path, body) => {
    if (path === '/channel/view?target_id=c1') return {id: 'c1', guild_id: 'g2', name: 'link_test', type: 1, is_category: false};
    return request(path, body);
  }}), /guild|server/i);
  const actualFetch = globalThis.fetch;
  try {
    globalThis.fetch = async (url, options) => {
      assert.equal(String(url), 'https://www.kookapp.cn/api/v3/message/create');
      assert.equal(options.headers.Authorization, 'Bot test-token');
      return {ok: true, status: 200, json: async () => ({code: 403, message: 'forbidden', data: {}})};
    };
    await assert.rejects(() => bot.kookRequest('test-token', '/message/create', {target_id: 'c1', content: 'test'}), /403|forbidden/);
  } finally { globalThis.fetch = actualFetch; }
  assert.equal(typeof bot.expire, 'function', 'Missing ended-share message update');
  const beforeExpiry = readFileSync(stateFile, 'utf8');
  await assert.rejects(() => bot.expire({config, stateFile, request: async () => { throw new Error('update denied'); }}), /update denied/);
  assert.equal(readFileSync(stateFile, 'utf8'), beforeExpiry, 'Failed edit must remain pending');
  assert.equal((await bot.expire({config, stateFile, request})).status, 'expired');
  assert.equal(updates.at(-1).msg_id, 'm1');
  assert.ok(updates.at(-1).content.includes('共享已结束'));
  assert.ok(!updates.at(-1).content.includes('https://'), 'Ended message must contain no clickable URL');
  const updateCount = updates.length;
  assert.equal((await bot.expire({config, stateFile, request})).status, 'already-expired');
  assert.equal(updates.length, updateCount);
  writeFileSync(inviteFile, 'https://new.trycloudflare.com/r/8988#v=example');
  nickname = '改过的服务器昵称';
  assert.equal((await bot.publish(options)).status, 'restored', 'Restarting the same room must restore its invitation');
  assert.equal(messages.length, 1, 'Restoring the same invitation should edit its existing message');
  assert.ok(/\[[^\]\n]+\]\(https:\/\/new\.trycloudflare\.com\/r\/8988#v=example\)/.test(updates.at(-1).content));
  assert.ok(!JSON.parse(readFileSync(stateFile, 'utf8')).expiredAt);
  assert.ok(updates.at(-1).content.includes(nickname), 'A later share must fetch the latest server nickname');
  writeFileSync(inviteFile, 'https://new.trycloudflare.com/r/8999');
  assert.equal((await bot.publish(options)).status, 'sent');
  assert.ok(updates.at(-1).content.includes('共享已结束'), 'Changing invitations must retire the previous message');
  assert.equal(messages.length, 2);
  writeFileSync(ownerFile, '');
  const anonymousState = join(dir, 'anonymous-message.json');
  const lookupsBeforeAnonymous = ownerLookups;
  assert.equal((await bot.publish({...options, stateFile: anonymousState})).status, 'sent');
  assert.ok(!messages.at(-1).content.includes('屏享主人') && !messages.at(-1).content.includes('{owner}') && !messages.at(-1).content.includes(nickname));
  assert.ok(messages.at(-1).content.includes('https://new.trycloudflare.com/r/8999'));
  assert.equal(JSON.parse(readFileSync(anonymousState, 'utf8')).owner, null);
  await bot.expire({config, stateFile: anonymousState, request});
  assert.ok(!updates.at(-1).content.includes('屏享主人') && !updates.at(-1).content.includes(nickname));
  assert.equal(ownerLookups, lookupsBeforeAnonymous, 'Anonymous shares must not query a member profile');
  assert.equal((await bot.publish({...options, stateFile: join(dir, 'missing-owner-state.json'), ownerFile: join(dir, 'absent-id.txt')})).status, 'sent');
  writeFileSync(ownerFile, 'not-a-user-id');
  await assert.rejects(() => bot.publish({...options, stateFile: anonymousState}), /digits|ID/i);
  console.log('PASS: current invite, exact target, duplicate suppression, and error handling');
} finally { rmSync(dir, {recursive: true, force: true}); }
