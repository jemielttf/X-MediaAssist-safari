import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFile } from "node:fs/promises";
import "../Extension/core.js";
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
  for (const value of ["1", `http://x.com/a/status/${id}`, `https://x.com.evil/a/status/${id}`, `https://x.com@evil/a/status/${id}`, "https://x.com/a/status/1e10", "https://x.com/a/status/001", `https://x.com/a/status/${id}/foo`, `https://user@x.com/a/status/${id}`]) assert.equal(c.parsePostURL(value), null, value);
});
test("media URL boundary rejects local, credentials, HLS, and lookalike hosts", () => {
  for (const value of ["file:///tmp/a.mp4", "http://video.twimg.com/a.mp4", "https://video.twimg.com.evil/a.mp4", "https://user@video.twimg.com/a.mp4", "https://video.twimg.com/a.m3u8", "https://127.0.0.1/a.mp4", "https://video.twimg.com:8443/a.mp4"]) assert.equal(c.isMP4URL(value), false, value);
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
  const result = c.extractMedia(post([media("video", [variant(256, url + "?low"), { content_type: "application/x-mpegURL", url: "https://video.twimg.com/a.m3u8", bitrate: 99999 }, variant(99999, "https://evil.test/a.mp4"), variant(4000, best)])]), id);
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
  const result = await c.downloadPost(id, { fetchImpl: fetchPost(post([media(), media(), media()])), sendNative: connected(async () => ++count === 1 ? { ok: true, filename: "saved.mp4" } : { ok: false, error: "disk full" }) });
  assert.equal(count, 2); assert.equal(result.ok, false); assert.deepEqual(result.saved, ["saved.mp4"]);
  assert.match(c.resultMessage(result), /saved.mp4/);
});
test("network, rate limit, invalid JSON and native disconnect are visible failures", async () => {
  for (const fetchImpl of [async () => { throw Error("offline"); }, async () => ({ ok: false, status: 429 }), async () => ({ ok: false, status: 403 }), async () => ({ ok: true, json: async () => { throw Error("bad json"); } })]) {
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
  for (const sendNative of [() => new Promise(() => {}), async () => { throw Error("XPC invalidated"); }, async () => undefined, async () => ({ ok: true }), async () => ({ ok: true, protocolVersion: 1 })]) {
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
      sendNativeMessage: () => { calls++; return new Promise(() => {}); },
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
  const base = { quality: 75, maximumFrameRate: 25, scale: 0.75 };
  const override = { quality: 50, maximumFrameRate: 15, scale: 0.5 };
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
  assert.deepEqual(base, { quality: 75, maximumFrameRate: 25, scale: 0.75 });
  await c.requestDownload(id, async message => {
    assert.deepEqual(message.gifOptions, override);
    return { ok: true, saved: [] };
  }, "auto", override);
});

test("GIF validation rejects unsupported types and values before a download", async () => {
  for (const raw of [null, [], {}, { ...c.GIF_DEFAULTS, quality: 91 }, { ...c.GIF_DEFAULTS, maximumFrameRate: 50 }, { ...c.GIF_DEFAULTS, scale: true }, { ...c.GIF_DEFAULTS, scale: "1" }]) {
    assert.throws(() => c.validateGIFOptions(raw));
    const result = await c.downloadPost(id, {
      gifOptions: raw, sendNative: connected(() => assert.fail("must not download")),
      fetchImpl: () => assert.fail("must not fetch")
    });
    assert.equal(result.ok, false);
    assert.match(result.error, /GIF設定/);
  }
});

test("version 2 native is rejected to prevent silently ignoring GIF options", async () => {
  const result = await c.downloadPost(id, {
    sendNative: async () => ({ ok: true, protocolVersion: 2 }),
    fetchImpl: () => assert.fail("must not fetch")
  });
  assert.equal(result.ok, false);
});

test("background exposes GIF defaults only to popup and forwards download overrides", async () => {
  let listener, received;
  const nativeCalls = [];
  const base = { quality: 75, maximumFrameRate: 25, scale: 0.75 };
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
  assert.deepEqual(nativeCalls, ["ping"]);
});
