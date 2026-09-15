browser.webRequest.onBeforeRequest.addListener(
  function (details) { return { cancel: true }; },
  { urls: ["<all_urls>"] },
  ["blocking"]
);

browser.contextualIdentities.query({}).then(function (containers) {
  browser.sidebarAction.setTitle({ title: containers.length + ' containers' });
});

browser.browsingData.remove({ since: 0 }, { cookies: true });
browser.storage.local.set({ ready: true });
