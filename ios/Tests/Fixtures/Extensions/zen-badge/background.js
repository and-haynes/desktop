// Counts the pages the content script reported, and puts the count on the
// toolbar action. Exercises runtime messaging, storage and the action API —
// all three of which WebKit implements.
chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
  if (!message || message.kind !== 'badge-inserted') { return; }
  chrome.storage.local.get({ badged: 0 }, function (stored) {
    var badged = (stored.badged || 0) + 1;
    chrome.storage.local.set({ badged: badged });
    chrome.action.setBadgeText({ text: String(badged) });
  });
  sendResponse({ ok: true });
});

chrome.runtime.onInstalled.addListener(function () {
  chrome.action.setBadgeText({ text: '0' });
});
