import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFile } from "node:fs/promises";
import { createI18n } from "./i18n-fixture.mjs";
import "../Extension/i18n.js";
import "../Extension/core.js";
globalThis.browser = { i18n: createI18n("ja") };
const c = globalThis.XMediaCore;
const id = "719944021058060289";
const url = "https://video.twimg.com/ext_tw_video/123/pu/vid/1280x720/sample.mp4";
const variant = (bitrate, address = url) => ({ content_type: "video/mp4", bitrate, url: address });
const media = (type = "video", variants = [variant(1000)]) => ({ type, video_info: { variants } });
const post = (items = [media()]) => ({ id_str: id, user: { screen_name: "example" }, mediaDetails: items });
const connected = download => request => request.type === "ping" ? Promise.resolve({ ok: true, protocolVersion: 3 }) : download(request);
const fetchPost = data => async () => ({ ok: true, status: 200, json: async () => data });

test("post IDs remain strings, including values beyond JS safe integers", () => {
  for (const host of ["x.com", "twitter.com", "www.x.com"]) {
    assert.equal(c.parsePostURL(`https://${host}/example/status/${id}?s=20`), id);
    assert.equal(c.parsePostURL(`https://${host}/i/web/status/${id}/video/2`), id);
  }
});
test("rejects unrelated URLs, credentials, bad IDs and paths", () => {
  for (const value of [
    "1", `http://x.com/a/status/${id}`, `https://x.com.evil/a/status/${id}`, `https://x.com@evil/a/status/${id}`,
    "https://x.com/a/status/1e10", "https://x.com/a/status/001", `https://x.com/a/status/${id}/foo`,
    `https://user@x.com/a/status/${id}`
  ]) assert.equal(c.parsePostURL(value), null, value);
});
test("media URL boundary rejects local, credentials, HLS, and lookalike hosts", () => {
  for (const value of [
    "file:///tmp/a.mp4", "http://video.twimg.com/a.mp4", "https://video.twimg.com.evil/a.mp4",
    "https://user@video.twimg.com/a.mp4", "https://video.twimg.com/a.m3u8", "https://127.0.0.1/a.mp4",
    "https://video.twimg.com:8443/a.mp4"
  ]) assert.equal(c.isMP4URL(value), false, value);
  assert.equal(c.isMP4URL(url + "?tag=12"), true);
});
test("syndication token matches public embed algorithm", () => {
  const u = new URL(c.syndicationURL(id));
  assert.equal(u.searchParams.get("id"), id);
  assert.equal(u.searchParams.get("token"), ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, ""));
  assert.throws(() => c.syndicationURL("../../etc"));
});
test("selects highest bitrate MP4, ignoring HLS and hostile URLs", () => {
  const best = url + "?best";
  const result = c.extractMedia(post([media("video", [
    variant(256, url + "?low"),
    { content_type: "application/x-mpegURL", url: "https://video.twimg.com/a.m3u8", bitrate: 99999 },
    variant(99999, "https://evil.test/a.mp4"),
    variant(4000, best)
  ])]), id);
  assert.equal(result[0].url, best);
});
test("uses resolution to rank variants without bitrate", () => {
  assert.equal(c.extractMedia(post([media("video", [variant(undefined, url.replace("1280x720", "320x180")), variant(undefined)])]), id)[0].url, url);
});
test("GIF classification is preserved for native conversion; indexes preserve photo positions", () => {
  const result = c.extractMedia(post([{ type: "photo" }, media("animated_gif"), media()]), id);
  assert.equal(result.length, 2);
  assert.equal(result[0].mediaType, "animated_gif");
  assert.equal(result[0].mediaIndex, 2);
  assert.equal(result[1].mediaIndex, 3);
});
test("does not download media from a quote or another post", () => {
  assert.throws(() => c.extractMedia({ ...post([]), quoted_tweet: post() }, id));
  assert.throws(() => c.extractMedia({ ...post(), id_str: "123" }, id));
  assert.throws(() => c.extractMedia({}, id));
  assert.throws(() => c.extractMedia(post([media("video", [])]), id));
});
test("author is sanitized without accepting paths", () => {
  assert.equal(c.extractMedia({ ...post(), user: { screen_name: "../escape" } }, id)[0].author, "x");
});
test("download succeeds sequentially with credential-free fetch", async () => {
  const calls = [];
  const result = await c.downloadPost(id, {
    fetchImpl: async (_url, options) => {
      assert.equal(options.credentials, "omit"); assert.equal(options.redirect, "error");
      return { ok: true, json: async () => post([media(), media("animated_gif")]) };
    },
    sendNative: connected(async request => { calls.push(request); return { ok: true, filename: `file-${request.mediaIndex}.mp4` }; })
  });
  assert.equal(result.ok, true); assert.deepEqual(result.saved, ["file-1.mp4", "file-2.mp4"]);
  assert.equal(calls[1].mediaType, "animated_gif");
});
test("partial failure reports saved files and stops remaining downloads", async () => {
  let count = 0;
  const result = await c.downloadPost(id, {
    fetchImpl: fetchPost(post([media(), media(), media()])),
    sendNative: connected(async () => ++count === 1 ? { ok: true, filename: "saved.mp4" } : { ok: false, error: "disk full" })
  });
  assert.equal(count, 2); assert.equal(result.ok, false); assert.deepEqual(result.saved, ["saved.mp4"]);
  assert.match(c.resultMessage(result), /saved.mp4/);
});
test("network, rate limit, invalid JSON and native disconnect are visible failures", async () => {
  for (const fetchImpl of [
    async () => { throw Error("offline"); },
    async () => ({ ok: false, status: 429 }),
    async () => ({ ok: false, status: 403 }),
    async () => ({ ok: true, json: async () => { throw Error("bad json"); } })
  ]) {
    const result = await c.downloadPost(id, { fetchImpl, sendNative: connected(() => assert.fail("must not download")) });
    assert.equal(result.ok, false); assert.ok(result.error);
  }
  const result = await c.downloadPost(id, { fetchImpl: fetchPost(post()), sendNative: connected(async () => { throw Error("disconnected"); }) });
  assert.equal(result.ok, false); assert.match(result.error, /保存結果/);
});
test("a lost response does not incorrectly assert that nothing was saved", () => {
  assert.match(c.resultMessage(undefined), /保存結果を確認できません/);
  assert.match(c.resultMessage(null), /ダウンロードフォルダ/);
});
test("native connection failure or stale protocol stops before fetching or saving", async () => {
  for (const sendNative of [
    () => new Promise(() => {}),
    async () => { throw Error("XPC invalidated"); },
    async () => undefined,
    async () => ({ ok: true }),
    async () => ({ ok: true, protocolVersion: 1 }),
    async () => ({ ok: true, protocolVersion: 2 })
  ]) {
    const result = await c.downloadPost(id, {
      sendNative, connectionTimeout: 5,
      fetchImpl: () => assert.fail("must not fetch before connection succeeds")
    });
    assert.equal(result.ok, false);
    assert.deepEqual(result.saved, []);
    assert.match(result.error, /Safariを終了/);
  }
});
test("lost native download response times out, preserves partial success, and never retries", async () => {
  let count = 0;
  const result = await c.downloadPost(id, {
    fetchImpl: fetchPost(post([media(), media(), media()])), downloadTimeout: 5,
    sendNative: connected(() => ++count === 1 ? Promise.resolve({ ok: true, filename: "saved.mp4" }) : new Promise(() => {}))
  });
  assert.equal(count, 2);
  assert.deepEqual(result.saved, ["saved.mp4"]);
  assert.equal(result.ok, false);
  assert.match(result.error, /ダウンロードフォルダ/);
});
test("message watchdog rejects a missing response and accepts a normal response", async () => {
  await assert.rejects(c.withTimeout(() => new Promise(() => {}), 5, "no response"), /no response/);
  assert.equal(await c.withTimeout(() => Promise.resolve("done"), 100, "no response"), "done");
  await assert.rejects(c.withTimeout(() => { throw Error("disconnected"); }, 100, "no response"), /disconnected/);
  const result = await c.requestDownload(id, async message => {
    if (message.type === "checkConnection") return { ok: true, instance: "background" };
    assert.deepEqual(message, { type: "downloadPost", postId: id, format: "auto" });
    return { ok: true, saved: ["saved.mp4"] };
  });
  assert.equal(result.ok, true);
});
test("background releases its in-flight lock after a native connection timeout", async () => {
  let listener, calls = 0;
  const context = vm.createContext({
    XMediaCore: { ...c, downloadPost: (postId, options) => c.downloadPost(postId, { ...options, connectionTimeout: 5 }) },
    browser: { runtime: { id: "self", getURL: path => `safari-web-extension://id/${path}`,
      // A finished save also sends one "notify", which this test does not count.
      sendNativeMessage: (_, message) => { if (message.type !== "notify") calls++; return new Promise(() => {}); },
      onMessage: { addListener: fn => { listener = fn; } } } }
  });
  vm.runInContext(await readFile(new URL("../Extension/background.js", import.meta.url), "utf8"), context);
  const message = { type: "downloadPost", postId: id };
  const sender = { id: "self", url: "https://x.com/home", tab: {} };
  assert.match((await listener(message, sender)).error, /Safariを終了/);
  assert.match((await listener(message, sender)).error, /Safariを終了/);
  assert.equal(calls, 2);
});
test("background verifies sender and suppresses duplicate in-flight requests", async () => {
  let listener, resolve;
  const context = vm.createContext({
    XMediaCore: { ...c, downloadPost: () => new Promise(done => { resolve = done; }) },
    browser: { runtime: { id: "self", getURL: path => `safari-web-extension://id/${path}`, onMessage: { addListener: fn => { listener = fn; } } } }
  });
  vm.runInContext(await readFile(new URL("../Extension/background.js", import.meta.url), "utf8"), context);
  const message = { type: "downloadPost", postId: id };
  assert.equal((await listener(message, { id: "evil", url: "https://x.com/home", tab: {} })).ok, false);
  assert.equal((await listener(message, { id: "self", url: "https://evil.test", tab: {} })).ok, false);
  const sender = { id: "self", url: "https://x.com/home", tab: {} };
  const connection = await listener({ type: "checkConnection" }, sender);
  assert.equal(connection.ok, true);
  assert.equal(typeof connection.instance, "string");
  assert.equal((await listener({ type: "checkConnection" }, { ...sender, id: "evil" })).ok, false);
  const pending = listener(message, sender);
  assert.equal((await listener(message, sender)).ok, false);
  resolve({ ok: true }); await pending;
  const retry = listener(message, sender); resolve({ ok: true }); assert.equal((await retry).ok, true);
});

