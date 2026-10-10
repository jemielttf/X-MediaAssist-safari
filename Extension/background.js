"use strict";
// Routes messages from the popup and X pages to the native app extension.
// Accepted messages: checkConnection, getGIFOptions (popup only), downloadPost.

// Posts being saved by this background; at most 3 at a time, one per post.
const activePosts = new Set();
// Identifies this background lifetime; it is not an authentication token.
const backgroundInstance = `${Date.now()}-${Math.random()}`;

browser.runtime.onMessage.addListener((message, sender) => {
  const core = globalThis.XMediaCore;
  const t = core.t;
  const sendNative = payload => browser.runtime.sendNativeMessage(core.NATIVE_APP, payload);

  // Only this extension's popup or its content script on an X page may talk to us.
  const popupURL = browser.runtime.getURL("popup.html");
  const fromPopup = sender.id === browser.runtime.id && sender.url === popupURL;
  const allowed = fromPopup || (sender.id === browser.runtime.id && sender.tab && core.isXPage(sender.url));

  if (allowed && message?.type === "checkConnection") {
    return Promise.resolve({ ok: true, instance: backgroundInstance });
  }
  if (fromPopup && message?.type === "getGIFOptions") {
    return core.pingNative(sendNative, 15000, t("native_unavailable"))
      .then(options => ({ ok: true, gifOptions: core.validateGIFOptions(options) }))
      .catch(error => ({ ok: false, error: error.message }));
  }

  // Everything else must be a well-formed downloadPost request.
  const format = message?.format ?? "auto";
  if (!allowed || message?.type !== "downloadPost" || !core.isPostId(message.postId) ||
      !["auto", "mp4"].includes(format)) {
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
  return core.downloadPost(message.postId, { format, gifOptions: message.gifOptions, sendNative })
    .finally(() => activePosts.delete(message.postId));
});
