"use strict";
const input = document.getElementById("post-url");
const button = document.getElementById("save");
const status = document.getElementById("status");
browser.tabs.query({ active: true, currentWindow: true }).then(tabs => {
  if (!input.value && XMediaCore.parsePostURL(tabs[0]?.url)) input.value = tabs[0].url;
}).catch(() => {});
document.getElementById("download-form").addEventListener("submit", async event => {
  event.preventDefault();
  const postId = XMediaCore.parsePostURL(input.value.trim());
  if (!postId) { status.textContent = "https://x.com/ユーザー名/status/投稿ID のURLを入力してください。"; return; }
  button.disabled = true;
  status.textContent = "保存中です。完了までこの画面を開いておいてください。";
  try { status.textContent = XMediaCore.resultMessage(await XMediaCore.requestDownload(postId, message => browser.runtime.sendMessage(message))); }
  catch (error) { status.textContent = error.message || "拡張機能との接続が切れました。保存結果をダウンロードフォルダで確認してください。"; }
  finally { button.disabled = false; }
});
