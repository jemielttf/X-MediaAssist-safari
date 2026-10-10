// Swift provides strings from the app's selected localization before this script loads.
const localized = globalThis.XMAStrings;
const t = key => localized?.messages[key] || key;
if (localized) {
    document.documentElement.lang = localized.language;
    document.querySelectorAll("[data-i18n]").forEach(element => {
        element.textContent = t(element.dataset.i18n);
    });
}

// show, showError, showGIFOptions and showGIFError are called from ViewController.swift.
function show(enabled) {
    const status = document.getElementById("extension-status");
    status.classList.toggle("is-enabled", enabled === true);
    status.querySelector("span").textContent = enabled === true
        ? t("extension_enabled")
        : t("extension_disabled");
}
function showError() {
    document.getElementById("error").textContent = t("preferences_error");
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
    document.getElementById("gif-status").textContent = t("gif_ready");
}
function showGIFError() {
    document.getElementById("gif-options").disabled = true;
    document.getElementById("gif-status").textContent = t("gif_error");
}
// Every change is saved immediately; Swift validates the values again before storing them.
document.getElementById("gif-options").addEventListener("change", () => {
    webkit.messageHandlers.controller.postMessage({ type: "set-gif-options", gifOptions: {
        quality: Number(document.querySelector('input[name="gif-quality"]:checked').value),
        maximumFrameRate: Number(document.querySelector('input[name="gif-fps"]:checked').value),
        scale: Number(document.querySelector('input[name="gif-scale"]:checked').value)
    }});
});