test("GIF fallback warnings retain MP4 names and allow remaining media", async () => {
  let count = 0;
  const result = await c.downloadPost(id, {
    fetchImpl: fetchPost(post([media("animated_gif"), media()])),
    sendNative: connected(async request => {
      assert.equal(request.format, "auto");
      return ++count === 1 ? { ok: true, filename: "fallback.mp4", warning: "GIF変換に失敗したためMP4を保存しました。" } : { ok: true, filename: "video.mp4" };
    })
  });
  assert.equal(result.ok, false);
  assert.deepEqual(result.saved, ["fallback.mp4", "video.mp4"]);
  assert.match(c.resultMessage(result), /GIF変換に失敗/);
  assert.match(c.resultMessage(result), /fallback.mp4/);
});
test("MP4 override is passed explicitly without altering GIF classification", async () => {
  const result = await c.downloadPost(id, {
    format: "mp4", fetchImpl: fetchPost(post([media("animated_gif")])),
    sendNative: connected(async request => {
      assert.equal(request.format, "mp4"); assert.equal(request.mediaType, "animated_gif");
      return { ok: true, filename: "source.mp4" };
    })
  });
  assert.equal(result.ok, true);
});

test("GIF defaults, base preferences and download overrides reach native without persistence", async () => {
  const base = { quality: 85, maximumFrameRate: 25, scale: 0.75 };
  const override = { quality: 70, maximumFrameRate: 15, scale: 0.5 };
  for (const [stored, supplied, expected] of [[undefined, undefined, c.GIF_DEFAULTS], [base, undefined, base], [base, override, override]]) {
    const sent = [];
    const result = await c.downloadPost(id, {
      gifOptions: supplied, fetchImpl: fetchPost(post([media("animated_gif")])),
      sendNative: async request => {
        sent.push(request);
        if (request.type === "ping") return { ok: true, protocolVersion: 3, gifOptions: stored };
        assert.deepEqual(request.gifOptions, expected);
        return { ok: true, filename: "saved.gif" };
      }
    });
    assert.equal(result.ok, true);
    assert.deepEqual(sent.map(request => request.type), ["ping", "download"]);
  }
  assert.deepEqual(base, { quality: 85, maximumFrameRate: 25, scale: 0.75 });
  await c.requestDownload(id, async message => {
    if (message.type === "checkConnection") return { ok: true, instance: "background" };
    assert.deepEqual(message.gifOptions, override);
    return { ok: true, saved: [] };
  }, "auto", override);
});

