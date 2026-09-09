// Video translation Phase B1 — YouTube caption reliability.
// Reads the local player's already-active captions (visible cue DOM) and
// in-session timedtext the page itself fetched after the user turned CC on.
// Never initiates a caption download, never sends PoToken, never enables CC,
// never captures audio. Speech capture / system ASR are Phase B2.
(function (root) {
  const Cues = root.GlobalTranslatorSubtitleCues;
  const SOURCE_PAGE = "gt-youtube-captions";
  const SOURCE_ISOLATED = "gt-youtube-captions-isolated";
  const YOUTUBE_PROBE_MS = 8000;

  const MESSAGES = Object.freeze({
    noYouTubeCaptions: "未检测到外语字幕（请先打开 YouTube 字幕）"
  });

  function isYouTubeHost(hostname) {
    const host = String(hostname || "").toLowerCase().replace(/\.$/, "");
    if (host === "youtu.be") return true;
    if (host === "youtube-nocookie.com" || host.endsWith(".youtube-nocookie.com")) return true;
    if (host === "youtube.com" || host.endsWith(".youtube.com")) {
      if (host === "studio.youtube.com" || host === "music.youtube.com" || host === "tv.youtube.com") {
        return false;
      }
      return true;
    }
    return false;
  }

  function currentVideoId(href) {
    try {
      const url = new URL(String(href || ""), "https://www.youtube.com");
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

  function isTimedTextUrl(url) {
    const value = String(url || "");
    if (!value || /timedtext_video/i.test(value)) return false;
    if (/\/api\/timedtext(?:\?|$|#)/i.test(value)) return true;
    return /\/timedtext(?:\?|$|#)/i.test(value);
  }

  function fmtHintFromUrl(url) {
    const match = String(url || "").match(/[?&]fmt=([a-z0-9]+)/i);
    return match ? match[1].toLowerCase() : "";
  }

  function sniffFmt(body, fmtHint) {
    const hint = String(fmtHint || "").toLowerCase();
    if (hint) return hint;
    const text = String(body || "").replace(/^\uFEFF/, "").trim();
    if (!text) return "";
    if (text.charAt(0) === "{" || text.charAt(0) === "[") return "json3";
    if (/^\s*WEBVTT\b/i.test(text)) return "vtt";
    if (/<transcript[\s>]/i.test(text) || /<text\b[^>]*\bstart=/i.test(text)) return "srv1";
    if (/<timedtext\b/i.test(text) || /<p\b[^>]*\bt="/i.test(text)) return "srv3";
    if (/<(?:tt|p)\b[^>]*\bbegin=/i.test(text)) return "ttml";
    return "";
  }

  function parseJson3(payload) {
    let data = payload;
    if (typeof payload === "string") {
      try {
        data = JSON.parse(String(payload).replace(/^\uFEFF/, "").replace(/^\)\]\}['"]?\s*/, ""));
      } catch (_error) {
        return [];
      }
    }
    const events = data && data.events;
    if (!Array.isArray(events)) return [];
    const raw = [];
    for (let i = 0; i < events.length; i++) {
      const event = events[i];
      if (!event || !Array.isArray(event.segs)) continue;
      let text = "";
      for (let j = 0; j < event.segs.length; j++) {
        text += (event.segs[j] && event.segs[j].utf8) || "";
      }
      const normalized = Cues ? Cues.normalizeCueText(text) : String(text).trim();
      if (!normalized) continue;
      raw.push({
        start: (Number(event.tStartMs) || 0) / 1000,
        duration: (Number(event.dDurationMs) || 0) / 1000,
        text: normalized
      });
    }
    const cues = [];
    for (let i = 0; i < raw.length; i++) {
      let end = raw[i].duration > 0 ? raw[i].start + raw[i].duration : 0;
      if (!(end > raw[i].start)) {
        const next = raw[i + 1];
        end = next ? next.start : raw[i].start + 2;
      }
      if (!(end > raw[i].start)) continue;
      cues.push({ start: raw[i].start, end, text: raw[i].text });
    }
    return cues;
  }

  function decodeXmlText(value) {
    const withoutCdata = String(value || "").replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1");
    return Cues ? Cues.normalizeCueText(withoutCdata) : withoutCdata.replace(/\s+/g, " ").trim();
  }

  function parseSrv1(xml) {
    const cues = [];
    const source = String(xml || "");
    const re = /<text\b([^>]*)>([\s\S]*?)<\/text>/gi;
    let match;
    while ((match = re.exec(source))) {
      const attrs = match[1];
      const start = Number((attrs.match(/\bstart="([^"]+)"/) || [])[1]);
      const dur = Number((attrs.match(/\bdur="([^"]+)"/) || [])[1]);
      const text = decodeXmlText(match[2]);
      if (!Number.isFinite(start) || !Number.isFinite(dur) || dur <= 0 || !text) continue;
      cues.push({ start, end: start + dur, text });
    }
    return cues;
  }

  function parseSrv3(xml) {
    const cues = [];
    const source = String(xml || "");
    const re = /<p\b([^>]*)>([\s\S]*?)<\/p>/gi;
    let match;
    while ((match = re.exec(source))) {
      const attrs = match[1];
      const startMs = Number((attrs.match(/\bt="([^"]+)"/) || [])[1]);
      const durMs = Number((attrs.match(/\bd="([^"]+)"/) || [])[1]);
      const text = decodeXmlText(match[2]);
      if (!Number.isFinite(startMs) || !Number.isFinite(durMs) || durMs <= 0 || !text) continue;
      const start = startMs / 1000;
      cues.push({ start, end: start + durMs / 1000, text });
    }
    return cues;
  }

  function parseTtml(xml) {
    const cues = [];
    const source = String(xml || "");
    const re = /<p\b([^>]*)>([\s\S]*?)<\/p>/gi;
    let match;
    while ((match = re.exec(source))) {
      const attrs = match[1];
      const begin = Cues && Cues.parseTimestamp
        ? Cues.parseTimestamp(String((attrs.match(/\bbegin="([^"]+)"/) || [])[1]).replace(".", ","))
        : null;
      const end = Cues && Cues.parseTimestamp
        ? Cues.parseTimestamp(String((attrs.match(/\bend="([^"]+)"/) || [])[1]).replace(".", ","))
        : null;
      const text = decodeXmlText(match[2]);
      if (begin == null || end == null || end <= begin || !text) continue;
      cues.push({ start: begin, end, text });
    }
    return cues;
  }

  function parseTimedText(body, fmtHint) {
    const fmt = sniffFmt(body, fmtHint);
    if (fmt === "json3") return parseJson3(body);
    if (fmt === "vtt" && Cues) return Cues.parseVtt(body);
    if (fmt === "srv1") return parseSrv1(body);
    if (fmt === "srv3") return parseSrv3(body);
    if (fmt === "ttml") return parseTtml(body);
    const jsonTry = parseJson3(body);
    if (jsonTry.length > 0) return jsonTry;
    const srv1Try = parseSrv1(body);
    if (srv1Try.length > 0) return srv1Try;
    const srv3Try = parseSrv3(body);
    if (srv3Try.length > 0) return srv3Try;
    if (Cues && /^\s*WEBVTT\b/i.test(String(body || ""))) return Cues.parseVtt(body);
    return [];
  }

  function liveCueUpdate(cues, text, time) {
    const list = Array.isArray(cues) ? cues.slice() : [];
    const normalized = Cues ? Cues.normalizeCueText(text) : String(text || "").trim();
    const now = Number(time);
    const t = Number.isFinite(now) ? now : 0;
    if (!normalized) {
      if (list.length > 0) {
        list[list.length - 1] = closedCue(list[list.length - 1], t);
      }
      return list;
    }
    const last = list.length > 0 ? list[list.length - 1] : null;
    if (last && last.text === normalized) {
      const extended = Object.assign({}, last);
      extended.end = Math.max(last.end, t + 1.25);
      list[list.length - 1] = extended;
      return list;
    }
    if (last) {
      list[list.length - 1] = closedCue(last, t);
    }
    list.push({ start: Math.max(0, t - 0.05), end: t + 1.25, text: normalized });
    return list.length > 48 ? list.slice(-48) : list;
  }

  function closedCue(cue, time) {
    const copy = Object.assign({}, cue);
    copy.end = Math.max(cue.start + 0.05, time);
    return copy;
  }

  function captionSelectors() {
    return ".ytp-caption-segment, .caption-visual-line";
  }

  function collectDomCaptionText(doc) {
    const parts = [];
    function walk(root) {
      if (!root || !root.querySelectorAll) return;
      const nodes = root.querySelectorAll(captionSelectors());
      for (let i = 0; i < nodes.length; i++) {
        const text = Cues ? Cues.normalizeCueText(nodes[i].textContent) : String(nodes[i].textContent || "").trim();
        if (text) parts.push(text);
      }
      const all = root.querySelectorAll("*");
      for (let i = 0; i < all.length; i++) {
        if (all[i] && all[i].shadowRoot) walk(all[i].shadowRoot);
      }
    }
    walk(doc);
    if (parts.length > 0) return parts.join(" ");
    if (!doc || !doc.querySelector) return "";
    const container = doc.querySelector(".ytp-caption-window-container, .caption-window, .ytp-caption-window-bottom");
    if (!container) return "";
    return Cues ? Cues.normalizeCueText(container.textContent) : String(container.textContent || "").trim();
  }

  function overlayParentNode(doc) {
    if (!doc) return null;
    if (doc.fullscreenElement) return doc.fullscreenElement;
    return doc.documentElement || doc.body || null;
  }

  function selectCues(timed, live, time) {
    const timedList = Array.isArray(timed) ? timed : [];
    const liveList = Array.isArray(live) ? live : [];
    if (timedList.length === 0) return liveList;
    const t = Number(time);
    if (!Number.isFinite(t)) return timedList;
    if (Cues && Cues.activeCue(timedList, t)) return timedList;
    if (liveList.length > 0 && Cues && Cues.activeCue(liveList, t)) return liveList;
    return timedList;
  }

  function userCaptionsEnabledFromDom(doc) {
    if (!doc || !doc.querySelector) return false;
    const button = doc.querySelector(".ytp-subtitles-button, button[aria-label*='字幕'], button[aria-label*='Captions'], button[aria-label*='Subtitles']");
    if (button && button.getAttribute("aria-pressed") === "true") return true;
    if (doc.querySelector(".ytp-caption-segment")) return true;
    return false;
  }

  function isActivePage() {
    if (typeof location === "undefined") return false;
    return isYouTubeHost(location.hostname);
  }

  let enabled = false;
  let timedtextCues = [];
  let liveCues = [];
  let videoId = "";
  let changeHandler = null;
  let domObserver = null;
  let domTimer = null;
  let messageListener = null;
  let navigateListener = null;

  function notify() {
    if (typeof changeHandler === "function") {
      try { changeHandler(); } catch (_error) {}
    }
  }

  function resetCues() {
    timedtextCues = [];
    liveCues = [];
  }

  function onNavigate() {
    const nextId = currentVideoId(typeof location !== "undefined" ? location.href : "");
    if (!nextId || nextId === videoId) return;
    videoId = nextId;
    resetCues();
    notify();
  }

  function applyTimedText(body, fmtHint) {
    const parsed = parseTimedText(body, fmtHint);
    if (parsed.length === 0) return;
    timedtextCues = parsed;
    notify();
  }

  function readDomCaptions() {
    if (!enabled) return;
    if (typeof document === "undefined") return;
    const text = collectDomCaptionText(document);
    const video = document.querySelector && document.querySelector("video.html5-main-video, video");
    const time = video ? (video.currentTime || 0) : 0;
    liveCues = liveCueUpdate(liveCues, text, time);
    if (liveCues.length > 0 || text) notify();
  }

  function scheduleDomRead() {
    if (domTimer) return;
    domTimer = setTimeout(() => {
      domTimer = null;
      try { readDomCaptions(); } catch (_error) {}
    }, 80);
  }

  function startDomWatch() {
    if (domObserver || typeof document === "undefined" || typeof MutationObserver === "undefined") return;
    domObserver = new MutationObserver(scheduleDomRead);
    const root = document.documentElement || document.body;
    if (!root) return;
    domObserver.observe(root, { childList: true, subtree: true, characterData: true });
  }

  function stopDomWatch() {
    if (domObserver) {
      try { domObserver.disconnect(); } catch (_error) {}
    }
    domObserver = null;
    if (domTimer) clearTimeout(domTimer);
    domTimer = null;
  }

  function helloPage() {
    try {
      window.postMessage({ source: SOURCE_ISOLATED, kind: "hello" }, location.origin);
    } catch (_error) {}
  }

  function byePage() {
    try {
      window.postMessage({ source: SOURCE_ISOLATED, kind: "bye" }, location.origin);
    } catch (_error) {}
  }

  function start(onChange) {
    changeHandler = onChange || null;
    if (typeof window === "undefined" || !isActivePage()) {
      enabled = false;
      return;
    }
    enabled = true;
    videoId = currentVideoId(location.href);
    if (!messageListener) {
      messageListener = function (event) {
        if (event.source !== window) return;
        const data = event.data;
        if (!data || data.source !== SOURCE_PAGE) return;
        if (data.kind === "timedtext") {
          applyTimedText(data.body, data.fmtHint);
        } else if (data.kind === "live") {
          const video = document.querySelector && document.querySelector("video.html5-main-video, video");
          const time = Number(data.time);
          const t = Number.isFinite(time) ? time : (video ? (video.currentTime || 0) : 0);
          liveCues = liveCueUpdate(liveCues, data.body, t);
          if (liveCues.length > 0 || data.body) notify();
        } else if (data.kind === "navigate") {
          const nextId = data.videoId || currentVideoId(location.href);
          if (!nextId || nextId === videoId) {
            videoId = nextId || videoId;
            return;
          }
          videoId = nextId;
          resetCues();
          notify();
        }
      };
      window.addEventListener("message", messageListener);
    }
    if (!navigateListener) {
      navigateListener = function () {
        try { onNavigate(); } catch (_error) {}
      };
      document.addEventListener("yt-navigate-finish", navigateListener);
      window.addEventListener("yt-navigate-finish", navigateListener);
    }
    startDomWatch();
    helloPage();
    scheduleDomRead();
  }

  function stop() {
    enabled = false;
    changeHandler = null;
    resetCues();
    videoId = "";
    stopDomWatch();
    if (messageListener) {
      try { window.removeEventListener("message", messageListener); } catch (_error) {}
      messageListener = null;
    }
    if (navigateListener) {
      try { document.removeEventListener("yt-navigate-finish", navigateListener); } catch (_error) {}
      try { window.removeEventListener("yt-navigate-finish", navigateListener); } catch (_error) {}
      navigateListener = null;
    }
    byePage();
  }

  function cuesFor(video) {
    const time = video && Number(video.currentTime);
    return selectCues(timedtextCues, liveCues, time);
  }

  const api = {
    SOURCE_PAGE,
    SOURCE_ISOLATED,
    YOUTUBE_PROBE_MS,
    MESSAGES,
    isYouTubeHost,
    isTimedTextUrl,
    fmtHintFromUrl,
    currentVideoId,
    parseJson3,
    parseSrv1,
    parseSrv3,
    parseTimedText,
    liveCueUpdate,
    collectDomCaptionText,
    userCaptionsEnabledFromDom,
    overlayParentNode,
    selectCues,
    isActivePage,
    start,
    stop,
    cuesFor
  };
  root.GlobalTranslatorYouTubeCaptions = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
