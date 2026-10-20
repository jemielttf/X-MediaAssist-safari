/* Adds a "Save video" button to each X post that shows a video or animated GIF. */
(() => {
  "use strict";
  // Safari may inject again when an extension is rebuilt or re-enabled.
  globalThis.__xmaContentCleanup?.();
  const core = globalThis.XMediaCore;
  const t = core.t;

  function postID(article) {
    // Use the timestamp permalink, never arbitrary links in post text or quotes.
    for (const time of article.querySelectorAll("a[href] time")) {
      if (time.closest('article[data-testid="tweet"]') !== article) continue;
      const id = core.parsePostURL(time.closest("a").href);
      if (id) return id;
    }
    return null;
  }

  // Ensures each video post has exactly one control for its current post ID.
  function refresh() {
    for (const article of document.querySelectorAll('article[data-testid="tweet"]')) {
      const id = postID(article);
      // Check the DOM too: a reused article or another script context
      // is not represented by a script-local WeakMap.
      const roots = [...article.querySelectorAll(".xma-controls")]
        .filter(root => root.closest('article[data-testid="tweet"]') === article);
      const existing = roots.find(root => root.dataset.postId === id);
      // Legacy observers reinsert their root whenever it is removed. Keep those
      // roots connected (CSS hides them), rather than triggering a repair loop.
      for (const root of roots) {
        if (root.dataset.postId && root !== existing) root.remove();
      }
      if (existing) continue;
      // X can render only a thumbnail + playButton until playback starts.
      const hasVideo = article.querySelector('video, [data-testid="videoPlayer"], [data-testid="playButton"]');
      if (!id || !hasVideo) continue;

      const root = document.createElement("div");
      root.className = "xma-controls";
      root.lang = globalThis.XMediaI18n.language();
      root.dataset.postId = id;
      const item = document.createElement("div");
      item.className = "xma-item";
      const buttons = document.createElement("div");
      buttons.className = "xma-actions";
      const button = document.createElement("button");
      button.type = "button";
      button.className = "xma-save";
      button.textContent = `↓ ${t("save_video")}`;
      button.title = t("save_tooltip");
      // Shown once something was saved; selects those files in Finder.
      const reveal = document.createElement("button");
      reveal.type = "button";
      reveal.className = "xma-save xma-reveal";
      reveal.textContent = t("show_in_finder");
      reveal.hidden = true;
      const status = document.createElement("span");
      status.className = "xma-status";
      status.setAttribute("role", "status");
      status.setAttribute("aria-live", "polite");
      buttons.append(button, reveal);
      item.append(buttons, status);
      root.append(item);
      // Keep clicks from opening the post underneath.
      root.addEventListener("click", event => { event.stopPropagation(); });
      const sendMessage = message => browser.runtime.sendMessage(message);
      let saved = [];
      let resultText = "";
      button.addEventListener("click", async event => {
        event.preventDefault();
        // Ignore synthetic clicks from page scripts and double clicks while saving.
        if (!event.isTrusted || button.disabled) return;
        button.disabled = true;
        reveal.hidden = true;
        button.textContent = t("downloading");
        const showProgress = progress => {
          status.textContent = `${core.progressMessage(progress)}\n${t("keep_tab_open")}`;
        };
        showProgress(null);
        try {
          const result = await core.requestDownload(id, sendMessage, "auto", undefined, { onProgress: showProgress });
          resultText = core.resultMessage(result);
          saved = Array.isArray(result?.saved) ? result.saved.filter(core.isSavedFilename) : [];
          button.textContent = result?.ok ? `↓ ${t("save_again")}` : `↓ ${t("retry")}`;
        } catch (error) {
          resultText = error.message || t("content_disconnected");
          saved = [];
          button.textContent = `↓ ${t("retry")}`;
        } finally {
          status.textContent = resultText;
          reveal.hidden = saved.length === 0;
          button.disabled = false;
        }
      });
      reveal.addEventListener("click", async event => {
        event.preventDefault();
        if (!event.isTrusted || reveal.disabled) return;
        reveal.disabled = true;
        try {
          const reply = await core.withTimeout(
            () => sendMessage({ type: "revealFiles", filenames: saved }),
            core.REVEAL_TIMEOUT_MS, t("reveal_failed"));
          status.textContent = reply?.ok ? resultText : `${resultText}\n${reply?.error || t("reveal_failed")}`;
        } catch {
          status.textContent = `${resultText}\n${t("reveal_failed")}`;
        } finally { reveal.disabled = false; }
      });
      // Place the controls just below the reply/repost/like bar when it exists.
      const actions = [...article.querySelectorAll('[role="group"]')]
        .find(group => group.querySelector('[data-testid="reply"]'));
      (actions?.parentElement ?? article).append(root);
    }
  }

  // X renders posts lazily and reuses articles; refresh at most once per 150 ms.
  let scheduled = false;
  let refreshTimer;
  const observer = new MutationObserver(records => {
    // Changes inside our own controls (status text, button label) need no refresh.
    if (records.every(record => record.target.closest?.(".xma-controls"))) return;
    if (scheduled) return;
    scheduled = true;
    refreshTimer = setTimeout(() => { scheduled = false; refresh(); }, 150);
  });
  globalThis.__xmaContentCleanup = () => {
    observer.disconnect();
    clearTimeout(refreshTimer);
  };
  // href changes catch an article reused for a different post.
  observer.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ["href"] });
  refresh();
})();
