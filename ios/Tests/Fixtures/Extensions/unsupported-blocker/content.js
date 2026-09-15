browser.runtime.sendMessage({ kind: 'seen', href: location.href });
browser.sidebarAction.open();
