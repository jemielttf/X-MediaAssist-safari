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
    return core.withTimeout(() => browser.runtime.sendNativeMessage("com.jemielttf.XMediaAssist", { type: "ping" }),
      15000, t("gif_options_load_failed"))
      .then(reply => {
        if (reply?.ok !== true || reply.protocolVersion !== 3) throw new Error(t("restart_safari"));
        return { ok: true, gifOptions: core.validateGIFOptions(reply.gifOptions ?? core.GIF_DEFAULTS) };
      }).catch(error => ({ ok: false, error: error.message }));
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
    sendNative: payload => browser.runtime.sendNativeMessage("com.jemielttf.XMediaAssist", payload)
  }).finally(() => activePosts.delete(message.postId));
});
