// Relays translation requests from content scripts to the desktop app's
// loopback bridge. Runs in the extension origin, so page CSP never applies;
// the app authenticates us by this extension's stable chrome-extension://
// origin (pinned via the manifest key).
importScripts("bridge-queue.js");

const ENDPOINT = "http://127.0.0.1:9233";

// One in-flight loopback call at a time. Multiple tabs (or ping overlapping
// a translate) used to POST concurrently; the Mac app then raced window
// overlay + bridge on the same local Ollama process. Video-cue translates
// use lane "video" so they jump ahead of queued whole-page batches.
const TRANSLATE_TIMEOUT_MS = 120000;
const CONTROL_TIMEOUT_MS = 5000;
const MAX_CACHE_ENTRIES = 2000;

const bridgeQueue = GlobalTranslatorBridgeQueue.createBridgeQueue({ maxSize: 64 });
const translationCache = new Map();
const inFlightTranslations = new Map();

function enqueueBridgeFetch(work, lane, tabId) {
  return bridgeQueue.enqueue(work, lane, tabId);
}

function fetchWithTimeout(url, options, timeoutMs) {
  if (typeof AbortController !== "function" || typeof setTimeout !== "function") {
    return fetch(url, options);
  }
  const controller = new AbortController();
  const timer = setTimeout(() => {
    try { controller.abort(); } catch (_error) {}
  }, timeoutMs);
  const nextOptions = Object.assign({}, options, { signal: controller.signal });
  return fetch(url, nextOptions).finally(() => {
    if (typeof clearTimeout === "function") clearTimeout(timer);
  });
}

function cacheKey(pageOrigin, sourceLanguage, text) {
  return (pageOrigin || "") + "\0" + (sourceLanguage || "") + "\0" + text;
}

function cacheGet(key) {
  if (!translationCache.has(key)) return undefined;
  const value = translationCache.get(key);
  translationCache.delete(key);
  translationCache.set(key, value);
  return value;
}

function cacheSet(key, value) {
  if (typeof value !== "string" || !value) return;
  if (translationCache.has(key)) {
    translationCache.delete(key);
  } else if (translationCache.size >= MAX_CACHE_ENTRIES) {
    const oldestKey = translationCache.keys().next().value;
    if (oldestKey !== undefined) translationCache.delete(oldestKey);
  }
  translationCache.set(key, value);
}

function clearTranslationCache() {
  translationCache.clear();
}

if (typeof chrome !== "undefined" && chrome.tabs) {
  if (chrome.tabs.onRemoved && typeof chrome.tabs.onRemoved.addListener === "function") {
    chrome.tabs.onRemoved.addListener((tabId) => {
      bridgeQueue.cancelByTab(tabId);
    });
  }
  if (chrome.tabs.onUpdated && typeof chrome.tabs.onUpdated.addListener === "function") {
    chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
      if (changeInfo && changeInfo.url) {
        bridgeQueue.cancelByTab(tabId);
      }
    });
  }
}

