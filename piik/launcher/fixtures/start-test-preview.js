(async () => {
  if (document.querySelector('#host-stop-share')) throw new Error('An existing share is active; refusing to replace it.');
  const deadline = Date.now() + 12000;
  while (!document.querySelector('button[aria-label="开始分享"]')) {
    if (Date.now() > deadline) throw new Error('Host page did not finish loading');
    await new Promise(resolve => setTimeout(resolve, 200));
  }
  const canvas = document.createElement('canvas');
  canvas.width = 1280; canvas.height = 720;
  const context = canvas.getContext('2d');
  window.piikDemoTimer = setInterval(() => {
    context.fillStyle = '#102238'; context.fillRect(0, 0, 1280, 720);
    context.fillStyle = '#7edcf1'; context.font = 'bold 62px sans-serif';
    context.fillText('Piik + KOOK demo', 120, 260);
    context.fillStyle = '#ffffff'; context.font = '34px sans-serif';
    context.fillText(new Date().toISOString(), 120, 370);
    context.fillText('Test picture - no desktop capture', 120, 440);
  }, 100);
  window.piikOriginalDisplayMedia = navigator.mediaDevices.getDisplayMedia;
  window.piikDemoStream = canvas.captureStream(10);
  navigator.mediaDevices.getDisplayMedia = async () => window.piikDemoStream;
  document.querySelector('button[aria-label="开始分享"]').click();
  return 'A generated test picture is ready; no desktop or microphone was captured.';
})()
