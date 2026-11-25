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
const bridgeQueue = GlobalTranslatorBridgeQueue.createBridgeQueue();

function enqueueBridgeFetch(work, lane) {
  return bridgeQueue.enqueue(work, lane);
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
    const pageOrigin = extractPageOrigin(sender);
    const bodyObject = { texts: message.texts, sourceLanguage: message.sourceLanguage };
    if (pageOrigin) bodyObject.pageOrigin = pageOrigin;
    enqueueBridgeFetch(() =>
      fetch(ENDPOINT + "/translate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(bodyObject)
      })
        .then(async (response) => {
          if (!response.ok) {
            sendResponse({ error: "http " + response.status });
            return;
          }
          const payload = await response.json();
          sendResponse({
            translations: payload.translations || [],
            retry: Array.isArray(payload.retry) ? payload.retry : []
          });
        })
        .catch((error) => sendResponse({ error: String(error) })),
    lane);
    return true; // async sendResponse
  }
  if (message.type === "ping") {
    // POST so Chrome attaches `Origin: chrome-extension://<id>` — the app
    // rejects origin-less GETs, which is exactly what a plain fetch is.
    // Health does not touch Ollama/DeepSeek; never queue it behind page or
    // video /translate or Chrome's sendResponse channel times out.
    fetch(ENDPOINT + "/health", { method: "POST" })
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
        sendResponse({
          ok: response.ok,
          videoTranslateEnabled,
          autoTranslateEnabled,
          backendReady,
          blockedReason,
          videoAsrStatus
        });
      })
      .catch(() => sendResponse({
        ok: false,
        videoTranslateEnabled: false,
        autoTranslateEnabled: false,
        backendReady: false,
        blockedReason: "",
        videoAsrStatus: "idle"
      }));
    return true;
  }
  if (message.type === "set-video-translate") {
    const enabled = message.enabled === true;
    fetch(ENDPOINT + "/video-translate", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled })
    })
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
    fetch(ENDPOINT + "/video-asr", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ needed })
    })
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
