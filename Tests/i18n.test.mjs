import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFile } from "node:fs/promises";
import { createI18n, messages } from "./i18n-fixture.mjs";

const read = path => readFile(new URL(`../${path}`, import.meta.url), "utf8");
const sources = await Promise.all(["Extension/i18n.js", "Extension/core.js"].map(read));
function context(language) {
  const ctx = vm.createContext({ browser: { i18n: createI18n(language) }, URL, AbortSignal, setTimeout, clearTimeout });
  sources.forEach(source => vm.runInContext(source, ctx));
  return ctx;
}
const postId = "123";
const fetchImpl = async () => ({ ok: true, json: async () => ({ id_str: postId, mediaDetails: [1, 2].map(() => ({
  type: "animated_gif", video_info: { variants: [{ content_type: "video/mp4", url: "https://video.twimg.com/test.mp4" }] }
})) }) });
const native = reply => async message => message.type === "ping" ? { ok: true, protocolVersion: 3 } : reply;

test("both WebExtension catalogs cover every UI key with matching substitutions", async () => {
  assert.deepEqual(Object.keys(messages.ja).sort(), Object.keys(messages.en).sort());
  for (const [key, entry] of Object.entries(messages.en)) {
    assert.ok(entry.message.length, key);
    assert.ok(messages.ja[key].message.length, key);
    assert.deepEqual(messages.ja[key].message.match(/\$\d+/g), entry.message.match(/\$\d+/g), key);
  }
  for (const path of ["Extension/core.js", "Extension/popup.js", "Extension/content.js", "Extension/background.js", "Extension/popup.html"]) {
    for (const match of (await read(path)).matchAll(/(?:\bt\("|data-i18n=")([a-z0-9_]+)/g)) assert.ok(messages.en[match[1]], `${path}: ${match[1]}`);
  }
  const manifest = JSON.parse(await read("Extension/manifest.json"));
  assert.equal(manifest.default_locale, "en");
  assert.equal(manifest.description, "__MSG_extension_description__");
});

test("app catalog covers AppKit and WKWebView keys in both languages", async () => {
  // The WKWebView receives the whole compiled table, so catalog coverage is sufficient.
  const catalog = JSON.parse(await read("X Media Assist/X Media Assist/Resources/Localizable.xcstrings"));
  const app = "X Media Assist/X Media Assist";
  const keyPattern = /(?:\bt\("|data-i18n="|AppLocalization\.string\("|makeMenuItem\(")([a-z_]+)/g;
  for (const path of [`${app}/Resources/Base.lproj/Main.html`, `${app}/Resources/Script.js`, `${app}/AppDelegate.swift`]) {
    for (const match of (await read(path)).matchAll(keyPattern)) {
      for (const language of ["ja", "en"]) {
        assert.ok(catalog.strings[match[1]]?.localizations[language].stringUnit.value,
          `${path}: ${match[1]} (${language})`);
      }
    }
  }
});

test("localization applies text safely and marks the document language", () => {
  for (const language of ["ja", "en", "fr"]) {
    const { XMediaI18n: i18n } = context(language);
    const label = { dataset: { i18n: "quality_high" }, textContent: "" };
    const document = { documentElement: {}, querySelectorAll: () => [label] };
    i18n.localize(document);
    assert.equal(document.documentElement.lang, language === "ja" ? "ja" : "en");
    assert.equal(label.textContent, language === "ja" ? "高" : "High");
    assert.match(i18n.text("no_mp4_variant", [4]), /4/);
  }
});

test("native failures use codes in both languages, with validated HTTP arguments and legacy fallback", async () => {
  for (const language of ["ja", "en"]) {
    const c = context(language).XMediaCore;
    for (const [code, key] of Object.entries({
      invalid_request: "native_invalid_request", invalid_response: "native_invalid_response",
      too_large: "native_too_large", invalid_mp4: "native_invalid_mp4", busy: "save_busy",
      write_failed: "native_write_failed", network: "native_network"
    })) {
      const result = await c.downloadPost(postId, { fetchImpl, sendNative: native({ ok: false, errorCode: code, error: "legacy" }) });
      assert.equal(result.error, messages[language][key].message);
    }
    const result = await c.downloadPost(postId, { fetchImpl, sendNative: native({ ok: false, errorCode: "http", httpStatus: 403 }) });
    assert.equal(result.error, c.t("native_http", [403]));
    for (const reply of [{ errorCode: "new_code" }, {}, { errorCode: "__proto__" }, { errorCode: "http", httpStatus: "<script>" }]) {
      const result = await c.downloadPost(postId, { fetchImpl, sendNative: native({ ...reply, ok: false, error: "legacy" }) });
      assert.equal(result.error, "legacy");
    }
  }
});

test("translated GIF warnings preserve saved filenames and continue to remaining media", async () => {
  for (const language of ["ja", "en"]) {
    const c = context(language).XMediaCore;
    for (const code of ["gif_unsupported", "gif_limit", "gif_encoding", "gif_timeout", "gif_busy", "gif_failed", "future_code"]) {
      const reply = { ok: true, filename: "original-name.mp4", warning: "legacy warning", warningCode: code };
      const result = await c.downloadPost(postId, { fetchImpl, sendNative: native(reply) });
      assert.equal(result.ok, false);
      assert.equal(result.saved.length, 2);
      assert.equal(result.warnings[0], `original-name.mp4: ${messages[language][code]?.message ?? "legacy warning"}`);
      assert.match(c.resultMessage(result), /original-name\.mp4/);
    }
  }
});

test("English save results distinguish one file, multiple files and partial saves", () => {
  const c = context("en").XMediaCore;
  assert.match(c.resultMessage({ ok: true, saved: ["a.gif"] }), /^Saved 1 file to Downloads/);
  assert.match(c.resultMessage({ ok: true, saved: ["a.gif", "b.mp4"] }), /^Saved 2 files to Downloads/);
  assert.match(c.resultMessage({ ok: false, saved: ["a.gif"], error: "failed" }), /^1 file has already been saved/);
  assert.match(c.resultMessage({ ok: false, saved: ["a.gif", "b.mp4"], error: "failed" }), /^2 files have already been saved/);
});
