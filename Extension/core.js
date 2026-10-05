/* Shared by the isolated content script, background, popup, and Node tests. */
(() => {
  "use strict";
  const t = (...args) => globalThis.XMediaI18n.text(...args);
  const NATIVE_ERRORS = Object.freeze({
    invalid_request: "native_invalid_request", invalid_response: "native_invalid_response",
    too_large: "native_too_large", invalid_mp4: "native_invalid_mp4", busy: "save_busy",
    write_failed: "native_write_failed", network: "native_network"
  });
  const GIF_WARNINGS = new Set(["gif_unsupported", "gif_limit", "gif_encoding", "gif_timeout", "gif_busy", "gif_failed"]);
  function nativeError(reply) {
    if (Object.hasOwn(NATIVE_ERRORS, reply?.errorCode)) return t(NATIVE_ERRORS[reply.errorCode]);
    if (reply?.errorCode === "http" && Number.isInteger(reply.httpStatus) && reply.httpStatus >= 100 && reply.httpStatus <= 599) {
      return t("native_http", [reply.httpStatus]);
    }
    return typeof reply?.error === "string" && reply.error ? reply.error : t("result_missing");
  }
  // Must match protocolVersion in SafariWebExtensionHandler.swift.
  const NATIVE_PROTOCOL = 3;
  const NATIVE_APP = "com.jemielttf.XMediaAssist";
  const GIF_DEFAULTS = Object.freeze({ quality: 95, maximumFrameRate: 20, scale: 1 });
  function validateGIFOptions(value) {
    if (!value || typeof value !== "object" || Array.isArray(value) ||
        Object.keys(value).length !== 3 || ![95, 85, 70].includes(value.quality) ||
        ![30, 25, 20, 15].includes(value.maximumFrameRate) || ![1, 0.75, 0.5].includes(value.scale)) {
      throw new Error(t("invalid_gif_options"));
    }
    return { quality: value.quality, maximumFrameRate: value.maximumFrameRate, scale: value.scale };
  }
  const POST_ID = /^[1-9][0-9]{0,19}$/;
  const HOSTS = new Set(["x.com", "www.x.com", "twitter.com", "www.twitter.com"]);
  function isPostId(value) { return typeof value === "string" && POST_ID.test(value); }
  function parsePostURL(value) {
    try {
      const url = new URL(value);
      if (url.protocol !== "https:" || !HOSTS.has(url.hostname) || url.username || url.password || url.port) return null;
      const match = url.pathname.match(/^\/(?:[A-Za-z0-9_]{1,15}|i\/web)\/status\/([1-9][0-9]{0,19})(?:\/(?:video|photo)\/[1-4])?\/?$/);
      return match?.[1] ?? null;
    } catch { return null; }
  }
  function isXPage(value) {
    try { const u = new URL(value); return u.protocol === "https:" && HOSTS.has(u.hostname) && !u.port && !u.username && !u.password; }
    catch { return false; }
  }
  function isMP4URL(value) {
    try {
      const u = new URL(value);
      return u.protocol === "https:" && u.hostname === "video.twimg.com" && !u.port && !u.username && !u.password && !u.hash && u.pathname.endsWith(".mp4");
    } catch { return false; }
  }
  function syndicationURL(id) {
    if (!isPostId(id)) throw new Error(t("invalid_post_id"));
    // Public embed token, derived from the ID; no account credentials are used.
    const token = ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "");
    return `https://cdn.syndication.twimg.com/tweet-result?id=${id}&lang=ja&token=${token}`;
  }
  function resolution(url) {
    const m = new URL(url).pathname.match(/\/(\d+)x(\d+)\//);
    return m ? Number(m[1]) * Number(m[2]) : 0;
  }
  function extractMedia(data, postId) {
    if (!isPostId(postId) || !data || data.id_str !== postId) throw new Error(t("post_unavailable"));
    if (!Array.isArray(data.mediaDetails)) throw new Error(t("no_downloadable_media"));
    const author = /^[A-Za-z0-9_]{1,15}$/.test(data.user?.screen_name ?? "") ? data.user.screen_name : "x";
    const result = [];
    for (const [index, media] of data.mediaDetails.entries()) {
      if (!["video", "animated_gif"].includes(media.type)) continue;
      const variants = (Array.isArray(media.video_info?.variants) ? media.video_info.variants : [])
        .filter(v => v?.content_type === "video/mp4" && isMP4URL(v.url))
        .sort((a, b) => (Number(b.bitrate) || 0) - (Number(a.bitrate) || 0) || resolution(b.url) - resolution(a.url));
      if (!variants.length) throw new Error(t("no_mp4_variant", [index + 1]));
      result.push({ postId, author, mediaIndex: index + 1, mediaType: media.type, url: variants[0].url });
    }
    if (!result.length) throw new Error(t("no_video"));
    if (result.length > 4) throw new Error(t("unsupported_media"));
    return result;
  }
  // A rejected/timed-out message does not cancel native work. Never retry automatically.
  async function withTimeout(operation, milliseconds, message) {
    let timer;
    try {
      return await Promise.race([
        Promise.resolve().then(operation),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), milliseconds); })
      ]);
    } finally { clearTimeout(timer); }
  }
  // Returns the native base GIF options (unvalidated). Any failure throws `message`.
  async function pingNative(sendNative, timeout, message) {
    let reply;
    try { reply = await withTimeout(() => sendNative({ type: "ping" }), timeout, message); }
    catch { throw new Error(message); }
    if (reply?.ok !== true || reply.protocolVersion !== NATIVE_PROTOCOL) throw new Error(message);
    return reply.gifOptions ?? GIF_DEFAULTS;
  }
  async function requestDownload(postId, sendMessage, format = "auto", gifOptions,
    { connectionTimeout = 15000, checkInterval = 15000 } = {}) {
    const options = gifOptions === undefined ? {} : { gifOptions: validateGIFOptions(gifOptions) };
    const connectionError = t("extension_disconnected");
    async function checkConnection() {
      const reply = await withTimeout(() => sendMessage({ type: "checkConnection" }), connectionTimeout, connectionError);
      if (reply?.ok !== true || typeof reply.instance !== "string") throw new Error(connectionError);
      return reply.instance;
    }
    const instance = await checkConnection();
    let timer, stopped = false;
    const disconnected = new Promise((_, reject) => {
      async function check() {
        try {
          if (await checkConnection() !== instance) throw new Error(connectionError);
          if (!stopped) timer = setTimeout(check, checkInterval);
        } catch { if (!stopped) reject(new Error(connectionError)); }
      }
      timer = setTimeout(check, checkInterval);
    });
    try {
      // Keep the transfer budget, but detect a lost/restarted background separately.
      // Checks never start another download or cancel native work.
      return await withTimeout(() => Promise.race([disconnected,
        Promise.resolve().then(() => sendMessage({ type: "downloadPost", postId, format, ...options }))]), 45 * 60 * 1000,
        t("extension_result_timeout"));
    } finally { stopped = true; clearTimeout(timer); }
  }
  async function downloadPost(postId, { fetchImpl = fetch, sendNative, connectionTimeout = 15000, downloadTimeout = 650000, format = "auto", gifOptions }) {
    const saved = [];
    const warnings = [];
    try {
      // Check the native extension before fetching or starting any file writes.
      const baseGIFOptions = await pingNative(sendNative, connectionTimeout, t("native_unavailable"));
      const resolvedGIFOptions = validateGIFOptions(gifOptions === undefined ? baseGIFOptions : gifOptions);
      let response;
      try {
        response = await fetchImpl(syndicationURL(postId), {
          credentials: "omit", redirect: "error", referrerPolicy: "no-referrer", cache: "no-store", signal: AbortSignal.timeout(20000)
        });
      } catch { throw new Error(t("post_network_failed")); }
      if (response.status === 429) throw new Error(t("rate_limited"));
      if (!response.ok) throw new Error(t("post_http_failed", [response.status]));
      let data;
      try { data = await response.json(); } catch { throw new Error(t("post_response_invalid")); }
      const media = extractMedia(data, postId);
      for (const item of media) {
        let reply;
        try { reply = await withTimeout(() => sendNative({ type: "download", ...item, format, gifOptions: resolvedGIFOptions }), downloadTimeout, "native timeout"); }
        catch { throw new Error(t("native_disconnected")); }
        if (!reply?.ok || typeof reply.filename !== "string") throw new Error(nativeError(reply));
        saved.push(reply.filename);
        if (typeof reply.warning === "string") {
          const warning = GIF_WARNINGS.has(reply.warningCode) ? t(reply.warningCode) : reply.warning;
          warnings.push(`${reply.filename}: ${warning}`);
        }
      }
      return { ok: warnings.length === 0, saved, warnings };
    } catch (error) {
      return { ok: false, saved, warnings, error: error.message || t("save_failed") };
    }
  }
  function resultMessage(result) {
    if (!result || typeof result.ok !== "boolean") return t("result_unknown");
    const saved = Array.isArray(result.saved) ? result.saved : [];
    const warning = Array.isArray(result.warnings) ? result.warnings.join("\n") : "";
    if (result.ok) return `${t(saved.length === 1 ? "saved_one" : "saved_many", [saved.length])}\n${saved.join("\n")}`;
    return `${saved.length ? `${t(saved.length === 1 ? "saved_partial_one" : "saved_partial_many", [saved.length])}\n${saved.join("\n")}\n` : ""}${[warning, result.error].filter(Boolean).join("\n") || t("save_failed")}`;
  }
  globalThis.XMediaCore = Object.freeze({ t, NATIVE_APP, GIF_DEFAULTS, validateGIFOptions, isPostId, parsePostURL, isXPage, isMP4URL, syndicationURL, extractMedia, withTimeout, pingNative, requestDownload, downloadPost, resultMessage });
})();
