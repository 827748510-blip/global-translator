// Global Translator Bridge — content script.
// Extracts visible text nodes in any language, asks the desktop app (via the
// background worker) for translations and replaces the DOM text in place.
// Restores original source text immediately when toggled off.
(() => {
  const SKIPPED_TAGS = ["SCRIPT", "STYLE", "NOSCRIPT", "CODE", "PRE", "TEXTAREA"];
  // Keep this aligned with TranslationCoordinator.localPageTextBatchSize.
  const CHUNK_SIZE = 3;
  const MAX_PER_ROUND = 200;
  const MAX_ROUNDS = 5;
  const OBSERVER_DEBOUNCE_MS = 800;
  const RETRY_INITIAL_MS = 1500;
  const RETRY_MAX_MS = 15000;

  // id -> { node, source, translation }
  const store = { entries: new Map(), next: 0 };
  const nodeIds = typeof WeakMap !== "undefined" ? new WeakMap() : null;
  let enabled = true;
  let running = false;
  let mutatingOwnDom = false;
  let observer = null;
  let debounceTimer = null;
  let retryTimer = null;
  let retryDelay = RETRY_INITIAL_MS;
  let retryPending = false;

  function textOf(node) {
    return (node.nodeValue || "").trim();
  }

  function pageLanguage() {
    return GlobalTranslatorTextFilter.normalizeSourceLanguage(
      (document.documentElement && document.documentElement.lang) || ""
    );
  }

  function isEligible(node) {
    const element = node.parentElement;
    if (!element || SKIPPED_TAGS.indexOf(element.tagName) !== -1) return false;
    if (element.closest && element.closest('[contenteditable="true"], [contenteditable=""]')) return false;
    if (element.closest && element.closest("[data-gt-video-translate], .ytp-caption-window-container, .ytp-caption-segment, .caption-window")) return false;
    const rect = element.getBoundingClientRect();
    if (rect.width < 4 || rect.height < 4) return false;
    const style = getComputedStyle(element);
    if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) return false;
    return true;
  }

  function pruneDisconnectedEntries() {
    for (const [id, entry] of store.entries) {
      if (!entry.node || !entry.node.isConnected) {
        store.entries.delete(id);
      }
    }
  }

  function nodeId(node) {
    if (nodeIds) {
      const existing = nodeIds.get(node);
      if (existing && store.entries.has(existing)) return existing;
      const id = String(store.next++);
      nodeIds.set(node, id);
      store.entries.set(id, { node, source: null, translation: null });
      return id;
    }
    for (const [id, entry] of store.entries) {
      if (entry.node === node) return id;
    }
    const id = String(store.next++);
    store.entries.set(id, { node, source: null, translation: null });
    return id;
  }

  // Two-phase extract: read DOM & collect cached re-applications first, then
  // write all cached translations in one batch so reads and writes never interleave.
  function extract(sourceLanguage) {
    pruneDisconnectedEntries();
    const results = [];
    const cacheReapply = [];
    const walker = document.createTreeWalker(
      document.body || document.documentElement,
      NodeFilter.SHOW_TEXT
    );
    let node;
    while ((node = walker.nextNode())) {
      const text = textOf(node);
      const parts = text.split(/(\r\n|[\n\r\u2028\u2029])/);
      const segments = [];
      for (let index = 0; index < parts.length; index += 2) {
        const source = parts[index].trim();
        if (GlobalTranslatorTextFilter.shouldSendForPageTranslate(source, sourceLanguage)) {
          segments.push({ index, source });
        }
      }
      if (segments.length === 0 || !isEligible(node)) continue;
      const id = nodeId(node);
      const entry = store.entries.get(id);
      if (entry.translation === text) continue;
      if (entry.source === text && entry.translation) {
        cacheReapply.push({ node, text, translation: entry.translation });
        continue;
      }
      if (entry.source === text) continue;
      const item = { id, text, parts, remaining: segments.length, retry: false };
      for (const segment of segments) results.push({ item, ...segment });
      if (results.length >= MAX_PER_ROUND) break;
    }
    if (cacheReapply.length > 0) {
      mutatingOwnDom = true;
      try {
        for (const item of cacheReapply) {
          item.node.nodeValue = item.node.nodeValue.replace(item.text, () => item.translation);
        }
      } finally {
        mutatingOwnDom = false;
      }
    }
    return results;
  }

  function translateChunk(texts, sourceLanguage) {
    return new Promise((resolve) => {
      chrome.runtime.sendMessage({ type: "translate", texts, sourceLanguage }, (response) => {
        if (chrome.runtime.lastError || !response || response.error) {
          resolve(null);
          return;
        }
        resolve({
          translations: response.translations || [],
          retry: Array.isArray(response.retry) ? response.retry : []
        });
      });
    });
  }

  function apply(segments, translations, retryIndexes) {
    const retry = new Set(retryIndexes || []);
    const writes = [];
    for (let i = 0; i < segments.length; i++) {
      const { item, index, source } = segments[i];
      const rawTranslation = translations[i];
      const translation = typeof rawTranslation === "string" ? rawTranslation.trim() : "";
      if (retry.has(i)) {
        item.retry = true;
      } else if (translation) {
        item.parts[index] = item.parts[index].replace(source, () => translation);
      }

      item.remaining--;
      if (item.remaining !== 0 || item.retry) continue;
      const entry = store.entries.get(item.id);
      const node = entry && entry.node;
      if (!node || !node.isConnected || textOf(node) !== item.text) continue;
      const translated = item.parts.join("");
      entry.source = item.text;
      entry.translation = translated === item.text ? null : translated;
      if (entry.translation) {
        writes.push({ node, original: item.text, translated });
      }
    }
    if (writes.length > 0) {
      mutatingOwnDom = true;
      try {
        for (const w of writes) {
          w.node.nodeValue = w.node.nodeValue.replace(w.original, () => w.translated);
        }
      } finally {
        mutatingOwnDom = false;
      }
    }
  }

  function restoreAll() {
    mutatingOwnDom = true;
    try {
      for (const [id, entry] of store.entries) {
        const node = entry && entry.node;
        if (!node || !node.isConnected) {
          store.entries.delete(id);
          continue;
        }
        if (entry.source && entry.translation && textOf(node) === entry.translation) {
          node.nodeValue = node.nodeValue.replace(entry.translation, () => entry.source);
        }
      }
    } finally {
      mutatingOwnDom = false;
    }
  }

  async function run() {
    if (!enabled || running) return;
    if (document.visibilityState !== "visible") return;
    running = true;
    try {
      for (let round = 0; round < MAX_ROUNDS; round++) {
        if (!enabled || document.visibilityState !== "visible") break;
        const sourceLanguage = pageLanguage();
        const segments = extract(sourceLanguage);
        if (segments.length === 0) break;
        for (let offset = 0; offset < segments.length; offset += CHUNK_SIZE) {
          const chunk = segments.slice(offset, offset + CHUNK_SIZE);
          const result = await translateChunk(chunk.map((segment) => segment.source), sourceLanguage);
          if (!enabled || document.visibilityState !== "visible") return;
          if (!result) {
            retryPending = true;
            return;
          }
          apply(chunk, result.translations, result.retry);
          if (result.retry.length > 0) {
            retryPending = true;
          }
        }
      }
      if (!retryPending) retryDelay = RETRY_INITIAL_MS;
    } finally {
      running = false;
      if (retryPending && enabled && document.visibilityState === "visible") {
        retryPending = false;
        scheduleRetry();
      }
    }
  }

  function scheduleRun() {
    if (mutatingOwnDom || !enabled) return;
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(run, OBSERVER_DEBOUNCE_MS);
  }

  function scheduleRetry() {
    if (!enabled || retryTimer) return;
    const delay = retryDelay;
    retryDelay = Math.min(retryDelay * 2, RETRY_MAX_MS);
    retryTimer = setTimeout(() => {
      retryTimer = null;
      if (running) {
        retryPending = true;
        return;
      }
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
    retryPending = false;
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
      restoreAll();
    }
  });

  document.addEventListener("visibilitychange", () => {
    if (!enabled || document.visibilityState !== "visible") return;
    retryDelay = RETRY_INITIAL_MS;
    scheduleRun();
  });
})();
