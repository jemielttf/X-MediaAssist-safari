"use strict";
// Toolbar popup: save a post by URL, optionally overriding GIF settings for this save only.
const t = globalThis.XMediaI18n.text;
globalThis.XMediaI18n.localize(document);

const input = document.getElementById("post-url");
const button = document.getElementById("save");
const status = document.getElementById("status");
const gifFields = document.getElementById("gif-options");
let gifOptionsReady = false;
let downloading = false;

const checkedValue = name => document.querySelector(`input[name="${name}"]:checked`).value;
const check = (name, value) => { document.querySelector(`input[name="${name}"][value="${value}"]`).checked = true; };

// GIF controls are usable only after the base settings load, and not while saving or in MP4 mode.
function updateGIFControls() {
  gifFields.disabled = !gifOptionsReady || downloading || checkedValue("format") === "mp4";
}
document.querySelectorAll('input[name="format"]')
  .forEach(control => control.addEventListener("change", updateGIFControls));

// Preselect the base GIF settings. On failure, saves omit gifOptions so the background
// re-reads the base settings itself.
const loadGIFOptions = XMediaCore.withTimeout(
  () => browser.runtime.sendMessage({ type: "getGIFOptions" }), 15000, t("gif_options_load_failed")
).then(reply => {
  if (!reply?.ok) throw new Error(reply?.error || t("gif_options_load_failed"));
  const options = XMediaCore.validateGIFOptions(reply.gifOptions);
  check("gif-quality", options.quality);
  check("gif-fps", options.maximumFrameRate);
  check("gif-scale", options.scale);
  gifOptionsReady = true;
}).catch(error => {
  status.textContent = t("gif_options_retry", [error.message || t("gif_options_load_failed")]);
}).finally(updateGIFControls);

// Prefill the URL when the active tab is an X post.
browser.tabs.query({ active: true, currentWindow: true })
  .then(tabs => {
    if (!input.value && XMediaCore.parsePostURL(tabs[0]?.url)) input.value = tabs[0].url;
  })
  .catch(() => {});

document.getElementById("download-form").addEventListener("submit", async event => {
  event.preventDefault();
  const postId = XMediaCore.parsePostURL(input.value.trim());
  if (!postId) {
    status.textContent = t("invalid_post_url");
    return;
  }

  button.disabled = true;
  downloading = true;
  updateGIFControls();
  status.textContent = t("keep_popup_open");
  try {
    await loadGIFOptions;
    const gifOptions = gifOptionsReady ? {
      quality: Number(checkedValue("gif-quality")),
      maximumFrameRate: Number(checkedValue("gif-fps")),
      scale: Number(checkedValue("gif-scale"))
    } : undefined;
    const result = await XMediaCore.requestDownload(
      postId, message => browser.runtime.sendMessage(message), checkedValue("format"), gifOptions);
    status.textContent = XMediaCore.resultMessage(result);
  } catch (error) {
    status.textContent = error.message || t("popup_disconnected");
  } finally {
    button.disabled = false;
    downloading = false;
    updateGIFControls();
  }
});
