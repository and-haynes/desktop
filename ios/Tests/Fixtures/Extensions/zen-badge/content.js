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

  // Second job: prove whether the *other* fixture extension is blocking.
  //
  // A 404 and a blocked request look identical to an <img> onerror handler,
  // which is why this is a fetch: declarativeNetRequest cancels the load and
  // the promise rejects, where a page that simply has no such file resolves
  // with a status. So "BLOCKED" here means blocked, not missing.
  var probe = location.origin + '/zen-blocked-resource.js?t=' + Date.now();
  fetch(probe, { cache: 'no-store' })
    .then(function (response) { badge.textContent = 'ZEN EXTENSION ACTIVE - REACHED ' + response.status; })
    .catch(function () { badge.textContent = 'ZEN EXTENSION ACTIVE - BLOCKED'; });

  chrome.runtime.sendMessage({ kind: 'badge-inserted', href: location.href });
})();
