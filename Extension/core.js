/* Shared by the isolated content script, background, popup, and Node tests. */
(() => {
  "use strict";
  const GIF_DEFAULTS = Object.freeze({ quality: 95, maximumFrameRate: 20, scale: 1 });
  function validateGIFOptions(value) {
    if (!value || typeof value !== "object" || Array.isArray(value) ||
        Object.keys(value).length !== 3 || ![95, 85, 70].includes(value.quality) ||
        ![30, 25, 20, 15].includes(value.maximumFrameRate) || ![1, 0.75, 0.5].includes(value.scale)) {
      throw new Error("GIF設定が正しくありません。");
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
    if (!isPostId(id)) throw new Error("投稿IDが正しくありません。");
    // Public embed token, derived from the ID; no account credentials are used.
    const token = ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "");
    return `https://cdn.syndication.twimg.com/tweet-result?id=${id}&lang=ja&token=${token}`;
  }
  function resolution(url) {
    const m = new URL(url).pathname.match(/\/(\d+)x(\d+)\//);
    return m ? Number(m[1]) * Number(m[2]) : 0;
  }
  function extractMedia(data, postId) {
    if (!isPostId(postId) || !data || data.id_str !== postId) throw new Error("投稿情報を取得できません。削除・非公開・閲覧制限、またはX側の変更が考えられます。");
    if (!Array.isArray(data.mediaDetails)) throw new Error("この投稿から保存できる動画やGIFアニメが見つかりません。引用した投稿の動画は、引用元を開いて保存してください。");
    const author = /^[A-Za-z0-9_]{1,15}$/.test(data.user?.screen_name ?? "") ? data.user.screen_name : "x";
    const result = [];
    for (const [index, media] of data.mediaDetails.entries()) {
      if (!["video", "animated_gif"].includes(media.type)) continue;
      const variants = (Array.isArray(media.video_info?.variants) ? media.video_info.variants : [])
        .filter(v => v?.content_type === "video/mp4" && isMP4URL(v.url))
        .sort((a, b) => (Number(b.bitrate) || 0) - (Number(a.bitrate) || 0) || resolution(b.url) - resolution(a.url));
      if (!variants.length) throw new Error(`メディア${index + 1}に直接保存できるMP4がありません（ライブ配信・HLSは対象外です）。`);
      result.push({ postId, author, mediaIndex: index + 1, mediaType: media.type, url: variants[0].url });
    }
    if (!result.length) throw new Error("この投稿には動画またはGIFアニメがありません。");
    if (result.length > 4) throw new Error("未対応のメディア構成です。");
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
  async function requestDownload(postId, sendMessage, format = "auto", gifOptions,
    { connectionTimeout = 15000, checkInterval = 15000 } = {}) {
    const options = gifOptions === undefined ? {} : { gifOptions: validateGIFOptions(gifOptions) };
    const connectionError = "拡張機能との接続が切れました。保存結果をダウンロードフォルダで確認し、ページを再読み込みしてください。改善しない場合はSafariを終了して起動し直してください。";
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
        "拡張機能から保存結果が届きません。ダウンロードフォルダを確認し、Safariを終了して起動し直してください。");
    } finally { stopped = true; clearTimeout(timer); }
  }
  async function downloadPost(postId, { fetchImpl = fetch, sendNative, connectionTimeout = 15000, downloadTimeout = 650000, format = "auto", gifOptions }) {
    const saved = [];
    const warnings = [];
    try {
      // Check the native extension before fetching or starting any file writes.
      const connectionError = "保存機能に接続できません。Safariを終了して起動し直し、X Media Assistが有効か確認してください。";
      let ready;
      try { ready = await withTimeout(() => sendNative({ type: "ping" }), connectionTimeout, connectionError); }
      catch { throw new Error(connectionError); }
      if (ready?.ok !== true || ready?.protocolVersion !== 3) throw new Error(connectionError);
      const resolvedGIFOptions = validateGIFOptions(gifOptions === undefined ? (ready.gifOptions ?? GIF_DEFAULTS) : gifOptions);
      let response;
      try {
        response = await fetchImpl(syndicationURL(postId), {
          credentials: "omit", redirect: "error", referrerPolicy: "no-referrer", cache: "no-store", signal: AbortSignal.timeout(20000)
        });
      } catch { throw new Error("投稿情報に接続できません。通信状態とSafariの拡張機能のサイト権限を確認してください。"); }
      if (response.status === 429) throw new Error("Xの取得回数制限に達しました。時間を置いて再試行してください。");
      if (!response.ok) throw new Error(`投稿情報を取得できませんでした（HTTP ${response.status}）。`);
      let data;
      try { data = await response.json(); } catch { throw new Error("Xからの応答を読み取れませんでした。"); }
      const media = extractMedia(data, postId);
      for (const item of media) {
        let reply;
        try { reply = await withTimeout(() => sendNative({ type: "download", ...item, format, gifOptions: resolvedGIFOptions }), downloadTimeout, "native timeout"); }
        catch { throw new Error("保存アプリとの通信が切れました。保存結果をダウンロードフォルダで確認してから再試行してください。"); }
        if (!reply?.ok || typeof reply.filename !== "string") throw new Error(reply?.error || "保存結果を確認できませんでした。");
        saved.push(reply.filename);
        if (typeof reply.warning === "string") warnings.push(`${reply.filename}: ${reply.warning}`);
      }
      return { ok: warnings.length === 0, saved, warnings };
    } catch (error) {
      return { ok: false, saved, warnings, error: error.message || "保存に失敗しました。" };
    }
  }
  function resultMessage(result) {
    if (!result || typeof result.ok !== "boolean") return "保存結果を確認できません。ダウンロードフォルダを確認してから再試行してください。";
    const saved = Array.isArray(result?.saved) ? result.saved : [];
    const warning = Array.isArray(result.warnings) ? result.warnings.join("\n") : "";
    if (result?.ok) return `${saved.length}件をダウンロードフォルダへ保存しました。\n${saved.join("\n")}`;
    return `${saved.length ? `${saved.length}件は保存済みです。\n${saved.join("\n")}\n` : ""}${[warning, result?.error].filter(Boolean).join("\n") || "保存に失敗しました。"}`;
  }
  globalThis.XMediaCore = Object.freeze({ GIF_DEFAULTS, validateGIFOptions, isPostId, parsePostURL, isXPage, isMP4URL, syndicationURL, extractMedia, withTimeout, requestDownload, downloadPost, resultMessage });
})();
