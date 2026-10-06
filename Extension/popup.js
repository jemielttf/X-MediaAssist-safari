"use strict";
const t = globalThis.XMediaI18n.text;
globalThis.XMediaI18n.localize(document);
const input = document.getElementById("post-url");
const button = document.getElementById("save");
const status = document.getElementById("status");
const gifFields = document.getElementById("gif-options");
let gifOptionsReady = false;
let downloading = false;
function updateGIFControls() {
	const mp4 = document.querySelector('input[name="format"]:checked').value === "mp4";
	gifFields.disabled = !gifOptionsReady || downloading || mp4;
}
document.querySelectorAll('input[name="format"]').forEach(control => control.addEventListener("change", updateGIFControls));
const loadGIFOptions = XMediaCore.withTimeout(
	() => browser.runtime.sendMessage({ type: "getGIFOptions" }), 15000, t("gif_options_load_failed")
).then(reply => {
	if (!reply?.ok) throw new Error(reply?.error || t("gif_options_load_failed"));
	const options = XMediaCore.validateGIFOptions(reply.gifOptions);
	document.querySelector(`input[name="gif-quality"][value="${options.quality}"]`).checked = true;
	document.querySelector(`input[name="gif-fps"][value="${options.maximumFrameRate}"]`).checked = true;
	document.querySelector(`input[name="gif-scale"][value="${options.scale}"]`).checked = true;
	gifOptionsReady = true;
}).catch(error => {
	status.textContent = t("gif_options_retry", [error.message || t("gif_options_load_failed")]);
}).finally(updateGIFControls);
browser.tabs
	.query({ active: true, currentWindow: true })
	.then((tabs) => {
		if (!input.value && XMediaCore.parsePostURL(tabs[0]?.url))
			input.value = tabs[0].url;
	})
	.catch(() => {});
document
	.getElementById("download-form")
	.addEventListener("submit", async (event) => {
		event.preventDefault();
		const postId = XMediaCore.parsePostURL(input.value.trim());
		if (!postId) {
			status.textContent =
				t("invalid_post_url");
			return;
		}
		button.disabled = true;
		downloading = true;
		updateGIFControls();
		status.textContent =
			t("keep_popup_open");
		try {
			await loadGIFOptions;
			status.textContent = XMediaCore.resultMessage(
				await XMediaCore.requestDownload(
					postId,
					(message) => browser.runtime.sendMessage(message),
					document.querySelector('input[name="format"]:checked').value,
					gifOptionsReady ? {
						quality: Number(document.querySelector('input[name="gif-quality"]:checked').value),
						maximumFrameRate: Number(document.querySelector('input[name="gif-fps"]:checked').value),
						scale: Number(document.querySelector('input[name="gif-scale"]:checked').value)
					} : undefined,
				),
			);
		} catch (error) {
			status.textContent =
				error.message ||
				t("popup_disconnected");
		} finally {
			button.disabled = false;
			downloading = false;
			updateGIFControls();
		}
	});
