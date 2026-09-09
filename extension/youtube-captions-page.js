// Phase B1 page-world observer for YouTube. Runs in MAIN world at
// document_start so in-session /api/timedtext can be cloned after the
// player already requested it. Never constructs timedtext URLs, never
// copies PoToken, never clicks CC, never turns captions on via the player.
(() => {
  if (window.__gtYoutubeCaptionsPage) return;
  window.__gtYoutubeCaptionsPage = true;

  const SOURCE_PAGE = "gt-youtube-captions";
  const SOURCE_ISOLATED = "gt-youtube-captions-isolated";
  const origin = location.origin;
  let lastTimedText = null;
  let lastVideoId = "";
  let relay = false;

  function post(kind, payload) {
    try {
      window.postMessage({ source: SOURCE_PAGE, kind, body: payload && payload.body, fmtHint: payload && payload.fmtHint, videoId: payload && payload.videoId }, origin);
    } catch (_error) {}
  }

  function isTimedTextUrl(url) {
    return /\/api\/timedtext(?:\?|$|#)/i.test(String(url || ""));
  }

  function hrefOf(input) {
    if (typeof input === "string") return input;
    if (input && typeof input.url === "string") return input.url;
    return "";
  }

  function fmtHintFromUrl(url) {
    const match = String(url || "").match(/[?&]fmt=([a-z0-9]+)/i);
    return match ? match[1].toLowerCase() : "";
  }

  function currentVideoId() {
    try {
      const url = new URL(location.href);
      const queryId = url.searchParams.get("v");
      if (queryId) return queryId;
      const shorts = url.pathname.match(/\/shorts\/([A-Za-z0-9_-]{6,})/);
      if (shorts) return shorts[1];
      const embed = url.pathname.match(/\/embed\/([A-Za-z0-9_-]{6,})/);
      if (embed) return embed[1];
      const live = url.pathname.match(/\/live\/([A-Za-z0-9_-]{6,})/);
      if (live) return live[1];
    } catch (_error) {}
    return "";
  }

  function rememberTimedText(body, fmtHint) {
    if (typeof body !== "string" || !body) return;
    lastTimedText = { body, fmtHint: fmtHint || "" };
    if (relay) post("timedtext", lastTimedText);
  }

  function replay() {
    if (lastTimedText) post("timedtext", lastTimedText);
    const videoId = currentVideoId();
    if (videoId) post("navigate", { videoId });
  }

  function wrapFetch() {
    const origFetch = window.fetch;
    if (typeof origFetch !== "function") return;
    window.fetch = function (input, init) {
      const promise = origFetch.apply(this, arguments);
      try {
        const href = hrefOf(input);
        if (isTimedTextUrl(href)) {
          const hint = fmtHintFromUrl(href);
          promise.then((response) => {
            try {
              if (!response || typeof response.clone !== "function") return;
              response.clone().text().then((body) => {
                rememberTimedText(body, hint);
              }).catch(() => {});
            } catch (_error) {}
          }).catch(() => {});
        }
      } catch (_error) {}
      return promise;
    };
  }

  function wrapXHR() {
    const XHR = window.XMLHttpRequest;
    if (!XHR || !XHR.prototype) return;
    const origOpen = XHR.prototype.open;
    const origSend = XHR.prototype.send;
    if (typeof origOpen !== "function" || typeof origSend !== "function") return;
    XHR.prototype.open = function (method, url) {
      try {
        this.__gtIsTimedText = isTimedTextUrl(url);
        this.__gtTimedTextHint = this.__gtIsTimedText ? fmtHintFromUrl(url) : "";
      } catch (_error) {
        this.__gtIsTimedText = false;
      }
      return origOpen.apply(this, arguments);
    };
    XHR.prototype.send = function () {
      if (this.__gtIsTimedText) {
        this.addEventListener("load", function () {
          try {
            const body = this.responseText;
            if (typeof body === "string" && body) {
              rememberTimedText(body, this.__gtTimedTextHint || fmtHintFromUrl(this.responseURL));
            }
          } catch (_error) {}
        });
      }
      return origSend.apply(this, arguments);
    };
  }

  function emitNavigate() {
    const videoId = currentVideoId();
    if (videoId === lastVideoId) return;
    lastVideoId = videoId;
    lastTimedText = null;
    post("navigate", { videoId });
  }

  wrapFetch();
  wrapXHR();

  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data || data.source !== SOURCE_ISOLATED) return;
    if (data.kind === "hello") {
      relay = true;
      replay();
    } else if (data.kind === "bye") {
      relay = false;
      lastTimedText = null;
    }
  });

  document.addEventListener("yt-navigate-finish", emitNavigate);
  window.addEventListener("yt-navigate-finish", emitNavigate);
})();
