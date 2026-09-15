// Drops one unmistakable element into the page. The UI test looks for the
// literal string below, so a screenshot is not the only evidence that the
// content script ran.
(function () {
  if (document.getElementById('zen-extension-badge')) { return; }
  var badge = document.createElement('div');
  badge.id = 'zen-extension-badge';
  badge.textContent = 'ZEN EXTENSION ACTIVE';
  badge.setAttribute('style', [
    'position:fixed', 'top:0', 'left:0', 'right:0', 'z-index:2147483647',
    'background:#6b3bd6', 'color:#fff', 'font:600 16px/40px -apple-system,sans-serif',
    'text-align:center', 'letter-spacing:0.08em'
  ].join(';'));
  function attach() {
    if (document.body) { document.body.appendChild(badge); }
    else { requestAnimationFrame(attach); }
  }
  attach();
  chrome.runtime.sendMessage({ kind: 'badge-inserted', href: location.href });
})();
