// Global Translator Bridge — content script.
// Extracts visible text nodes in any language, asks the desktop app (via the
// background worker) for translations and replaces the DOM text in place.
// Restores original source text immediately when toggled off.
(() => {
  const SKIPPED_TAGS = new Set([
    "SCRIPT", "STYLE", "NOSCRIPT", "CODE", "PRE", "TEXTAREA",
    "SVG", "MATH", "CANVAS", "VIDEO", "AUDIO", "IFRAME",
    "KBD", "SAMP", "VAR", "OPTION"
  ]);
  const ICON_CLASS_RE = /(?:^|\s)(?:material-icons(?:-[\w-]+)?|material-symbols(?:-[\w-]+)?|google-symbols|google-material-icons|fa|fas|far|fab|fal|fad|fa-[\w-]+|codicon|codicon-[\w-]+|iconfont|icon-font|ri-[\w-]+|bi|bi-[\w-]+|ti-[\w-]+|lucide|lucide-[\w-]+|anticon|el-icon[\w-]*|glyphicon[\w-]*|ion-[\w-]+|feather-[\w-]+|octicon[\w-]*|svg-inline--fa)(?:\s|$)/i;
  const ICON_LIGATURE_TEXT_RE = /^[a-z0-9_ -]{1,32}$/i;
  const NO_TRANSLATE_SELECTOR = '[translate="no"], [translate="NO"], .notranslate, [data-notranslate]';
  // Keep this aligned with TranslationCoordinator.localPageTextBatchSize.
  const CHUNK_SIZE = 3;
  const MAX_PER_ROUND = 200;
  const MAX_ROUNDS = 5;
  const OBSERVER_DEBOUNCE_MS = 800;
  const RETRY_INITIAL_MS = 1500;
  const RETRY_MAX_MS = 15000;
  const MAX_TEXT_CACHE = 2000;

  // id -> { node, source, translation, retryUntil }
  const store = { entries: new Map(), next: 0 };
  const nodeIds = typeof WeakMap !== "undefined" ? new WeakMap() : null;
  const textCache = new Map();
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

  function cacheGet(key) {
    if (!textCache.has(key)) return undefined;
    const value = textCache.get(key);
    textCache.delete(key);
    textCache.set(key, value);
    return value;
  }

  function cacheSet(key, value) {
    if (typeof value !== "string" || !value) return;
    if (textCache.has(key)) {
      textCache.delete(key);
    } else if (textCache.size >= MAX_TEXT_CACHE) {
      const oldest = textCache.keys().next().value;
      if (oldest !== undefined) textCache.delete(oldest);
    }
    textCache.set(key, value);
  }

  function drainOwnMutations() {
    if (observer && typeof observer.takeRecords === "function") {
      try { observer.takeRecords(); } catch (_error) {}
    }
  }

  function pageLanguage() {
    return GlobalTranslatorTextFilter.normalizeSourceLanguage(
      (document.documentElement && document.documentElement.lang) || ""
    );
  }

  function hasIconClass(element) {
    if (!element) return false;
    const rawClass = typeof element.className === "string"
      ? element.className
      : (element.getAttribute ? element.getAttribute("class") : "");
    return typeof rawClass === "string" && rawClass.length > 0 && ICON_CLASS_RE.test(rawClass);
  }

  function isNoTranslateElement(element) {
    if (!element) return false;
    if (element.translate === false) return true;
    if (element.getAttribute) {
      const translateAttr = String(element.getAttribute("translate") || "").toLowerCase();
      if (translateAttr === "no") return true;
    }
    if (element.classList && element.classList.contains("notranslate")) return true;
    return Boolean(element.closest && element.closest(NO_TRANSLATE_SELECTOR));
  }

  function isAriaHiddenIconElement(element, text) {
    if (!element || !element.getAttribute) return false;
    if (element.getAttribute("aria-hidden") !== "true") return false;
    const sample = String(text || (element.textContent || "")).trim();
    if (!sample) return true;
    if (/[\u3400-\u9FFF\u3040-\u30FF\u1100-\u11FF\uAC00-\uD7AF]/.test(sample)) return false;
    if (!ICON_LIGATURE_TEXT_RE.test(sample)) return false;
    const words = sample.split(/\s+/).filter(Boolean);
    return words.length <= 2;
  }

  function shouldSkipElement(element, text) {
    if (!element) return true;
    if (SKIPPED_TAGS.has(element.tagName)) return true;
    if (element.isContentEditable) return true;
    if (isNoTranslateElement(element)) return true;
    if (hasIconClass(element)) return true;
    if (isAriaHiddenIconElement(element, text)) return true;
    if (element.closest && element.closest('[contenteditable="true"], [contenteditable=""]')) return true;
    if (element.closest && element.closest("[data-gt-video-translate], .ytp-caption-window-container, .ytp-caption-segment, .caption-window")) return true;
    return false;
  }

  function measureEligibility(element) {
    const rect = element.getBoundingClientRect();
    if (rect.width < 4 || rect.height < 4) return null;
    const style = getComputedStyle(element);
    if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) return null;
    if (typeof GlobalTranslatorTextFilter.isIconFontFamily === "function" &&
        GlobalTranslatorTextFilter.isIconFontFamily(style.fontFamily)) {
      return null;
    }
    const vh = typeof window !== "undefined" ? (window.innerHeight || 0) : 0;
    const inViewport = vh <= 0 || (rect.bottom >= 0 && rect.top <= vh);
    return { inViewport };
  }

  function pruneDisconnectedEntries() {
    for (const [id, entry] of store.entries) {
      if (!entry.node || !entry.node.isConnected) {
        store.entries.delete(id);
      }
    }
  }

  function peekEntry(node) {
    if (nodeIds) {
      const existing = nodeIds.get(node);
      return existing ? store.entries.get(existing) || null : null;
    }
    for (const entry of store.entries.values()) {
      if (entry.node === node) return entry;
    }
    return null;
  }

  function nodeId(node) {
    if (nodeIds) {
      const existing = nodeIds.get(node);
      if (existing && store.entries.has(existing)) return existing;
      const id = String(store.next++);
      nodeIds.set(node, id);
      store.entries.set(id, { node, source: null, translation: null, retryUntil: 0 });
      return id;
    }
    for (const [id, entry] of store.entries) {
      if (entry.node === node) return id;
    }
    const id = String(store.next++);
    store.entries.set(id, { node, source: null, translation: null, retryUntil: 0 });
    return id;
  }

  function makeWalker(root) {
    const canFilterElements = typeof NodeFilter !== "undefined" &&
      typeof NodeFilter.SHOW_ELEMENT === "number" &&
      typeof NodeFilter.FILTER_REJECT === "number" &&
      typeof NodeFilter.FILTER_ACCEPT === "number" &&
      typeof NodeFilter.FILTER_SKIP === "number";
    if (!canFilterElements) {
      return document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    }
    return document.createTreeWalker(
      root,
      NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
      {
        acceptNode(node) {
          if (node.nodeType === 1) {
            if (SKIPPED_TAGS.has(node.tagName) || node.isContentEditable || isNoTranslateElement(node) || hasIconClass(node)) {
              return NodeFilter.FILTER_REJECT;
            }
            if (node.hasAttribute && (node.hasAttribute("data-gt-video-translate") || node.hasAttribute("contenteditable"))) {
              const ce = node.getAttribute("contenteditable");
              if (node.hasAttribute("data-gt-video-translate") || ce === "true" || ce === "") {
                return NodeFilter.FILTER_REJECT;
              }
            }
            if (
              node.classList &&
              (node.classList.contains("ytp-caption-window-container") ||
                node.classList.contains("ytp-caption-segment") ||
                node.classList.contains("caption-window"))
            ) {
              return NodeFilter.FILTER_REJECT;
            }
            return NodeFilter.FILTER_SKIP;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
      }
    );
  }

  // Two-phase extract: read DOM & collect cached re-applications first, then
  // write all cached translations in one batch so reads and writes never interleave.
  function extract(sourceLanguage) {
    const now = Date.now();
    const viewportResults = [];
    const deferredResults = [];
    const cacheReapply = [];
    const samples = [];
    const root = document.body || document.documentElement;
    if (!root) return [];
    const walker = makeWalker(root);
    let node;
    while ((node = walker.nextNode())) {
      const text = textOf(node);
      if (text.length < 2) continue;
      const existingEntry = peekEntry(node);
      if (samples.length < 60 && !shouldSkipElement(node.parentElement, text)) {
        const sampleText = existingEntry && existingEntry.translation === text && existingEntry.source
          ? existingEntry.source
          : text;
        samples.push(sampleText);
      }
      if (existingEntry) {
        if (existingEntry.translation === text) continue;
        if (existingEntry.source === text && existingEntry.translation) {
          cacheReapply.push({ node, text, translation: existingEntry.translation });
          continue;
        }
        if (existingEntry.source === text) continue;
        if (existingEntry.retryUntil && now < existingEntry.retryUntil) continue;
      }
      if (shouldSkipElement(node.parentElement, text)) continue;

      const parts = text.split(/(\r\n|[\n\r\u2028\u2029])/);
      const segments = [];
      for (let index = 0; index < parts.length; index += 2) {
        const source = parts[index].trim();
        if (GlobalTranslatorTextFilter.shouldSendForPageTranslate(source, sourceLanguage)) {
          segments.push({ index, source });
        }
      }
      if (segments.length === 0) continue;

      const layout = measureEligibility(node.parentElement);
      if (!layout) continue;

      const id = nodeId(node);
      const entry = store.entries.get(id);
      let allCached = true;
      for (let i = 0; i < segments.length; i++) {
        const cached = cacheGet((sourceLanguage || "") + "\0" + segments[i].source);
        if (!cached) {
          allCached = false;
          break;
        }
      }
      if (allCached) {
        for (let i = 0; i < segments.length; i++) {
          const seg = segments[i];
          const cached = cacheGet((sourceLanguage || "") + "\0" + seg.source);
          parts[seg.index] = parts[seg.index].replace(seg.source, () => cached);
        }
        const translated = parts.join("");
        entry.source = text;
        entry.translation = translated === text ? null : translated;
        entry.retryUntil = 0;
        if (entry.translation) {
          cacheReapply.push({ node, text, translation: entry.translation });
        }
        continue;
      }

      const item = { id, text, parts, remaining: segments.length, retry: false };
      const target = layout.inViewport ? viewportResults : deferredResults;
      for (const segment of segments) {
        target.push({ item, ...segment });
      }
      if (viewportResults.length >= MAX_PER_ROUND) break;
    }
    if (typeof GlobalTranslatorTextFilter.isLikelySimplifiedChinesePage === "function" &&
        GlobalTranslatorTextFilter.isLikelySimplifiedChinesePage(samples, sourceLanguage)) {
      return [];
    }
    if (cacheReapply.length > 0) {
      mutatingOwnDom = true;
      try {
        for (const item of cacheReapply) {
          item.node.nodeValue = item.node.nodeValue.replace(item.text, () => item.translation);
        }
      } finally {
        drainOwnMutations();
        mutatingOwnDom = false;
      }
    }
    if (viewportResults.length >= MAX_PER_ROUND) {
      return viewportResults.slice(0, MAX_PER_ROUND);
    }
    const remainingCapacity = MAX_PER_ROUND - viewportResults.length;
    return viewportResults.concat(deferredResults.slice(0, remainingCapacity));
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

  function apply(segments, translations, retryIndexes, sourceLanguage) {
    const retry = new Set(retryIndexes || []);
    const writes = [];
    for (let i = 0; i < segments.length; i++) {
      const { item, index, source } = segments[i];
      const rawTranslation = translations[i];
      const translation = typeof rawTranslation === "string" ? rawTranslation.trim() : "";
      if (retry.has(i)) {
        item.retry = true;
      } else if (translation) {
        if (sourceLanguage !== undefined) {
          cacheSet((sourceLanguage || "") + "\0" + source, translation);
        } else {
          cacheSet("\0" + source, translation);
        }
        item.parts[index] = item.parts[index].replace(source, () => translation);
      }

      item.remaining--;
      if (item.remaining !== 0) continue;
      const entry = store.entries.get(item.id);
      if (item.retry) {
        if (entry) entry.retryUntil = Date.now() + Math.max(0, retryDelay - 50);
        continue;
      }
      const node = entry && entry.node;
      if (!node || !node.isConnected || textOf(node) !== item.text) continue;
      const translated = item.parts.join("");
      entry.source = item.text;
      entry.translation = translated === item.text ? null : translated;
      entry.retryUntil = 0;
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
        drainOwnMutations();
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
      drainOwnMutations();
      mutatingOwnDom = false;
    }
  }

  async function translateChunkDedup(chunk, sourceLanguage) {
    const uniqueTexts = [];
    const slotMap = new Map();
    const indices = new Array(chunk.length);
    for (let i = 0; i < chunk.length; i++) {
      const src = chunk[i].source;
      let idx = slotMap.get(src);
      if (idx === undefined) {
        idx = uniqueTexts.length;
        uniqueTexts.push(src);
        slotMap.set(src, idx);
      }
      indices[i] = idx;
    }
    const result = await translateChunk(uniqueTexts, sourceLanguage);
    if (!result) return null;
    const retrySet = new Set(result.retry || []);
    const expandedTranslations = new Array(chunk.length);
    const expandedRetry = [];
    for (let i = 0; i < chunk.length; i++) {
      const idx = indices[i];
      if (retrySet.has(idx)) {
        expandedTranslations[i] = "";
        expandedRetry.push(i);
      } else {
        expandedTranslations[i] = result.translations[idx];
      }
    }
    return { translations: expandedTranslations, retry: expandedRetry };
  }

  async function run() {
    if (!enabled || running) return;
    if (document.visibilityState !== "visible") return;
    running = true;
    try {
      pruneDisconnectedEntries();
      for (let round = 0; round < MAX_ROUNDS; round++) {
        if (!enabled || document.visibilityState !== "visible") break;
        const sourceLanguage = pageLanguage();
        const segments = extract(sourceLanguage);
        if (segments.length === 0) break;
        for (let offset = 0; offset < segments.length; offset += CHUNK_SIZE) {
          const chunk = segments.slice(offset, offset + CHUNK_SIZE);
          const result = await translateChunkDedup(chunk, sourceLanguage);
          if (!enabled || document.visibilityState !== "visible") return;
          if (!result) {
            retryPending = true;
            return;
          }
          apply(chunk, result.translations, result.retry, sourceLanguage);
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
