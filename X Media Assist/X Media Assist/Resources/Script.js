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
}
function showGIFError() {
    document.getElementById("gif-options").disabled = true;
    document.getElementById("gif-status").textContent = "GIF設定を読み込み・保存できませんでした。アプリを開き直してください。";
}
document.getElementById("gif-options").addEventListener("change", () => {
    webkit.messageHandlers.controller.postMessage({ type: "set-gif-options", gifOptions: {
        quality: Number(document.querySelector('input[name="gif-quality"]:checked').value),
        maximumFrameRate: Number(document.querySelector('input[name="gif-fps"]:checked').value),
        scale: Number(document.querySelector('input[name="gif-scale"]:checked').value)
    }});
});
