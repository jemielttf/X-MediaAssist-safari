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
