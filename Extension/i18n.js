/* WebExtension messages are resolved by Safari, including default_locale fallback. */
(() => {
  "use strict";
  function text(key, substitutions = []) {
    return browser.i18n.getMessage(key, substitutions.map(String)) || key;
  }
  function language() { return text("ui_language"); }
  function localize(document) {
    document.documentElement.lang = language();
    for (const element of document.querySelectorAll("[data-i18n]")) {
      element.textContent = text(element.dataset.i18n);
    }
  }
  globalThis.XMediaI18n = Object.freeze({ text, language, localize });
})();
