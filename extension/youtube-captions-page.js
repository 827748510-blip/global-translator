// Phase B1 page-world observer for YouTube. Runs in MAIN world at
// document_start so in-session timedtext can be cloned after the
// player already requested it. Never constructs caption URLs, never
// copies PoToken, never clicks CC, never turns captions on via the player.
(() => {
  try {
    if (document.documentElement) {
      document.documentElement.setAttribute("data-gt-ytcap", "1");
    }
  } catch (_error) {}
  if (window.__gtYoutubeCaptionsPage) return;
  window.__gtYoutubeCaptionsPage = true;

  const SOURCE_PAGE = "gt-youtube-captions";
  const SOURCE_ISOLATED = "gt-youtube-captions-isolated";
  const origin = location.origin;
  let lastTimedText = null;
  let lastVideoId = "";
  let relay = false;
  let liveTimer = null;
  let lastEmittedLiveText = "";
  let lastEmittedLiveTime = -1;

  function post(kind, payload) {
    try {
      window.postMessage({
        source: SOURCE_PAGE,
        kind,
        body: payload && payload.body,
        fmtHint: payload && payload.fmtHint,
        videoId: payload && payload.videoId,
        time: payload && payload.time
      }, origin);
    } catch (_error) {}
  }

  function isTimedTextUrl(url) {
    const value = String(url || "");
    if (!value || value.toLowerCase().indexOf("timedtext") === -1) return false;
    if (/timedtext_video/i.test(value)) return false;
    if (/\/api\/timedtext(?:\?|$|#)/i.test(value)) return true;
    return /\/timedtext(?:\?|$|#)/i.test(value);
  }

  function hrefOf(input) {
    if (typeof input === "string") return input;
    if (input && typeof input.url === "string") return input.url;
    if (typeof URL !== "undefined" && input instanceof URL) return String(input);
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

  function collectCaptionText(root) {
    function collect(node, selector) {
      const parts = [];
      if (!node || !node.querySelectorAll) return parts;
      const containers = node.querySelectorAll(".ytp-caption-window-container, .caption-window, .ytp-caption-window-bottom, .html5-video-player, ytd-player");
      const scopes = containers.length > 0 ? containers : [node];
      for (let s = 0; s < scopes.length; s++) {
        const scopeTarget = scopes[s];
        if (!scopeTarget || !scopeTarget.querySelectorAll) continue;
        const nodes = scopeTarget.querySelectorAll(selector);
        for (let i = 0; i < nodes.length; i++) {
          const text = String(nodes[i].textContent || "").replace(/\s+/g, " ").trim();
          if (text && parts[parts.length - 1] !== text) parts.push(text);
        }
        if (scopeTarget.shadowRoot && scopeTarget.shadowRoot.querySelectorAll) {
          const shadowNodes = scopeTarget.shadowRoot.querySelectorAll(selector);
          for (let i = 0; i < shadowNodes.length; i++) {
            const text = String(shadowNodes[i].textContent || "").replace(/\s+/g, " ").trim();
            if (text && parts[parts.length - 1] !== text) parts.push(text);
          }
        }
      }
      return parts;
    }
    const scope = root || document;
    const segments = collect(scope, ".ytp-caption-segment");
    if (segments.length > 0) return segments.join(" ");
    const lines = collect(scope, ".caption-visual-line");
    if (lines.length > 0) return lines.join(" ");
    const container = scope.querySelector &&
      scope.querySelector(".ytp-caption-window-container, .caption-window");
    return container ? String(container.textContent || "").replace(/\s+/g, " ").trim() : "";
  }

  function primaryVideo() {
    const main = document.querySelector("video.html5-main-video");
    if (main) return main;
    const listed = document.querySelectorAll("video");
    let best = null;
    let area = 0;
    for (let i = 0; i < listed.length; i++) {
      const rect = listed[i].getBoundingClientRect();
      const nextArea = Math.max(0, rect.width) * Math.max(0, rect.height);
      if (nextArea > area) {
        area = nextArea;
        best = listed[i];
      }
    }
    return best || listed[0] || null;
  }

  function emitLive() {
    if (!relay) return;
    const text = collectCaptionText(document);
    const video = primaryVideo();
    const time = video ? video.currentTime : 0;
    if (text === lastEmittedLiveText && (!text || Math.abs(time - lastEmittedLiveTime) < 0.8)) {
      return;
    }
    lastEmittedLiveText = text;
    lastEmittedLiveTime = time;
    post("live", { body: text, time });
  }

  function scheduleLive() {
    if (!relay) return;
    if (liveTimer) return;
    liveTimer = setTimeout(() => {
      liveTimer = null;
      try { emitLive(); } catch (_error) {}
    }, 60);
  }

  function replay() {
    const videoId = currentVideoId();
    if (videoId) post("navigate", { videoId });
    if (lastTimedText) post("timedtext", lastTimedText);
    emitLive();
  }

  function wrapFetch() {
    const origFetch = window.fetch;
    if (typeof origFetch !== "function") return;
    window.fetch = function (input, init) {
      const promise = origFetch.apply(this, arguments);
      try {
        promise.then((response) => {
          try {
            const href = hrefOf(input) || (response && response.url) || "";
            const responseUrl = (response && response.url) || "";
            if (!isTimedTextUrl(href) && !isTimedTextUrl(responseUrl)) return;
            const hint = fmtHintFromUrl(href) || fmtHintFromUrl(responseUrl);
            if (!response || typeof response.clone !== "function") return;
            response.clone().text().then((body) => {
              rememberTimedText(body, hint);
            }).catch(() => {});
          } catch (_error) {}
        }).catch(() => {});
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
      if (!this.__gtCaptionBound) {
        this.__gtCaptionBound = true;
        this.addEventListener("load", function () {
          try {
            const responseUrl = this.responseURL || "";
            if (!this.__gtIsTimedText && !isTimedTextUrl(responseUrl)) return;
            const body = this.responseText;
            if (typeof body === "string" && body) {
              rememberTimedText(body, this.__gtTimedTextHint || fmtHintFromUrl(responseUrl));
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
    const previous = lastVideoId;
    lastVideoId = videoId;
    lastEmittedLiveText = "";
    lastEmittedLiveTime = -1;
    if (previous) lastTimedText = null;
    post("navigate", { videoId });
  }

  wrapFetch();
  wrapXHR();

  const domObserver = new MutationObserver(scheduleLive);

  function startDomObserver() {
    try {
      const target = document.querySelector(".ytp-caption-window-container, .html5-video-player, ytd-player")
        || document.body || document.documentElement;
      if (target) {
        domObserver.observe(target, { childList: true, subtree: true, characterData: true });
      }
    } catch (_error) {}
  }

  function stopDomObserver() {
    try { domObserver.disconnect(); } catch (_error) {}
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    if (event.origin !== location.origin) return;
    const data = event.data;
    if (!data || data.source !== SOURCE_ISOLATED) return;
    if (data.kind === "hello") {
      relay = true;
      startDomObserver();
      replay();
    } else if (data.kind === "bye") {
      relay = false;
      stopDomObserver();
      lastTimedText = null;
      lastEmittedLiveText = "";
      lastEmittedLiveTime = -1;
      if (liveTimer) {
        clearTimeout(liveTimer);
        liveTimer = null;
      }
    }
  });

  document.addEventListener("yt-navigate-finish", emitNavigate);
  window.addEventListener("yt-navigate-finish", emitNavigate);
})();
