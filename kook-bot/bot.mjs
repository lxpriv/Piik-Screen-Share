import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

export function renderMessage(kind, invite = '', templates = JSON.parse(readFileSync(join(here, 'messages.json'), 'utf8')), owner = null) {
  const lines = templates[kind];
  if (!Array.isArray(lines) || !lines.length || !lines.every(line => typeof line === 'string')) {
    throw new Error(`messages.json: ${kind} must be a non-empty array of text lines.`);
  }
  const template = lines.join('\n');
  if (kind === 'start' && !template.includes('{invite}')) throw new Error('messages.json: start must keep the {invite} placeholder.');
  if (kind === 'end' && /\{invite\}|https?:\/\//i.test(template)) throw new Error('messages.json: end must not include an invitation or clickable URL/link.');
  const content = lines.filter(line => owner || !line.includes('{owner}') || line.includes('{invite}')).join('\n');
  const escapedOwner = (owner || '').replace(/[\\`*_~[\]()]/g, '\\$&').replace(/[\r\n]+/g, ' ');
  return content.replace(/\{(invite|owner)\}/g, (_, key) => key === 'invite' ? invite : escapedOwner);
}

function ownerUserId(ownerFile = join(here, '..', 'piik', 'data', 'kook-user-id.txt')) {
  let id;
  try { id = readFileSync(ownerFile, 'utf8').trim(); } catch (error) { if (error.code === 'ENOENT') return ''; throw error; }
  if (!id) return '';
  if (!/^[0-9]{1,32}$/.test(id)) throw new Error('KOOK user ID must contain digits only. Copy your own user ID, not the Bot Token.');
  return id;
}

async function lookupOwner(id, guildId, request) {
  const user = await request(`/user/view?user_id=${encodeURIComponent(id)}&guild_id=${encodeURIComponent(guildId)}`);
  const nickname = user.nickname?.trim() || user.username?.trim();
  if (user.id !== id || user.bot || !nickname) throw new Error('Could not resolve the bound KOOK member in the target server. Check your user ID.');
  return {id, guildId, nickname};
}

function readState(stateFile) {
  return existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, 'utf8')) : null;
}

function saveState(stateFile, state) {
  mkdirSync(dirname(stateFile), {recursive: true});
  writeFileSync(`${stateFile}.tmp`, JSON.stringify(state, null, 2));
  renameSync(`${stateFile}.tmp`, stateFile);
}

export async function expire({config, stateFile, request}) {
  const state = readState(stateFile);
  if (!state) return {status: 'no-message'};
  if (state.expiredAt) return {status: 'already-expired'};
  if (!config.bot_token?.trim()) throw new Error('Bot token is missing; cannot update the invitation.');
  request ??= (path, body) => kookRequest(config.bot_token, path, body);
  let owner = state.owner;
  if (owner) {
    try { owner = await lookupOwner(owner.id, owner.guildId, request); } catch { /* Removing an old invitation must not depend on a nickname lookup. */ }
  }
  await request('/message/update', {
    msg_id: state.messageId,
    content: renderMessage('end', '', undefined, owner?.nickname),
  });
  saveState(stateFile, {...state, owner, expiredAt: new Date().toISOString()});
  return {status: 'expired', messageId: state.messageId};
}

export async function kookRequest(token, path, body) {
  const response = await fetch(`https://www.kookapp.cn/api/v3${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {Authorization: `Bot ${token}`, 'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
    redirect: 'error',
  });
  let result;
  try { result = await response.json(); } catch { throw new Error(`KOOK returned invalid JSON (HTTP ${response.status})`); }
  if (!response.ok || result.code !== 0) {
    throw new Error(`KOOK API failed (HTTP ${response.status}, code ${result.code ?? 'unknown'}): ${result.message || 'request rejected'}`);
  }
  return result.data;
}

async function listAll(request, path) {
  const items = [];
  for (let page = 1; ; page++) {
    const data = await request(`${path}${path.includes('?') ? '&' : '?'}page=${page}&page_size=50`);
    items.push(...data.items);
    if (page >= (data.meta?.page_total ?? 1)) return items;
  }
}

async function targetChannel(config, request) {
  const guilds = await listAll(request, '/guild/list');
  const matching = guilds.filter(g => config.guild_id ? g.id === config.guild_id : g.name === config.guild_name);
  if (matching.length !== 1) throw new Error('Target guild/server is missing or ambiguous. Invite the bot, check verification restrictions, or set guild_id.');
  const guild = matching[0];
  let channelId = config.channel_id;
  if (!channelId) {
    const channels = await listAll(request, `/channel/list?guild_id=${encodeURIComponent(guild.id)}&type=1`);
    const matches = channels.filter(c => c.name === config.channel_name && c.type === 1 && !c.is_category);
    if (matches.length !== 1) throw new Error('Target text channel is missing or ambiguous. Check bot visibility or set channel_id.');
    channelId = matches[0].id;
  }
  const channel = await request(`/channel/view?target_id=${encodeURIComponent(channelId)}`);
  if (channel.guild_id !== guild.id) throw new Error('Channel belongs to another guild/server; refusing to send.');
  if (channel.type !== 1 || channel.is_category) throw new Error('Target must be a text channel, not a category or voice channel.');
  if (channel.name !== config.channel_name) throw new Error('Channel name does not match configuration; refusing to send.');
  return {guild, channel};
}

export function currentInvitation(inviteFile, publicFile) {
  const value = readFileSync(inviteFile, 'utf8').trim();
  const url = new URL(value);
  const origin = new URL(readFileSync(publicFile, 'utf8').trim());
  if (url.protocol !== 'https:' || url.username || url.password || !/^\/r\/[1-9][0-9]{3}$/.test(url.pathname) || url.search) {
    throw new Error('Invalid Piik viewer invitation. Host/admin URLs must never be posted.');
  }
  if (url.origin !== origin.origin) throw new Error('Stale invitation: URL does not match the current public origin.');
  return value;
}

export async function publish({config, inviteFile, publicFile, stateFile, ownerFile, request, dryRun = false, force = false}) {
  if (!config.bot_token?.trim()) throw new Error('Bot token is missing. Fill in config.local.json locally.');
  if (!config.guild_name && !config.guild_id) throw new Error('Target guild/server is missing.');
  const invite = currentInvitation(inviteFile, publicFile);
  request ??= (path, body) => kookRequest(config.bot_token, path, body);
  const {guild, channel} = await targetChannel(config, request);
  const userId = ownerUserId(ownerFile);
  const key = `${channel.id}\n${invite}\n${userId}`;
  if (dryRun) return {status: 'checked', guild: guild.name, channel: channel.name, channelId: channel.id, invite};
  const previous = readState(stateFile);
  if (!force && previous?.key === key && !previous.expiredAt) return {status: 'unchanged'};
  const owner = userId ? await lookupOwner(userId, guild.id, request) : null;
  const content = renderMessage('start', invite, undefined, owner?.nickname);
  const restore = !force && previous?.key === key && previous.expiredAt;
  let sent;
  if (restore) {
    await request('/message/update', {msg_id: previous.messageId, content});
    sent = {msg_id: previous.messageId};
  } else {
    if (previous && !previous.expiredAt) await expire({config, stateFile, request});
    sent = await request('/message/create', {type: 9, target_id: channel.id, content});
  }
  if (!sent?.msg_id) throw new Error('KOOK did not return a message ID; check the channel before retrying.');
  saveState(stateFile, {key, messageId: sent.msg_id, sentAt: new Date().toISOString(), owner});
  return {status: restore ? 'restored' : 'sent', guild: guild.name, channel: channel.name, messageId: sent.msg_id, invite};
}

async function main() {
  const flags = new Set(process.argv.slice(2));
  if (![...flags].every(f => ['--send', '--check', '--check-owner', '--expire', '--force'].includes(f)) || ['--send', '--check', '--check-owner', '--expire'].filter(f => flags.has(f)).length !== 1 || (flags.has('--force') && !flags.has('--send'))) {
    throw new Error('Usage: node bot.mjs --check | --check-owner | --send [--force] | --expire');
  }
  const configFile = join(here, 'config.local.json');
  if (!existsSync(configFile)) throw new Error('Create config.local.json from config.example.json first.');
  const config = JSON.parse(readFileSync(configFile, 'utf8'));
  config.bot_token = process.env.KOOK_BOT_TOKEN || config.bot_token;
  if (!config.bot_token?.trim()) throw new Error('Fill bot_token in config.local.json locally; do not paste it into chat.');
  if (flags.has('--check-owner')) {
    const request = (path, body) => kookRequest(config.bot_token, path, body);
    const {guild} = await targetChannel(config, request);
    const userId = ownerUserId();
    console.log(JSON.stringify(userId ? await lookupOwner(userId, guild.id, request) : {anonymous: true}));
    return;
  }
  const stateFile = join(here, 'data', 'last-message.json');
  if (flags.has('--expire')) {
    console.log(JSON.stringify(await expire({config, stateFile}), null, 2));
    return;
  }
  const piikData = join(here, '..', 'piik', 'data');
  const inviteFile = join(piikData, 'invite-url.txt');
  const publicFile = join(piikData, 'public-url.txt');
  const invite = currentInvitation(inviteFile, publicFile);
  const health = await fetch(`${new URL(invite).origin}/healthz`, {signal: AbortSignal.timeout(10000), redirect: 'error'});
  if (!health.ok || (await health.json()).status !== 'ok') throw new Error('Piik public service is not healthy. Start Piik and refresh its invitation first.');
  console.log(JSON.stringify(await publish({config, inviteFile, publicFile, stateFile, dryRun: flags.has('--check'), force: flags.has('--force')}), null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
