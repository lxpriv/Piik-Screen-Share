(async () => {
  document.querySelector('button[aria-label="选择画面"]').click();
  await new Promise(resolve => setTimeout(resolve, 2000));
  return {text: document.body.innerText.slice(0, 1100), video: [...document.querySelectorAll('video')].map(video => ({readyState: video.readyState, width: video.videoWidth, height: video.videoHeight}))};
})()
