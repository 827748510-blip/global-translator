// Relays translation requests from content scripts to the desktop app's
// loopback bridge. Runs in the extension origin, so page CSP never applies;
// the app authenticates us by this extension's stable chrome-extension://
// origin (pinned via the manifest key).
const ENDPOINT = "http://127.0.0.1:9233";

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== "object") return false;
  if (message.type === "translate" && Array.isArray(message.texts)) {
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
      .catch((error) => sendResponse({ error: String(error) }));
    return true; // async sendResponse
  }
  if (message.type === "ping") {
    // POST so Chrome attaches `Origin: chrome-extension://<id>` — the app
    // rejects origin-less GETs, which is exactly what a plain fetch is.
    fetch(ENDPOINT + "/health", { method: "POST" })
      .then((response) => sendResponse({ ok: response.ok }))
      .catch(() => sendResponse({ ok: false }));
    return true;
  }
  return false;
});
