document.getElementById('reset').addEventListener('click', function () {
  chrome.storage.local.set({ badged: 0 });
  chrome.action.setBadgeText({ text: '0' });
});
