import {existsSync, readFileSync} from 'node:fs';
import {stopHostPages} from '../../kook-bot/browser.mjs';

const file = new URL('../data/public-url.txt', import.meta.url);
const origin = existsSync(file) ? readFileSync(file, 'utf8').trim() : undefined;
try {
  console.log(JSON.stringify(await stopHostPages(origin)));
} catch (error) {
  console.error('Piik browser capture could not be stopped: ' + error.message);
  process.exitCode = 1;
}