test("background connection watchdog detects missing and restarted backgrounds without retrying downloads", async () => {
  let downloads = 0;
  await assert.rejects(c.requestDownload(id, message => {
    if (message.type === "downloadPost") downloads++;
    return new Promise(() => {});
  }, "auto", undefined, { connectionTimeout: 5, checkInterval: 5 }), /接続が切れ/);
  assert.equal(downloads, 0);
  for (const restarted of [false, true]) {
    let checks = 0;
    downloads = 0;
    await assert.rejects(c.requestDownload(id, message => {
      if (message.type === "checkConnection") {
        if (++checks === 1) return Promise.resolve({ ok: true, instance: "first" });
        return restarted ? Promise.resolve({ ok: true, instance: "second" }) : new Promise(() => {});
      }
      downloads++;
      return new Promise(() => {});
    }, "auto", undefined, { connectionTimeout: 5, checkInterval: 5 }), /ダウンロードフォルダ/);
    assert.equal(downloads, 1);
  }
  let finish, checks = 0;
  const result = await c.requestDownload(id, message => {
    if (message.type === "checkConnection") {
      if (++checks === 2) finish({ ok: true, saved: ["saved.gif"] });
      return Promise.resolve({ ok: true, instance: "stable" });
    }
    return new Promise(resolve => { finish = resolve; });
  }, "auto", undefined, { connectionTimeout: 10, checkInterval: 5 });
  assert.equal(result.ok, true);
  assert.equal(checks, 2);
});

