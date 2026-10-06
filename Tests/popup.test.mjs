import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFile } from "node:fs/promises";
import { createI18n } from "./i18n-fixture.mjs";

const sources = await Promise.all(["i18n", "core", "popup"].map(name =>
  readFile(new URL(`../Extension/${name}.js`, import.meta.url), "utf8")));
const settle = () => new Promise(resolve => setImmediate(resolve));

function popup(sendMessage) {
  const element = value => ({ value, disabled: false, textContent: "", listeners: {},
    addEventListener(type, listener) { this.listeners[type] = listener; } });
  const elements = Object.fromEntries(["post-url", "save", "status", "gif-options", "download-form"].map(id => [id, element("")]));
  elements["post-url"].value = "https://x.com/example/status/123";
  const groups = Object.fromEntries(Object.entries({ format: ["auto", "mp4"], "gif-quality": ["95", "85", "70"],
    "gif-fps": ["20", "30", "25", "15"], "gif-scale": ["1", "0.75", "0.5"] }).map(([name, values]) => {
    let selected = values[0];
    return [name, values.map(value => Object.defineProperty(element(value), "checked", {
      get: () => selected === value, set: checked => { if (checked) selected = value; }
    }))];
  }));
  const timers = new Map();
  const context = vm.createContext({
    URL, AbortSignal,
    setTimeout(callback, milliseconds) { const timer = {}; timers.set(timer, { callback, milliseconds }); return timer; },
    clearTimeout(timer) { timers.delete(timer); },
    document: {
      documentElement: {}, getElementById: id => elements[id],
      querySelector(selector) {
        const match = selector.match(/^input\[name="([^"]+)"\](?:\[value="([^"]+)"\]|:checked)$/);
        return groups[match[1]].find(control => match[2] ? control.value === match[2] : control.checked);
      },
      querySelectorAll: selector => selector === 'input[name="format"]' ? groups.format : []
    },
    browser: { i18n: createI18n("ja"), tabs: { query: async () => [] }, runtime: { sendMessage } }
  });
  sources.forEach(source => vm.runInContext(source, context));
  return {
    elements, groups, timers,
    submit: () => elements["download-form"].listeners.submit({ preventDefault() {} }),
    expire() {
      const entry = [...timers.entries()].find(([, timer]) => timer.milliseconds === 15000);
      assert.ok(entry, "a pending settings/connection request must have a 15-second deadline");
      timers.delete(entry[0]);
      entry[1].callback();
    }
  };
}

test("popup loads GIF defaults and sends the selected options once", async () => {
  const messages = [];
  const options = { quality: 85, maximumFrameRate: 25, scale: 0.75 };
  const ui = popup(async message => {
    messages.push(message);
    if (message.type === "getGIFOptions") return { ok: true, gifOptions: options };
    if (message.type === "checkConnection") return { ok: true, instance: "background" };
    return { ok: true, saved: ["saved.gif"] };
  });
  await settle();
  assert.equal(ui.elements["gif-options"].disabled, false);
  await ui.submit();
  assert.deepEqual(messages.map(message => message.type), ["getGIFOptions", "checkConnection", "downloadPost"]);
  assert.equal(JSON.stringify(messages[2].gifOptions), JSON.stringify(options));
  assert.equal(ui.elements.save.disabled, false);
  assert.equal(ui.elements["gif-options"].disabled, false);
  assert.match(ui.elements.status.textContent, /saved\.gif/);
  assert.equal(ui.timers.size, 0);
});

test("popup preserves the base-settings retry path after GIF settings fail", async () => {
  const messages = [];
  const ui = popup(async message => {
    messages.push(message);
    if (message.type === "getGIFOptions") throw new Error("settings unavailable");
    if (message.type === "checkConnection") return { ok: true, instance: "background" };
    return { ok: true, saved: ["saved.gif"] };
  });
  await settle();
  assert.match(ui.elements.status.textContent, /保存時に基本設定を再取得/);
  await ui.submit();
  assert.deepEqual(messages.map(message => message.type), ["getGIFOptions", "checkConnection", "downloadPost"]);
  assert.equal(messages[2].gifOptions, undefined);
  assert.equal(ui.elements.save.disabled, false);
  assert.equal(ui.elements["gif-options"].disabled, true);
  assert.match(ui.elements.status.textContent, /saved\.gif/);
  assert.equal(ui.timers.size, 0);
});

test("lost GIF settings and connection replies release the popup without starting or retrying a save", async () => {
  const messages = [];
  let reply;
  const ui = popup(message => {
    messages.push(message);
    return new Promise(resolve => { if (message.type === "getGIFOptions") reply = resolve; });
  });
  const saving = ui.submit();
  await settle();
  assert.equal(ui.elements.save.disabled, true);
  ui.expire();
  await settle();
  assert.deepEqual(messages.map(message => message.type), ["getGIFOptions", "checkConnection"]);
  ui.expire();
  await saving;
  assert.equal(ui.elements.save.disabled, false);
  assert.equal(ui.elements["gif-options"].disabled, true);
  assert.match(ui.elements.status.textContent, /接続が切れ/);
  assert.equal(ui.timers.size, 0);
  reply({ ok: true, gifOptions: { quality: 70, maximumFrameRate: 15, scale: 0.5 } });
  await settle();
  assert.equal(ui.groups["gif-quality"].find(control => control.checked).value, "95");
  assert.equal(ui.elements["gif-options"].disabled, true);
  assert.deepEqual(messages.map(message => message.type), ["getGIFOptions", "checkConnection"]);
});
