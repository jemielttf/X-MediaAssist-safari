"use strict";
const activePosts = new Set();
browser.runtime.onMessage.addListener((message, sender) => {
  const core = globalThis.XMediaCore;
  const popupURL = browser.runtime.getURL("popup.html");
  const allowed = sender.id === browser.runtime.id && (sender.url === popupURL || (sender.tab && core.isXPage(sender.url)));
  if (sender.id === browser.runtime.id && sender.url === popupURL && message?.type === "getGIFOptions") {
    return core.withTimeout(() => browser.runtime.sendNativeMessage("com.jemielttf.XMediaAssist", { type: "ping" }),
      15000, "GIF基本設定を読み込めませんでした。")
      .then(reply => {
        if (reply?.ok !== true || reply.protocolVersion !== 3) throw new Error("Safariを終了して起動し直してください。");
        return { ok: true, gifOptions: core.validateGIFOptions(reply.gifOptions ?? core.GIF_DEFAULTS) };
      }).catch(error => ({ ok: false, error: error.message }));
  }
  if (!allowed || message?.type !== "downloadPost" || !core.isPostId(message.postId) || !["auto", "mp4"].includes(message.format ?? "auto")) {
    return Promise.resolve({ ok: false, saved: [], error: "保存リクエストを受け付けられませんでした。" });
  }
  if (message.gifOptions !== undefined) {
    try { core.validateGIFOptions(message.gifOptions); }
    catch { return Promise.resolve({ ok: false, saved: [], error: "GIF設定が正しくありません。" }); }
  }
  if (activePosts.has(message.postId) || activePosts.size >= 3) {
    return Promise.resolve({ ok: false, saved: [], error: "保存処理中です。完了してから再試行してください。" });
  }
  activePosts.add(message.postId);
  return core.downloadPost(message.postId, {
    format: message.format ?? "auto",
    gifOptions: message.gifOptions,
    sendNative: payload => browser.runtime.sendNativeMessage("com.jemielttf.XMediaAssist", payload)
  }).finally(() => activePosts.delete(message.postId));
});
