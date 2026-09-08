// Global Translator Bridge — content script.
// Extracts visible Latin text nodes, asks the desktop app (via the
// background worker) for translations and replaces the DOM text in place.
// Mirrors the extraction/apply rules of the CDP in-page pipeline.
(() => {
  const SKIPPED_TAGS = ["SCRIPT", "STYLE", "NOSCRIPT", "CODE", "PRE", "TEXTAREA"];
  // Keep this aligned with local Ollama: qwen3 thinking + JSON schema is
  // reliable one (or a few) string(s) at a time. A 30-item POST made the
  // desktop app run many sequential round-trips under one fetch and die as
  // networkFailure, then open the circuit for ~30s.
  const CHUNK_SIZE = 3;
  const MAX_PER_ROUND = 200;
  const MAX_ROUNDS = 5;
  const OBSERVER_DEBOUNCE_MS = 800;
  const RETRY_INITIAL_MS = 1500;
  const RETRY_MAX_MS = 15000;

  // id -> { node, source, translation } — source is the text we translated;
  // if the page re-renders a node with the same source text, the cached
  // translation is re-applied instantly without another server round-trip.
  const store = { entries: new Map(), next: 0 };
  let enabled = true;
  let running = false;
  let observer = null;
  let debounceTimer = null;
  let retryTimer = null;
  let retryDelay = RETRY_INITIAL_MS;

  function textOf(node) {
    return (node.nodeValue || "").trim();
  }

  function isEligible(node) {
    const text = textOf(node);
    if (text.length < 2) return false;
    if (!/[A-Za-z]/.test(text) || /[一-鿿]/.test(text)) return false;
    const element = node.parentElement;
    if (!element || SKIPPED_TAGS.indexOf(element.tagName) !== -1) return false;
    if (element.closest && element.closest('[contenteditable="true"], [contenteditable=""]')) return false;
    const rect = element.getBoundingClientRect();
    if (rect.width < 4 || rect.height < 4) return false;
    const style = getComputedStyle(element);
    if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) return false;
    return true;
  }

  function nodeId(node) {
    for (const [id, entry] of store.entries) {
      if (entry.node === node) return id;
    }
    const id = String(store.next++);
    store.entries.set(id, { node, source: null, translation: null });
    return id;
  }

  // Collect nodes still awaiting translation. Nodes the page reverted to a
  // previously translated source text are re-applied from cache immediately;
  // anything else goes to the desktop app.
  function extract() {
    const results = [];
    const walker = document.createTreeWalker(
      document.body || document.documentElement,
      NodeFilter.SHOW_TEXT
    );
    let node;
    while ((node = walker.nextNode())) {
      if (!isEligible(node)) continue;
      const id = nodeId(node);
      const entry = store.entries.get(id);
      const text = textOf(node);
      if (entry.source === text && entry.translation) {
        node.nodeValue = node.nodeValue.replace(text, entry.translation);
        continue;
      }
      if (entry.source === text) continue;
      results.push({ id, text });
      if (results.length >= MAX_PER_ROUND) break;
    }
    return results;
  }

  function translateChunk(texts) {
    return new Promise((resolve) => {
      chrome.runtime.sendMessage({ type: "translate", texts }, (response) => {
        if (chrome.runtime.lastError || !response || response.error) {
          resolve(null);
          return;
        }
        resolve(response.translations || []);
      });
    });
  }

  function apply(items, translations) {
    let applied = 0;
    for (let i = 0; i < items.length; i++) {
      const entry = store.entries.get(items[i].id);
      const node = entry && entry.node;
      if (!node || !node.isConnected) continue;
      const original = node.nodeValue;
      const trimmed = original.trim();
      if (!trimmed || trimmed !== items[i].text) continue;
      // Mark as asked even when the app filtered the text out (nil
      // translation), otherwise every DOM mutation would re-request it.
      entry.source = items[i].text;
      const translated = translations[i];
      if (!translated || typeof translated !== "string") continue;
      node.nodeValue = original.replace(trimmed, translated);
      entry.translation = translated;
      applied++;
    }
    return applied;
  }

  async function run() {
    if (!enabled || running) return;
    if (document.visibilityState !== "visible") return;
    running = true;
    try {
      for (let round = 0; round < MAX_ROUNDS; round++) {
        if (!enabled || document.visibilityState !== "visible") break;
        const items = extract();
        if (items.length === 0) break;
        for (let offset = 0; offset < items.length; offset += CHUNK_SIZE) {
          const chunk = items.slice(offset, offset + CHUNK_SIZE);
          const translations = await translateChunk(chunk.map((item) => item.text));
          if (!translations) {
            // App unreachable or master switch bouncing; retry without
            // waiting for another DOM mutation.
            scheduleRetry();
            return;
          }
          apply(chunk, translations);
        }
      }
      retryDelay = RETRY_INITIAL_MS;
    } finally {
      running = false;
    }
  }

  function scheduleRun() {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(run, OBSERVER_DEBOUNCE_MS);
  }

  function scheduleRetry() {
    if (!enabled || retryTimer) return;
    const delay = retryDelay;
    retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
    retryTimer = setTimeout(() => {
      retryTimer = null;
      run();
    }, delay);
  }

  function startObserver() {
    if (observer) return;
    observer = new MutationObserver(scheduleRun);
    observer.observe(document.body || document.documentElement, {
      childList: true,
      subtree: true,
      characterData: true
    });
  }

  function stopObserver() {
    if (observer) observer.disconnect();
    observer = null;
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = null;
    if (retryTimer) clearTimeout(retryTimer);
    retryTimer = null;
  }

  chrome.storage.local.get({ enabled: true }, (prefs) => {
    enabled = prefs.enabled !== false;
    if (enabled) {
      startObserver();
      run();
    }
  });

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local" || !("enabled" in changes)) return;
    enabled = changes.enabled.newValue !== false;
    if (enabled) {
      startObserver();
      retryDelay = RETRY_INITIAL_MS;
      run();
    } else {
      stopObserver();
    }
  });

  document.addEventListener("visibilitychange", () => {
    if (!enabled || document.visibilityState !== "visible") return;
    retryDelay = RETRY_INITIAL_MS;
    scheduleRun();
  });
})();
