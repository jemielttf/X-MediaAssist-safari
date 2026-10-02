function show(enabled) {
    const status = document.getElementById("extension-status");
    status.classList.toggle("is-enabled", enabled === true);
    status.querySelector("span").textContent = enabled === true
        ? "Safari拡張機能は有効です"
        : "Safari拡張機能は無効です。Safariの設定で有効にしてください。";
}
function showError() {
    document.getElementById("error").textContent = "Safariの設定を開けませんでした。Safariのメニューから「設定 → 拡張機能」を開いてください。";
}
document.querySelector(".open-preferences").addEventListener("click", () => {
    webkit.messageHandlers.controller.postMessage("open-preferences");
});

document.querySelector(".open-licenses").addEventListener("click", () => {
    webkit.messageHandlers.controller.postMessage("open-licenses");
});

function showGIFOptions(options) {
    document.querySelector(`input[name="gif-quality"][value="${options.quality}"]`).checked = true;
    document.querySelector(`input[name="gif-fps"][value="${options.maximumFrameRate}"]`).checked = true;
    document.querySelector(`input[name="gif-scale"][value="${options.scale}"]`).checked = true;
    document.getElementById("gif-options").disabled = false;
    document.getElementById("gif-status").textContent = "通常のGIF保存に使います。変更は自動保存されます。";
    renderGIFSummary();
}
function showGIFError() {
    document.getElementById("gif-options").disabled = true;
    document.getElementById("summary").hidden = true;
    document.getElementById("gif-status").textContent = "GIF設定を読み込み・保存できませんでした。アプリを開き直してください。";
}
function renderGIFSummary() {
    const quality = document.querySelector('input[name="gif-quality"]:checked').nextElementSibling.textContent;
    const rate = document.querySelector('input[name="gif-fps"]:checked').value;
    const scale = Number(document.querySelector('input[name="gif-scale"]:checked').value);
    const summary = document.getElementById("summary");
    const title = document.createElement("strong");
    title.textContent = `${quality}画質`;
    summary.replaceChildren(title, `、最大${rate}fpsを目安に、${scale === 1 ? "元のサイズ" : `元の${scale * 100}%のサイズ`}のGIFを保存します。`);
    summary.hidden = false;
}

document.getElementById("gif-options").addEventListener("change", () => {
    renderGIFSummary();
    webkit.messageHandlers.controller.postMessage({ type: "set-gif-options", gifOptions: {
        quality: Number(document.querySelector('input[name="gif-quality"]:checked').value),
        maximumFrameRate: Number(document.querySelector('input[name="gif-fps"]:checked').value),
        scale: Number(document.querySelector('input[name="gif-scale"]:checked').value)
    }});
});
