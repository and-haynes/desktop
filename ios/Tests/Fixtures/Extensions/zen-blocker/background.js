// declarativeNetRequest does the blocking itself — the rules are static and
// WebKit compiles them at load. This only reports what was matched, which is
// what `declarativeNetRequestFeedback` is for, and is the part a test can see.
if (chrome.declarativeNetRequest && chrome.declarativeNetRequest.onRuleMatchedDebug) {
  chrome.declarativeNetRequest.onRuleMatchedDebug.addListener(function (info) {
    chrome.action.setBadgeText({ text: 'X' });
    console.log('zen-blocker blocked', info && info.request && info.request.url);
  });
}