test("GIF validation rejects unsupported types and values before a download", async () => {
  assert.equal(c.GIF_DEFAULTS.quality, 95);
  for (const quality of [95, 85, 70]) {
    assert.equal(c.validateGIFOptions({ ...c.GIF_DEFAULTS, quality }).quality, quality);
  }
  for (const quality of [90, 75, 50]) {
    assert.throws(() => c.validateGIFOptions({ ...c.GIF_DEFAULTS, quality }));
  }
  for (const raw of [
    null, [], {}, { ...c.GIF_DEFAULTS, quality: 91 }, { ...c.GIF_DEFAULTS, maximumFrameRate: 50 },
    { ...c.GIF_DEFAULTS, scale: true }, { ...c.GIF_DEFAULTS, scale: "1" }
  ]) {
    assert.throws(() => c.validateGIFOptions(raw));
    const result = await c.downloadPost(id, {
      gifOptions: raw, sendNative: connected(() => assert.fail("must not download")),
      fetchImpl: () => assert.fail("must not fetch")
    });
    assert.equal(result.ok, false);
    assert.match(result.error, /GIF設定/);
  }
});

test("background exposes GIF defaults only to popup and forwards download overrides", async () => {
  let listener, received;
  const nativeCalls = [];
  const base = { quality: 85, maximumFrameRate: 25, scale: 0.75 };
  const context = vm.createContext({
    XMediaCore: { ...c, downloadPost: async (_, options) => { received = options; return { ok: true }; } },
    browser: { runtime: { id: "self", getURL: path => `safari-web-extension://id/${path}`,
      sendNativeMessage: async (_, message) => { nativeCalls.push(message.type); return { ok: true, protocolVersion: 3, gifOptions: base }; },
      onMessage: { addListener: fn => { listener = fn; } } } }
  });
  vm.runInContext(await readFile(new URL("../Extension/background.js", import.meta.url), "utf8"), context);
  const popup = { id: "self", url: "safari-web-extension://id/popup.html" };
  assert.deepEqual((await listener({ type: "getGIFOptions" }, popup)).gifOptions, base);
  assert.equal((await listener({ type: "getGIFOptions" }, { id: "self", url: "https://x.com/home", tab: {} })).ok, false);
  assert.equal((await listener({ type: "setGIFOptions", gifOptions: base }, popup)).ok, false);
  await listener({ type: "downloadPost", postId: id, gifOptions: base }, popup);
  assert.deepEqual(received.gifOptions, base);
  // getGIFOptions pings; the finished download sends its notification.
  assert.deepEqual(nativeCalls, ["ping", "notify"]);
});

