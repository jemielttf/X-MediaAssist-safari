(() => {
  "use strict";
  // Safari may inject again when an extension is rebuilt or re-enabled.
  globalThis.__xmaContentCleanup?.();
  const core = globalThis.XMediaCore;
  function postID(article) {
    // Use the timestamp permalink, never arbitrary links in post text or quotes.
    for (const time of article.querySelectorAll("a[href] time")) {
      if (time.closest('article[data-testid="tweet"]') !== article) continue;
      const id = core.parsePostURL(time.closest("a").href);
      if (id) return id;
    }
    return null;
  }
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
      if (!id || !article.querySelector('video, [data-testid="videoPlayer"], [data-testid="playButton"]')) continue;
      const root = document.createElement("div");
      root.className = "xma-controls";
      root.dataset.postId = id;
      const item = document.createElement("div");
      item.className = "xma-item";
      const button = document.createElement("button");
      button.type = "button";
      button.className = "xma-save";
      button.textContent = "↓ MP4を保存";
      button.title = "このポストの動画・GIF投稿を最高品質のMP4で保存";
      const status = document.createElement("span");
      status.className = "xma-status";
      status.setAttribute("role", "status");
      status.setAttribute("aria-live", "polite");
      item.append(button, status);
      root.append(item);
      root.addEventListener("click", event => { event.stopPropagation(); });
      button.addEventListener("click", async event => {
        event.preventDefault();
        if (!event.isTrusted || button.disabled) return;
        button.disabled = true;
        button.textContent = "保存中…";
        status.textContent = "完了までこのタブを開いておいてください。";
        try {
          const result = await core.requestDownload(id, message => browser.runtime.sendMessage(message));
          status.textContent = core.resultMessage(result);
          button.textContent = result?.ok ? "↓ もう一度保存" : "↓ 再試行";
        } catch (error) {
          status.textContent = error.message || "拡張機能との接続が切れました。保存先を確認し、ページを再読み込みしてください。";
          button.textContent = "↓ 再試行";
        } finally { button.disabled = false; }
      });
      const actions = [...article.querySelectorAll('[role="group"]')].find(group => group.querySelector('[data-testid="reply"]'));
      (actions?.parentElement ?? article).append(root);
    }
  }
  let scheduled = false;
  let refreshTimer;
  const observer = new MutationObserver(records => {
    if (records.every(record => record.target.closest?.(".xma-controls"))) return;
    if (scheduled) return;
    scheduled = true;
    refreshTimer = setTimeout(() => { scheduled = false; refresh(); }, 150);
  });
  globalThis.__xmaContentCleanup = () => {
    observer.disconnect();
    clearTimeout(refreshTimer);
  };
  observer.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ["href"] });
  refresh();
})();
