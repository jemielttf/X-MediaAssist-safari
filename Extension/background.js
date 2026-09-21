"use strict";
const activePosts = new Set();
browser.runtime.onMessage.addListener((message, sender) => {
  const core = globalThis.XMediaCore;
  const popupURL = browser.runtime.getURL("popup.html");
  const allowed = sender.id === browser.runtime.id && (sender.url === popupURL || (sender.tab && core.isXPage(sender.url)));
  if (!allowed || message?.type !== "downloadPost" || !core.isPostId(message.postId) || !["auto", "mp4"].includes(message.format ?? "auto")) {
    return Promise.resolve({ ok: false, saved: [], error: "保存リクエストを受け付けられませんでした。" });
  }
  if (activePosts.has(message.postId) || activePosts.size >= 3) {
    return Promise.resolve({ ok: false, saved: [], error: "保存処理中です。完了してから再試行してください。" });
  }
  activePosts.add(message.postId);
  return core.downloadPost(message.postId, {
    format: message.format ?? "auto",
    sendNative: payload => browser.runtime.sendNativeMessage("com.jemielttf.XMediaAssist", payload)
  }).finally(() => activePosts.delete(message.postId));
});