test("saved file names match only what the native side publishes", () => {
  for (const name of ["example-123-1.mp4", "a_b-719944021058060289-4.gif", "example-123-2 2.mp4", "example-123-1 1000.gif"]) {
    assert.equal(c.isSavedFilename(name), true, name);
  }
  for (const name of ["other.mp4", "../example-123-1.mp4", "example-123-1.mov", "example-123-5.mp4", "example-123-1 0.mp4",
    "example-0123-1.mp4", "/tmp/example-123-1.mp4", "example-123-1.mp4/", 1, null]) {
    assert.equal(c.isSavedFilename(name), false, String(name));
  }
});

test("progress text covers fetching, transfer, conversion and malformed values", () => {
  assert.equal(c.progressMessage(null), "投稿情報を取得中…");
  assert.equal(c.progressMessage({ index: 0, count: 0 }), "投稿情報を取得中…");
  assert.equal(c.progressMessage({ index: 1, count: 1 }), "準備中…");
  assert.equal(c.progressMessage({ index: 1, count: 1, phase: "downloading", receivedBytes: 12_345_678, expectedBytes: 40_000_000 }),
    "ダウンロード中 12.3 / 40.0 MB（30%）");
  assert.equal(c.progressMessage({ index: 2, count: 3, phase: "downloading", receivedBytes: 1_500_000, expectedBytes: -1 }),
    "(2/3) ダウンロード中 1.5 MB");
  assert.equal(c.progressMessage({ index: 1, count: 2, phase: "converting", encodedFrames: 45, totalFrames: 100 }),
    "(1/2) GIFに変換中（45%）");
  assert.equal(c.progressMessage({ index: 1, count: 1, phase: "converting", encodedFrames: 0, totalFrames: 0 }), "GIFに変換中…");
  // Never more than 100%, and never numbers from malformed fields.
  assert.equal(c.progressMessage({ index: 1, count: 1, phase: "downloading", receivedBytes: 50, expectedBytes: 40 }),
    "ダウンロード中 0.0 / 0.0 MB（100%）");
  assert.equal(c.progressMessage({ index: 1, count: 1, phase: "downloading", receivedBytes: "5" }), "ダウンロード中…");
  assert.equal(c.progressMessage({ index: 1, count: 1, phase: "converting", encodedFrames: NaN, totalFrames: 10 }), "GIFに変換中…");
  assert.equal(c.progressMessage({ index: 5, count: 2, phase: "other" }), "準備中…");
  assert.equal(c.progressMessage({ index: -1, count: 2 }), "投稿情報を取得中…");
});

