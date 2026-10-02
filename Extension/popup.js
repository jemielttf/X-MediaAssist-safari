"use strict";
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
const loadGIFOptions = browser.runtime.sendMessage({ type: "getGIFOptions" }).then(reply => {
	if (!reply?.ok) throw new Error(reply?.error || "GIF基本設定を読み込めませんでした。");
	const options = XMediaCore.validateGIFOptions(reply.gifOptions);
	document.querySelector(`input[name="gif-quality"][value="${options.quality}"]`).checked = true;
	document.querySelector(`input[name="gif-fps"][value="${options.maximumFrameRate}"]`).checked = true;
	document.querySelector(`input[name="gif-scale"][value="${options.scale}"]`).checked = true;
	gifOptionsReady = true;
}).catch(error => {
	status.textContent = `${error.message} 保存時に基本設定を再取得します。`;
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
				"https://x.com/ユーザー名/status/投稿ID のURLを入力してください。";
			return;
		}
		button.disabled = true;
		downloading = true;
		updateGIFControls();
		status.textContent =
			"取得・変換中です。完了までこの画面を開いておいてください。";
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
				"拡張機能との接続が切れました。保存結果をダウンロードフォルダで確認してください。";
		} finally {
			button.disabled = false;
			downloading = false;
			updateGIFControls();
		}
	});
