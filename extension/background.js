// Relays translation requests from content scripts to the desktop app's
// loopback bridge. Runs in the extension origin, so page CSP never applies;
// the app authenticates us by this extension's stable chrome-extension://
// origin (pinned via the manifest key).
const ENDPOINT = "http://127.0.0.1:9233";

// One in-flight loopback call at a time. Multiple tabs (or ping overlapping
// a translate) used to POST concurrently; the Mac app then raced window
// overlay + bridge on the same local Ollama process.
let bridgeChain = Promise.resolve();

function enqueueBridgeFetch(work) {
  const run = bridgeChain.then(work, work);
  bridgeChain = run.then(() => undefined, () => {});
  return run;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== "object") return false;
  if (message.type === "translate" && Array.isArray(message.texts)) {
    enqueueBridgeFetch(() =>
      fetch(ENDPOINT + "/translate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ texts: message.texts })
      })
        .then(async (response) => {
          if (!response.ok) {
            sendResponse({ error: "http " + response.status });
            return;
          }
          const payload = await response.json();
          sendResponse({ translations: payload.translations || [] });
        })
        .catch((error) => sendResponse({ error: String(error) }))
    );
    return true; // async sendResponse
  }
  if (message.type === "ping") {
    // POST so Chrome attaches `Origin: chrome-extension://<id>` — the app
    // rejects origin-less GETs, which is exactly what a plain fetch is.
    enqueueBridgeFetch(() =>
      fetch(ENDPOINT + "/health", { method: "POST" })
        .then((response) => sendResponse({ ok: response.ok }))
        .catch(() => sendResponse({ ok: false }))
    );
    return true;
  }
  return false;
});