test("download reports each item's position and native progress key", async () => {
  const items = [];
  const result = await c.downloadPost(id, {
    fetchImpl: fetchPost(post([{ type: "photo" }, media("animated_gif"), media()])),
    sendNative: connected(async request => ({ ok: true, filename: `example-${id}-${request.mediaIndex}.mp4` })),
    onItem: item => items.push(item)
  });
  assert.equal(result.ok, true);
  assert.deepEqual(items, [
    { index: 1, count: 2, basename: `example-${id}-2` },
    { index: 2, count: 2, basename: `example-${id}-3` }
  ]);
});

test("progress polling reports replies, skips failures and stops with the save", async () => {
  const seen = [];
  let finish, polls = 0;
  const saving = c.requestDownload(id, message => {
    if (message.type === "checkConnection") return Promise.resolve({ ok: true, instance: "stable" });
    if (message.type === "getProgress") {
      assert.equal(message.postId, id);
      if (++polls === 2) return Promise.reject(new Error("lost"));
      if (polls === 3) finish({ ok: true, saved: [] });
      return Promise.resolve({ ok: true, progress: { index: 1, count: 1, polls } });
    }
    return new Promise(resolve => { finish = resolve; });
  }, "auto", undefined, { onProgress: progress => seen.push(progress), progressInterval: 2 });
  assert.equal((await saving).ok, true);
  const after = polls;
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(polls, after, "no polling after the save finished");
  // The failed second poll is skipped; the third reply arrived before the result.
  assert.deepEqual(seen.map(progress => progress.polls), [1, 3]);
});

// Objects from the background's vm context have another realm's prototypes.
const plain = value => JSON.parse(JSON.stringify(value));
function background(sendNativeMessage, downloadPost = c.downloadPost) {
  let listener;
  const context = vm.createContext({
    XMediaCore: { ...c, downloadPost },
    browser: { runtime: { id: "self", getURL: path => `safari-web-extension://id/${path}`, sendNativeMessage,
      onMessage: { addListener: fn => { listener = fn; } } } }
  });
  return readFile(new URL("../Extension/background.js", import.meta.url), "utf8").then(source => {
    vm.runInContext(source, context);
    return listener;
  });
}

test("background progress combines the current item with native transfer state", async () => {
  let item, finish;
  const native = [];
  let nativeReply = { ok: true, progress: { phase: "downloading", receivedBytes: 10, expectedBytes: 20 } };
  const listener = await background(async (_, message) => { native.push(message); return nativeReply; },
    (_, { onItem }) => { item = onItem; return new Promise(resolve => { finish = resolve; }); });
  const page = { id: "self", url: "https://x.com/home", tab: {} };
  const ask = async (sender = page) => plain(await listener({ type: "getProgress", postId: id }, sender));
  assert.deepEqual(await ask(), { ok: true, progress: null });
  const saving = listener({ type: "downloadPost", postId: id }, page);
  assert.deepEqual((await ask()).progress, { index: 0, count: 0 });
  item({ index: 2, count: 3, basename: `example-${id}-2` });
  assert.deepEqual((await ask()).progress,
    { phase: "downloading", receivedBytes: 10, expectedBytes: 20, index: 2, count: 3 });
  assert.deepEqual(plain(native.at(-1)), { type: "progress", basename: `example-${id}-2` });
  // An older native side or a failed query still reports the item position.
  nativeReply = { ok: false, errorCode: "invalid_request" };
  assert.deepEqual((await ask()).progress, { index: 2, count: 3 });
  assert.equal((await ask({ ...page, id: "evil" })).ok, false);
  assert.equal((await listener({ type: "getProgress", postId: "../1" }, page)).ok, false);
  finish({ ok: true, saved: [] }); await saving;
  assert.deepEqual(await ask(), { ok: true, progress: null });
});

