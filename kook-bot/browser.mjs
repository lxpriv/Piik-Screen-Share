// Piik v2.8: use its existing preview/invitation UI; never read Host tokens.
export async function evaluate(page, expression) {
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Chrome connection timed out')), 3000);
      socket.onopen = () => { clearTimeout(timer); resolve(); };
      socket.onerror = () => { clearTimeout(timer); reject(new Error('Chrome connection failed')); };
    });
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Chrome evaluation timed out')), 3000);
      socket.onmessage = event => {
        const message = JSON.parse(event.data);
        if (message.id !== 1) return;
        clearTimeout(timer);
        if (message.error || message.result?.exceptionDetails) return reject(new Error('Piik page could not be inspected'));
        resolve(message.result.result.value);
      };
      socket.send(JSON.stringify({id: 1, method: 'Runtime.evaluate', params: {expression, returnByValue: true}}));
    });
  } finally { socket.close(); }
}

async function hostPages(publicOrigin) {
  const pages = await (await fetch('http://127.0.0.1:9227/json/list', {signal: AbortSignal.timeout(3000)})).json();
  const origins = new Set(['http://localhost:8787', 'http://127.0.0.1:8787']);
  if (publicOrigin) origins.add(new URL(publicOrigin).origin);
  return pages.filter(page => {
    if (page.type !== 'page') return false;
    try { const url = new URL(page.url); return origins.has(url.origin) && url.pathname === '/'; }
    catch { return false; }
  });
}

export function needsInvitation(state, publicOrigin) {
  if (!state?.live) return false;
  try { return new URL(state.invite).origin !== new URL(publicOrigin).origin; }
  catch { return true; }
}

export async function ensureInvitation(state) {
  if (!state?.live || !state.page) return false;
  return evaluate(state.page, `(() => {
    if (!document.querySelector('#host-stop-share')) return false;
    const field = document.querySelector('.lr-invite-field');
    const rotate = field?.previousElementSibling?.querySelectorAll('button')[1];
    if (!rotate || rotate.disabled || rotate.getAttribute('aria-disabled') === 'true') return false;
    rotate.click();
    return true;
  })()`);
}

export async function stopHostPages(publicOrigin) {
  let pages;
  try { pages = await hostPages(publicOrigin); }
  catch (error) {
    if (error.cause?.code === 'ECONNREFUSED') return {closed: 0};
    throw error;
  }
  for (const page of pages) {
    const response = await fetch(`http://127.0.0.1:9227/json/close/${encodeURIComponent(page.id)}`, {signal: AbortSignal.timeout(3000)});
    if (!response.ok) throw new Error('Could not close a Piik Host capture page.');
  }
  return {closed: pages.length};
}

export async function shareState(publicOrigin) {
  for (const page of await hostPages(publicOrigin)) {
    const state = await evaluate(page, `(() => {
      const video = document.querySelector('.lr-tv-screen video');
      const track = video?.srcObject?.getVideoTracks?.()[0];
      return {
        sharing: !!document.querySelector('#host-stop-share, #host-cancel-share'),
        live: !!document.querySelector('#host-stop-share') && track?.readyState === 'live' && video.readyState >= 2 && video.videoWidth > 0,
        invite: document.querySelector('input.lr-invite-url')?.value || null
      };
    })()`);
    if (state.sharing) return {...state, page};
  }
  return {sharing: false, live: false, invite: null};
}

export async function liveInvitation(publicOrigin) {
  const state = await shareState(publicOrigin);
  return state.live ? state.invite : null;
}
