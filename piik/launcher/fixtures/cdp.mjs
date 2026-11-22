import { readFileSync } from 'node:fs';

const pages = await (await fetch('http://127.0.0.1:9227/json/list')).json();
const page = pages.find(p => p.type === 'page' && p.url.startsWith(process.argv[2]));
if (!page) throw new Error('Piik page not found');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
const result = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('Browser command timed out')), 20000);
  ws.onmessage = e => {
    const message = JSON.parse(e.data);
    if (message.id !== 1) return;
    clearTimeout(timer);
    resolve(message);
  };
  ws.send(JSON.stringify({id: 1, method: 'Runtime.evaluate', params: {
    expression: readFileSync(process.argv[3], 'utf8'), awaitPromise: true, returnByValue: true, userGesture: true,
  }}));
});
ws.close();
if (result.error || result.result?.exceptionDetails) throw new Error(JSON.stringify(result));
console.log(JSON.stringify(result.result.result.value, null, 2));
