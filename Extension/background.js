"use strict";
// Routes messages from the popup and X pages to the native app extension.
// Accepted messages: checkConnection, getGIFOptions (popup only), getProgress, revealFiles, downloadPost.

// Posts being saved by this background; at most 3 at a time, one per post.
const activePosts = new Set();
// Media item currently being saved for each active post: { index, count, basename }.
const currentItems = new Map();
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
  if (allowed && message?.type === "getProgress" && core.isPostId(message.postId)) {
    return progress(message.postId, sendNative, core);
  }
  if (allowed && message?.type === "revealFiles") {
    return reveal(message.filenames, sendNative, core);
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

  const postId = message.postId;
  activePosts.add(postId);
  const onItem = item => currentItems.set(postId, item);
  return core.downloadPost(postId, { format, gifOptions: message.gifOptions, sendNative, onItem })
    .then(result => { notify(result, sendNative, core); return result; })
    .finally(() => { activePosts.delete(postId); currentItems.delete(postId); });
});

// Announces the result even if the tab or popup was closed. Not awaited: the page gets
// its result right away, and an older native side or a denied permission changes nothing.
function notify(result, sendNative, core) {
  try {
    Promise.resolve(sendNative({ type: "notify", ...core.notificationContent(result) })).catch(() => {});
  } catch { /* notification is best effort */ }
}

// { index, count } of the post's current item plus the native transfer/conversion state.
// index 0 means the post metadata is still being fetched; null means no save is running.
async function progress(postId, sendNative, core) {
  if (!activePosts.has(postId)) return { ok: true, progress: null };
  const item = currentItems.get(postId);
  if (!item) return { ok: true, progress: { index: 0, count: 0 } };
  let native = null;
  try {
    const reply = await core.withTimeout(
      () => sendNative({ type: "progress", basename: item.basename }), 5000, "progress timeout");
    if (reply?.ok === true && reply.progress && typeof reply.progress === "object") native = reply.progress;
  } catch { /* report the item position only */ }
  return { ok: true, progress: { ...native, index: item.index, count: item.count } };
}

// Selects saved files in Finder. Only names this extension saves are forwarded.
async function reveal(filenames, sendNative, core) {
  const t = core.t;
  if (!Array.isArray(filenames) || filenames.length < 1 || filenames.length > 4 ||
      !filenames.every(core.isSavedFilename)) {
    return { ok: false, error: t("request_rejected") };
  }
  try {
    const reply = await core.withTimeout(
      () => sendNative({ type: "reveal", filenames }), 15000, t("reveal_failed"));
    if (reply?.ok === true) return { ok: true };
    return { ok: false, error: reply?.errorCode === "not_found" ? core.nativeError(reply) : t("reveal_failed") };
  } catch { return { ok: false, error: t("reveal_failed") }; }
}
