const version = await (await fetch('http://127.0.0.1:9227/json/version')).json();
const socket = new WebSocket(version.webSocketDebuggerUrl);
try {
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Test browser did not close')), 5000);
    socket.onerror = () => { clearTimeout(timeout); reject(new Error('Test browser connection failed')); };
    socket.onopen = () => socket.send(JSON.stringify({id: 1, method: 'Browser.close'}));
    socket.onclose = () => { clearTimeout(timeout); resolve(); };
  });
} finally { socket.close(); }
