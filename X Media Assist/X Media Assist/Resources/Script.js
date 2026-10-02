function show(enabled) {
    document.body.classList.toggle("state-on", enabled === true);
    document.body.classList.toggle("state-off", enabled === false);
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
