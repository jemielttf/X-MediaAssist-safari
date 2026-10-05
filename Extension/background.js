"use strict";
const activePosts = new Set();
// Identifies this background lifetime; it is not an authentication token.
const backgroundInstance = `${Date.now()}-${Math.random()}`;
browser.runtime.onMessage.addListener((message, sender) => {
  const core = globalThis.XMediaCore;
  const t = core.t;
  const popupURL = browser.runtime.getURL("popup.html");
  const allowed = sender.id === browser.runtime.id && (sender.url === popupURL || (sender.tab && core.isXPage(sender.url)));
  if (allowed && message?.type === "checkConnection") {
    return Promise.resolve({ ok: true, instance: backgroundInstance });
  }
  if (sender.id === browser.runtime.id && sender.url === popupURL && message?.type === "getGIFOptions") {
    return core.pingNative(payload => browser.runtime.sendNativeMessage(core.NATIVE_APP, payload), 15000, t("native_unavailable"))
      .then(options => ({ ok: true, gifOptions: core.validateGIFOptions(options) }))
      .catch(error => ({ ok: false, error: error.message }));
  }
  if (!allowed || message?.type !== "downloadPost" || !core.isPostId(message.postId) || !["auto", "mp4"].includes(message.format ?? "auto")) {
    return Promise.resolve({ ok: false, saved: [], error: t("request_rejected") });
  }
  if (message.gifOptions !== undefined) {
    try { core.validateGIFOptions(message.gifOptions); }
    catch { return Promise.resolve({ ok: false, saved: [], error: t("invalid_gif_options") }); }
  }
  if (activePosts.has(message.postId) || activePosts.size >= 3) {
    return Promise.resolve({ ok: false, saved: [], error: t("save_busy") });
  }
  activePosts.add(message.postId);
  return core.downloadPost(message.postId, {
    format: message.format ?? "auto",
    gifOptions: message.gifOptions,
    sendNative: payload => browser.runtime.sendNativeMessage(core.NATIVE_APP, payload)
  }).finally(() => activePosts.delete(message.postId));
});