function extractPageOrigin(sender) {
  const rawUrl = sender && (sender.url || (sender.tab && sender.tab.url));
  if (typeof rawUrl !== "string" || !rawUrl) return null;
  if (typeof URL === "function") {
    try {
      const parsed = new URL(rawUrl);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
      if (!parsed.origin || parsed.origin === "null") return null;
      return parsed.origin;
    } catch (_error) {
      return null;
    }
  }
  const match = /^(https?):\/\/([^/?#@]+)(?:[/?#]|$)/i.exec(rawUrl);
  return match ? `${match[1].toLowerCase()}://${match[2].toLowerCase()}` : null;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== "object") return false;
  if (message.type === "translate" && Array.isArray(message.texts)) {
    const lane = message.lane === "video" ? "video" : "page";
    const tabId = sender && sender.tab && typeof sender.tab.id === "number" ? sender.tab.id : null;
    const pageOrigin = extractPageOrigin(sender);
    const sourceLanguage = message.sourceLanguage;
    const texts = message.texts;
    const cachedTranslations = new Array(texts.length);
    const missingTexts = [];
    const missingSlots = [];
    const missingMap = new Map();

    for (let i = 0; i < texts.length; i++) {
      const text = texts[i];
      const key = typeof text === "string" ? cacheGet(cacheKey(pageOrigin, sourceLanguage, text)) : undefined;
      if (key !== undefined) {
        cachedTranslations[i] = key;
      } else {
        let dedupIndex = typeof text === "string" ? missingMap.get(text) : undefined;
        if (dedupIndex === undefined) {
          dedupIndex = missingTexts.length;
          missingTexts.push(text);
          if (typeof text === "string") missingMap.set(text, dedupIndex);
        }
        missingSlots.push({ originalIndex: i, missingIndex: dedupIndex });
      }
    }

    if (missingTexts.length === 0) {
      sendResponse({ translations: cachedTranslations, retry: [] });
      return true;
    }

    const batchKey = cacheKey(pageOrigin, sourceLanguage, missingTexts.join("\u0001"));
    let batchPromise = inFlightTranslations.get(batchKey);
    if (!batchPromise) {
      const bodyObject = { texts: missingTexts, sourceLanguage };
      if (pageOrigin) bodyObject.pageOrigin = pageOrigin;
      batchPromise = enqueueBridgeFetch(() =>
        fetchWithTimeout(ENDPOINT + "/translate", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(bodyObject)
        }, TRANSLATE_TIMEOUT_MS)
          .then(async (response) => {
            if (!response.ok) {
              return { error: "http " + response.status };
            }
            const payload = await response.json();
            const translations = Array.isArray(payload.translations) ? payload.translations : [];
            const batchResult = {
              translations,
              retry: Array.isArray(payload.retry) ? payload.retry : []
            };
            const retrySet = new Set(batchResult.retry);
            for (let i = 0; i < missingTexts.length; i++) {
              if (!retrySet.has(i) && typeof missingTexts[i] === "string" && typeof translations[i] === "string" && translations[i]) {
                cacheSet(cacheKey(pageOrigin, sourceLanguage, missingTexts[i]), translations[i]);
              }
            }
            return batchResult;
          })
          .catch((error) => ({ error: String(error) })),
      lane, tabId)
        .catch((error) => ({ error: String(error) }))
        .finally(() => {
          inFlightTranslations.delete(batchKey);
        });
      inFlightTranslations.set(batchKey, batchPromise);
    }

    batchPromise.then((result) => {
      if (!result || result.error) {
        sendResponse({ error: (result && result.error) || "bridge error" });
        return;
      }
      const out = cachedTranslations.slice();
      const outRetry = [];
      const retrySet = new Set(result.retry || []);
      for (let i = 0; i < missingSlots.length; i++) {
        const slot = missingSlots[i];
        if (retrySet.has(slot.missingIndex)) {
          out[slot.originalIndex] = "";
          outRetry.push(slot.originalIndex);
        } else {
          const translated = result.translations[slot.missingIndex];
          out[slot.originalIndex] = typeof translated === "string" ? translated : "";
        }
      }
      sendResponse({ translations: out, retry: outRetry });
    });
    return true; // async sendResponse
  }
  if (message.type === "ping") {
    // POST so Chrome attaches `Origin: chrome-extension://<id>` — the app
    // rejects origin-less GETs, which is exactly what a plain fetch is.
    // Health does not touch Ollama/DeepSeek; never queue it behind page or
    // video /translate or Chrome's sendResponse channel times out.
    fetchWithTimeout(ENDPOINT + "/health", { method: "POST" }, CONTROL_TIMEOUT_MS)
      .then(async (response) => {
        let videoTranslateEnabled = false;
        let autoTranslateEnabled = false;
        let backendReady = false;
        let blockedReason = "";
        let videoAsrStatus = "idle";
        try {
          const payload = await response.json();
          videoTranslateEnabled = payload.videoTranslateEnabled === true;
          autoTranslateEnabled = payload.autoTranslateEnabled === true;
          backendReady = payload.backendReady === true;
          blockedReason = typeof payload.blockedReason === "string" ? payload.blockedReason : "";
          videoAsrStatus = typeof payload.videoAsrStatus === "string" ? payload.videoAsrStatus : "idle";
        } catch (_error) {}
        if (!response.ok || !backendReady) {
          clearTranslationCache();
        }
        sendResponse({
          ok: response.ok,
          videoTranslateEnabled,
          autoTranslateEnabled,
          backendReady,
          blockedReason,
          videoAsrStatus
        });
      })
      .catch(() => {
        clearTranslationCache();
        sendResponse({
          ok: false,
          videoTranslateEnabled: false,
          autoTranslateEnabled: false,
          backendReady: false,
          blockedReason: "",
          videoAsrStatus: "idle"
        });
      });
    return true;
  }
  if (message.type === "set-video-translate") {
    const enabled = message.enabled === true;
    fetchWithTimeout(ENDPOINT + "/video-translate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled })
    }, CONTROL_TIMEOUT_MS)
      .then(async (response) => {
        if (!response.ok) {
          sendResponse({ ok: false, videoTranslateEnabled: !enabled, error: "http " + response.status });
          return;
        }
        const payload = await response.json();
        sendResponse({
          ok: payload.ok !== false,
          videoTranslateEnabled: payload.videoTranslateEnabled === true
        });
      })
      .catch((error) => sendResponse({ ok: false, videoTranslateEnabled: !enabled, error: String(error) }));
    return true;
  }
  if (message.type === "video-asr") {
    const needed = message.needed === true;
    if (needed && sender && sender.tab) {
      const tab = sender.tab;
      const muted = Boolean(tab.mutedInfo && tab.mutedInfo.muted === true);
      if (tab.active === false || tab.audible === false || muted || !extractPageOrigin(sender)) {
        sendResponse({
          ok: true,
          enabled: false,
          needed: false,
          running: false,
          status: "idle",
          message: "",
          cues: []
        });
        return true;
      }
    }
    fetchWithTimeout(ENDPOINT + "/video-asr", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ needed })
    }, CONTROL_TIMEOUT_MS)
      .then(async (response) => {
        if (!response.ok) {
          sendResponse({ error: "http " + response.status, status: "error" });
          return;
        }
        const payload = await response.json();
        sendResponse(payload);
      })
      .catch((error) => sendResponse({ error: String(error), status: "error" }));
    return true;
  }
  return false;
});
