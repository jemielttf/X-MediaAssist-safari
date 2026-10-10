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
      const button = document.createElement("button");
      button.type = "button";
      button.className = "xma-save";
      button.textContent = `↓ ${t("save_video")}`;
      button.title = t("save_tooltip");
      const status = document.createElement("span");
      status.className = "xma-status";
      status.setAttribute("role", "status");
      status.setAttribute("aria-live", "polite");
      item.append(button, status);
      root.append(item);
      // Keep clicks from opening the post underneath.
      root.addEventListener("click", event => { event.stopPropagation(); });
      button.addEventListener("click", async event => {
        event.preventDefault();
        // Ignore synthetic clicks from page scripts and double clicks while saving.
        if (!event.isTrusted || button.disabled) return;
        button.disabled = true;
        button.textContent = t("downloading");
        status.textContent = t("keep_tab_open");
        try {
          const result = await core.requestDownload(id, message => browser.runtime.sendMessage(message));
          status.textContent = core.resultMessage(result);
          button.textContent = result?.ok ? `↓ ${t("save_again")}` : `↓ ${t("retry")}`;
        } catch (error) {
          status.textContent = error.message || t("content_disconnected");
          button.textContent = `↓ ${t("retry")}`;
        } finally { button.disabled = false; }
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
