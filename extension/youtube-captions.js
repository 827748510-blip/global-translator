// Video translation Phase B1 — YouTube caption reliability.
// Reads the local player's already-active captions (visible cue DOM) and
// in-session timedtext the page itself fetched after the user turned CC on.
// Never initiates a caption download, never sends PoToken, never enables CC,
// never captures audio. Speech capture / system ASR are Phase B2 in the
// native SystemAudioCapture module; this helper stays caption-only.
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

  function joinCaptionParts(parts) {
    const unique = [];
    for (let i = 0; i < parts.length; i++) {
      if (parts[i] && unique[unique.length - 1] !== parts[i]) unique.push(parts[i]);
    }
    return unique.join(" ");
  }

  function collectSelectorText(root, selector) {
    const parts = [];
    function walk(node) {
      if (!node || !node.querySelectorAll) return;
      const nodes = node.querySelectorAll(selector);
      for (let i = 0; i < nodes.length; i++) {
        const text = Cues ? Cues.normalizeCueText(nodes[i].textContent) : String(nodes[i].textContent || "").trim();
        if (text) parts.push(text);
      }
      const all = node.querySelectorAll("*");
      for (let i = 0; i < all.length; i++) {
        if (all[i] && all[i].shadowRoot) walk(all[i].shadowRoot);
      }
    }
    walk(root);
    return parts;
  }

  function collectDomCaptionText(doc) {
    if (!doc) return "";
    const segments = collectSelectorText(doc, ".ytp-caption-segment");
    if (segments.length > 0) return joinCaptionParts(segments);
    const lines = collectSelectorText(doc, ".caption-visual-line");
    if (lines.length > 0) return joinCaptionParts(lines);
    if (!doc.querySelector) return "";
    const container = doc.querySelector(".ytp-caption-window-container, .caption-window, .ytp-caption-window-bottom");
    if (!container) return "";
    return Cues ? Cues.normalizeCueText(container.textContent) : String(container.textContent || "").trim();
  }

  function overlayParentNode(doc) {
    if (!doc) return null;
    if (doc.fullscreenElement) return doc.fullscreenElement;
    return doc.body || doc.documentElement || null;
  }

  function pageWorldAlive(doc) {
    const root = doc || (typeof document !== "undefined" ? document : null);
    if (!root || !root.documentElement || !root.documentElement.getAttribute) return false;
    return root.documentElement.getAttribute("data-gt-ytcap") === "1";
  }

  function primaryVideo(doc) {
    if (!doc || !doc.querySelector) return null;
    const main = doc.querySelector("video.html5-main-video");
    if (main) return main;
    const listed = doc.querySelectorAll ? doc.querySelectorAll("video") : [];
    let best = null;
    let area = 0;
    for (let i = 0; i < listed.length; i++) {
      const video = listed[i];
      const rect = video && video.getBoundingClientRect ? video.getBoundingClientRect() : null;
      const nextArea = rect ? Math.max(0, rect.width) * Math.max(0, rect.height) : 0;
      if (nextArea > area) {
        area = nextArea;
        best = video;
      }
    }
    return best || listed[0] || null;
  }

  function liveCueFromNow(text, time) {
    const normalized = Cues ? Cues.normalizeCueText(text) : String(text || "").trim();
    const t = Number(time);
    const now = Number.isFinite(t) ? t : 0;
    if (!normalized) return [];
    return [{ start: Math.max(0, now - 0.35), end: now + 2.5, text: normalized }];
  }

  function adoptLiveCaption(previous, text, time) {
    const next = liveCueFromNow(text, time);
    if (next.length > 0) return next;
    const list = Array.isArray(previous) ? previous : [];
    const t = Number(time);
    if (Cues && Number.isFinite(t) && Cues.activeCue(list, t)) return list;
    return [];
  }

  function overlayDebugBits(input) {
    const cues = (input && input.cues) || [];
    const time = Number(input && input.time);
    const translations = (input && input.translations) || {};
    const cue = Cues && Number.isFinite(time) ? Cues.activeCue(cues, time) : null;
    const source = Cues && cue ? Cues.normalizeCueText(cue.text) : "";
    const hasZh = !!(source && translations[source]);
    const foreign = !!(source && Cues && Cues.shouldSendForVideoTranslate(source));
    let trans = "idle";
    if (cue) {
      if (!foreign) trans = "skip";
      else if (hasZh) trans = "zh";
      else trans = "wait";
    }
    return [
      "c" + cues.length,
      Number.isFinite(time) ? "t" + Math.floor(time) : "t-",
      cue ? "on" : "off",
      trans,
      input && input.pageWorld === true ? "pw1" : "pw0",
      input && input.dom === true ? "dom1" : "dom0"
    ].join(" ");
  }

  function syncFromDom(video) {
    if (!enabled) return;
    if (typeof document === "undefined") return;
    const player = video || primaryVideo(document);
    const text = collectDomCaptionText(document);
    const time = player && Number.isFinite(Number(player.currentTime)) ? Number(player.currentTime) : 0;
    liveCues = adoptLiveCaption(liveCues, text, time);
  }

  function isForeignCue(cue) {
    return !!(cue && Cues && Cues.shouldSendForVideoTranslate(cue.text));
  }

  function selectCues(timed, live, time) {
    const timedList = Array.isArray(timed) ? timed : [];
    const liveList = Array.isArray(live) ? live : [];
    const t = Number(time);
    const liveActive = Cues && Number.isFinite(t) ? Cues.activeCue(liveList, t) : null;
    const timedActive = Cues && Number.isFinite(t) ? Cues.activeCue(timedList, t) : null;
    // Visible English still wins leftover Chinese timedtext. Already-Chinese
    // live CC must not hide a foreign timedtext cue at the same clock, and
    // must not look like a foreign cue pending /translate (`on wait`).
    if (isForeignCue(liveActive)) return liveList;
    if (isForeignCue(timedActive)) return timedList;
    if (liveActive) return liveList;
    if (timedList.length === 0) return liveList;
    if (!Number.isFinite(t)) return timedList;
    if (timedActive) return timedList;
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
    const player = primaryVideo(document);
    const text = collectDomCaptionText(document);
    const time = player && Number.isFinite(Number(player.currentTime)) ? Number(player.currentTime) : 0;
    liveCues = adoptLiveCaption(liveCues, text, time);
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
          const player = primaryVideo(document);
          const time = Number(data.time);
          const t = Number.isFinite(time) ? time : (player ? Number(player.currentTime) || 0 : 0);
          liveCues = adoptLiveCaption(liveCues, data.body, t);
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
    pageWorldAlive,
    primaryVideo,
    liveCueFromNow,
    adoptLiveCaption,
    overlayDebugBits,
    syncFromDom,
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