test("background reveals only saved file names and explains failures", async () => {
  const native = [];
  let nativeReply = { ok: true };
  const listener = await background(async (_, message) => {
    native.push(message);
    if (nativeReply instanceof Error) throw nativeReply;
    return nativeReply;
  });
  const popup = { id: "self", url: "safari-web-extension://id/popup.html" };
  const reveal = async filenames => plain(await listener({ type: "revealFiles", filenames }, popup));
  for (const filenames of [undefined, [], ["../secret.mp4"], ["a-1-1.mp4", "other.txt"], Array(5).fill("a-1-1.mp4")]) {
    assert.equal((await reveal(filenames)).ok, false);
  }
  assert.equal(native.length, 0);
  assert.equal((await listener({ type: "revealFiles", filenames: ["a-1-1.mp4"] }, { id: "evil", url: popup.url })).ok, false);
  assert.deepEqual(await reveal(["a-1-1.mp4", "a-1-2 2.gif"]), { ok: true });
  assert.deepEqual(plain(native), [{ type: "reveal", filenames: ["a-1-1.mp4", "a-1-2 2.gif"] }]);
  nativeReply = { ok: false, errorCode: "not_found" };
  assert.match((await reveal(["a-1-1.mp4"])).error, /見つかりません/);
  nativeReply = { ok: false, errorCode: "invalid_request" };
  assert.equal((await reveal(["a-1-1.mp4"])).error, "Finderで表示できませんでした。");
  nativeReply = new Error("disconnected");
  assert.equal((await reveal(["a-1-1.mp4"])).error, "Finderで表示できませんでした。");
});

test("every extension script parses, including those no other test executes", async () => {
  for (const name of ["i18n", "core", "background", "content", "popup"]) {
    const source = await readFile(new URL(`../Extension/${name}.js`, import.meta.url), "utf8");
    assert.doesNotThrow(() => new vm.Script(source, { filename: `${name}.js` }), name);
  }
});

test("notification text distinguishes saved, partially saved and failed posts", () => {
  assert.deepEqual(plain(c.notificationContent({ ok: true, saved: ["a-1-1.mp4", "a-1-2.gif"], warnings: [] })),
    { title: "保存しました", body: "a-1-1.mp4\na-1-2.gif", filenames: ["a-1-1.mp4", "a-1-2.gif"], revealTitle: "Finderで表示" });
  // Only names this extension saves are offered to the Finder button.
  assert.deepEqual(plain(c.notificationContent({ ok: true, saved: ["../other.mp4"] })).filenames, undefined);
  // A GIF that fell back to MP4 is saved; the body explains why.
  const fallback = c.notificationContent({ ok: false, saved: ["a-1-1.mp4"], warnings: ["a-1-1.mp4: GIF変換に失敗"] });
  assert.equal(fallback.title, "保存しました");
  assert.match(fallback.body, /GIF変換に失敗/);
  const partial = c.notificationContent({ ok: false, saved: ["a-1-1.mp4"], warnings: [], error: "通信が切れました" });
  assert.equal(partial.title, "一部のみ保存しました");
  assert.deepEqual(plain(partial.filenames), ["a-1-1.mp4"]);
  assert.match(partial.body, /a-1-1\.mp4[\s\S]*通信が切れました/);
  const failed = c.notificationContent({ ok: false, saved: [], error: "失敗" });
  assert.equal(failed.title, "保存できませんでした");
  assert.equal(failed.revealTitle, undefined, "nothing to show in Finder");
  assert.equal(c.notificationContent(undefined).title, "保存できませんでした");
  assert.equal(c.notificationContent({ ok: false, saved: [], error: "x".repeat(3000) }).body.length, 2000);
});

test("background notifies once per finished post without delaying or failing the result", async () => {
  const native = [];
  let nativeFails = false;
  const listener = await background(async (_, message) => {
    native.push(message);
    if (message.type === "notify" && nativeFails) throw new Error("old native side");
    return { ok: true };
  }, async () => ({ ok: true, saved: ["example-1-1.mp4"], warnings: [] }));
  const page = { id: "self", url: "https://x.com/home", tab: {} };
  assert.equal((await listener({ type: "downloadPost", postId: id }, page)).ok, true);
  assert.deepEqual(plain(native), [{ type: "notify", title: "保存しました", body: "example-1-1.mp4",
    filenames: ["example-1-1.mp4"], revealTitle: "Finderで表示" }]);
  nativeFails = true;
  assert.equal((await listener({ type: "downloadPost", postId: id }, page)).ok, true);
  assert.equal(native.length, 2);
});
