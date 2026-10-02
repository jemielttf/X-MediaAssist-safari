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
    document.getElementById("gif-quality").value = String(options.quality);
    document.getElementById("gif-fps").value = String(options.maximumFrameRate);
    document.getElementById("gif-scale").value = String(options.scale);
    document.getElementById("gif-options").disabled = false;
    document.getElementById("gif-status").textContent = "通常のGIF保存に使います。変更は自動保存されます。";
}
function showGIFError() {
    document.getElementById("gif-options").disabled = true;
    document.getElementById("gif-status").textContent = "GIF設定を読み込み・保存できませんでした。アプリを開き直してください。";
}
document.getElementById("gif-options").addEventListener("change", () => {
    webkit.messageHandlers.controller.postMessage({ type: "set-gif-options", gifOptions: {
        quality: Number(document.getElementById("gif-quality").value),
        maximumFrameRate: Number(document.getElementById("gif-fps").value),
        scale: Number(document.getElementById("gif-scale").value)
    }});
});
