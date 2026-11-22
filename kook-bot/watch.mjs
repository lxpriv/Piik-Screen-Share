import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { ensureInvitation, liveInvitation, needsInvitation, shareState } from './browser.mjs';
import { currentInvitation, expire, publish } from './bot.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const piikData = join(here, '..', 'piik', 'data');
const inviteFile = join(piikData, 'invite-url.txt');
const publicFile = join(piikData, 'public-url.txt');
const stateFile = join(here, 'data', 'last-message.json');
const activityFile = join(here, 'data', 'activity.txt');
const stopFile = join(here, 'data', 'stop-request.txt');
function stopRequested() {
  try { return readFileSync(stopFile, 'utf8').trim() === String(process.pid); }
  catch { return false; }
}
let activity;
function report(value) {
  if (activity === value) return;
  mkdirSync(dirname(activityFile), {recursive: true});
  writeFileSync(activityFile, `${process.pid}\n${value}\n`);
  activity = value;
}
const config = JSON.parse(readFileSync(join(here, 'config.local.json'), 'utf8'));
config.bot_token = process.env.KOOK_BOT_TOKEN || config.bot_token;
if (!config.bot_token?.trim()) throw new Error('Bot Token is missing. Fill config.local.json, then run Start-Bot.ps1.');
console.log('Waiting for a live Piik Host preview. Poll interval: 2 seconds.');
report('waiting');
let attempted = null;
let inactiveSamples = 0;
let invitationRequested = false;

function servicesRunning() {
  try {
    for (const name of ['server', 'tunnel']) process.kill(Number(readFileSync(join(piikData, `${name}.pid`), 'utf8').trim()), 0);
    return true;
  } catch { return false; }
}

try {
  while (!stopRequested()) {
    let state = null;
    let publicOrigin;
    try {
      publicOrigin = readFileSync(publicFile, 'utf8').trim();
      if (servicesRunning()) state = await shareState(publicOrigin);
    } catch (error) {
      if (error.cause?.code !== 'ECONNREFUSED') {
        // An unreadable debugger is not proof that the user stopped capturing.
        report('browser-error');
        await delay(2000);
        continue;
      }
    }
    inactiveSamples = state?.sharing ? 0 : inactiveSamples + 1;
    if (!state?.sharing) invitationRequested = false;
    if (inactiveSamples === 3) {
      report('ending');
      console.log(JSON.stringify(await expire({config, stateFile})));
      attempted = null;
    }
    if (needsInvitation(state, publicOrigin)) {
      report(attempted === null ? 'inviting' : 'no-invite');
      // Generate an initial invite; do not undo a manual revocation after publishing this share.
      if (!invitationRequested && attempted === null && await ensureInvitation(state)) {
        invitationRequested = true;
        console.log(JSON.stringify({status: 'creating-invitation', reason: 'missing-or-old-public-origin'}));
      }
      await delay(2000);
      continue;
    }
    if (state?.invite) invitationRequested = false;
    const invite = state?.live ? state.invite : null;
    if (invite && invite !== attempted) {
      report('publishing');
      mkdirSync(piikData, {recursive: true});
      writeFileSync(inviteFile, invite + '\n');
      currentInvitation(inviteFile, publicFile);
      const origin = new URL(invite).origin;
      const response = await fetch(`${origin}/healthz`, {signal: AbortSignal.timeout(10000), redirect: 'error'});
      if (!response.ok || (await response.json()).status !== 'ok') throw new Error('Public Piik health check failed; no invitation was sent.');
      // Recheck after the public request, so stopping or changing rooms cannot post the previous share.
      if (stopRequested() || (await liveInvitation(publicOrigin)) !== invite) continue;
      const result = await publish({config, inviteFile, publicFile, stateFile});
      console.log(JSON.stringify(result));
      attempted = invite;
    }
    report(state?.live ? 'sharing' : state?.sharing ? 'preparing' : 'waiting');
    await delay(2000);
  }
} catch (error) {
  // ponytail: fail visibly without auto-retrying an uncertain send; inspect the channel/log before restarting.
  console.error(error.message);
  report('error');
  process.exitCode = 1;
}
