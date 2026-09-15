chrome.storage.local.get({ badged: 0 }, function (stored) {
  document.getElementById('count').textContent = String(stored.badged || 0);
});
