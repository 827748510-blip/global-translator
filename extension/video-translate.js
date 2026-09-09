// Video translation Phase A + B1 — overlay Simplified Chinese from textTracks,
// optional local SRT/VTT sidecar, or YouTube in-session captions. No ASR,
// no media capture, never pauses playback or rewrites original media.
(() => {
  const Cues = (typeof GlobalTranslatorSubtitleCues !== "undefined")
    ? GlobalTranslatorSubtitleCues
    : null;
  const Youtube = (typeof GlobalTranslatorYouTubeCaptions !== "undefined")
    ? GlobalTranslatorYouTubeCaptions
    : null;
  if (!Cues) return;

  const CHUNK_SIZE = 3;
  const PROBE_MS = 4000;
  const PREFETCH = 4;
  const DESKTOP_SYNC_MS = 3000;
  const HOST_ATTR = "data-gt-video-translate";
  const PAINT_MS = 250;

  let enabled = false;
  let sidecarCues = [];
  let probed = false;
  let probeTimer = null;
  let serviceError = false;
  let runningTranslate = false;
  let observer = null;
  let paintTimer = null;
  const translations = new Map();
  const originalTrackModes = new WeakMap();
  const overlays = new Map();
  const boundVideos = new WeakSet();
  const boundList = [];

  function safe(fn) {
    try {
      fn();
    } catch (_error) {
      // Never interrupt the page or playback.
    }
  }

  function isVisibleVideo(video) {
    if (!video || !video.isConnected) return false;
    const rect = video.getBoundingClientRect();
    return rect.width >= 24 && rect.height >= 24;
  }

  function listVideos() {
    const all = Array.prototype.slice.call(document.querySelectorAll("video"));
    const main = document.querySelector("video.html5-main-video");
    if (main) {
      const rest = all.filter((video) => video !== main && isVisibleVideo(video));
      return [main].concat(rest);
    }
    const visible = all.filter(isVisibleVideo);
    return visible.length > 0 ? visible : all;
  }

  function restoreTrackModes(video) {
    const tracks = video.textTracks;
    if (!tracks) return;
    for (let i = 0; i < tracks.length; i++) {
      const track = tracks[i];
      if (!originalTrackModes.has(track)) continue;
      try {
        track.mode = originalTrackModes.get(track);
      } catch (_error) {}
    }
  }

  function collectTrackCues(video) {
    const collected = [];
    const tracks = video.textTracks;
    if (!tracks) return collected;
    for (let i = 0; i < tracks.length; i++) {
      const track = tracks[i];
      if (!track || track.kind === "metadata") continue;
      if (!originalTrackModes.has(track)) {
        originalTrackModes.set(track, track.mode);
      }
      if (track.mode === "disabled") {
        try { track.mode = "hidden"; } catch (_error) {}
      }
      const list = track.cues;
      if (!list) continue;
      for (let j = 0; j < list.length; j++) {
        const cue = list[j];
        const text = Cues.normalizeCueText(cue && cue.text);
        if (!text) continue;
        collected.push({ start: cue.startTime, end: cue.endTime, text });
      }
    }
    return collected;
  }

  function youtubeCues(video) {
    if (!Youtube || typeof Youtube.cuesFor !== "function") return [];
    if (!Youtube.isActivePage()) return [];
    return Youtube.cuesFor(video) || [];
  }

  function youtubeNoForeignMessage() {
    if (sidecarCues.length > 0) return "";
    if (Youtube && Youtube.isActivePage() && Youtube.MESSAGES) {
      return Youtube.MESSAGES.noYouTubeCaptions || "";
    }
    return "";
  }

  function cuesFor(video) {
    if (sidecarCues.length > 0) return sidecarCues;
    const fromYoutube = youtubeCues(video);
    if (fromYoutube.length > 0) return fromYoutube;
    return collectTrackCues(video);
  }

  function overlayParent(_video) {
    if (Youtube && typeof Youtube.overlayParentNode === "function") {
      return Youtube.overlayParentNode(document);
    }
    const full = document.fullscreenElement;
    if (full) return full;
    return document.documentElement || document.body;
  }

  function translationObject() {
    const object = {};
    translations.forEach((value, key) => {
      object[key] = value;
    });
    return object;
  }

  function ensureOverlay(video) {
    let record = overlays.get(video);
    const parent = overlayParent(video);
    if (record && record.host.isConnected) {
      if (parent && record.host.parentNode !== parent) {
        parent.appendChild(record.host);
      }
      return record;
    }
    const host = document.createElement("div");
    host.setAttribute(HOST_ATTR, "");
    host.style.cssText = [
      "all:initial",
      "display:block",
      "position:fixed",
      "pointer-events:none",
      "z-index:2147483646"
    ].join(";");
    host.style.setProperty("z-index", "2147483646", "important");
    host.style.setProperty("pointer-events", "none", "important");
    const shadow = host.attachShadow({ mode: "closed" });
    const box = document.createElement("div");
    box.setAttribute("part", "box");
    box.style.cssText = [
      "display:none",
      "pointer-events:none",
      "text-align:center",
      "font-family:-apple-system,'PingFang SC','Noto Sans CJK SC',sans-serif",
      "font-size:15px",
      "line-height:1.35",
      "color:#fff"
    ].join(";");
    const pill = document.createElement("div");
    pill.style.cssText = [
      "display:inline-block",
      "max-width:90%",
      "padding:4px 10px",
      "border-radius:4px",
      "background:rgba(0,0,0,0.72)",
      "white-space:pre-wrap",
      "word-break:break-word"
    ].join(";");
    box.appendChild(pill);
    shadow.appendChild(box);
    (parent || document.documentElement || document.body).appendChild(host);
    record = { host, box, pill };
    overlays.set(video, record);
    return record;
  }

  function positionOverlay(record, video) {
    const rect = video.getBoundingClientRect();
    const host = record.host;
    const parent = host.parentNode;
    const height = 56;
    const offscreen = rect.width < 24 || rect.height < 24 ||
      rect.bottom < 8 || rect.top > window.innerHeight - 8;
    host.style.display = offscreen ? "none" : "block";
    host.style.pointerEvents = "none";
    host.style.setProperty("z-index", "2147483646", "important");
    const useAbsolute = parent && parent !== document.documentElement && parent !== document.body;
    if (useAbsolute) {
      const parentRect = parent.getBoundingClientRect();
      host.style.position = "absolute";
      host.style.left = Math.max(0, rect.left - parentRect.left) + "px";
      host.style.top = Math.max(0, rect.bottom - parentRect.top - height - 8) + "px";
    } else {
      host.style.position = "fixed";
      host.style.left = Math.max(0, rect.left) + "px";
      host.style.top = Math.max(0, rect.bottom - height - 8) + "px";
    }
    host.style.width = Math.max(0, rect.width) + "px";
    host.style.height = height + "px";
  }

  function renderVideo(video) {
    if (!enabled || !video || !video.isConnected) return;
    const record = ensureOverlay(video);
    positionOverlay(record, video);
    const state = Cues.overlayState({
      enabled: true,
      cues: cuesFor(video),
      time: video.currentTime || 0,
      translations: translationObject(),
      serviceError,
      probed,
      noForeignMessage: youtubeNoForeignMessage()
    });
    if (!state.show || (!state.cueText && !state.message)) {
      record.box.style.display = "none";
      record.pill.textContent = "";
      return;
    }
    record.box.style.display = "block";
    record.pill.textContent = state.cueText || state.message;
  }

  function renderAll() {
    listVideos().forEach(renderVideo);
  }

  function translateTexts(texts) {
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({ type: "translate", texts }, (response) => {
          if (chrome.runtime.lastError || !response || response.error) {
            resolve(null);
            return;
          }
          resolve({
            translations: response.translations || [],
            retry: Array.isArray(response.retry) ? response.retry : []
          });
        });
      } catch (_error) {
        resolve(null);
      }
    });
  }

  function pendingForeignTexts(video) {
    const cues = cuesFor(video);
    const time = video.currentTime || 0;
    const needed = [];
    const seen = {};
    const current = Cues.activeCue(cues, time);
    const startIndex = current ? cues.indexOf(current) : cues.findIndex((cue) => cue.start >= time);
    const from = startIndex >= 0 ? startIndex : 0;
    for (let i = from; i < cues.length && needed.length < PREFETCH; i++) {
      const text = Cues.normalizeCueText(cues[i] && cues[i].text);
      if (!text || seen[text] || translations.has(text)) continue;
      if (!Cues.shouldSendForVideoTranslate(text)) continue;
      seen[text] = true;
      needed.push(text);
    }
    return needed;
  }

  async function prefetch(video) {
    if (!enabled || runningTranslate) return;
    const texts = pendingForeignTexts(video);
    if (texts.length === 0) return;
    runningTranslate = true;
    try {
      for (let offset = 0; offset < texts.length; offset += CHUNK_SIZE) {
        if (!enabled) return;
        const chunk = texts.slice(offset, offset + CHUNK_SIZE);
        const result = await translateTexts(chunk);
        if (!result) {
          serviceError = true;
          renderAll();
          return;
        }
        serviceError = false;
        const retry = new Set(result.retry || []);
        for (let i = 0; i < chunk.length; i++) {
          if (retry.has(i)) continue;
          const translated = result.translations[i];
          if (typeof translated === "string" && translated.trim()) {
            translations.set(chunk[i], translated.trim());
          }
        }
      }
      renderAll();
    } finally {
      runningTranslate = false;
    }
  }

  function onTimeUpdate(event) {
    safe(() => {
      const video = event.target;
      renderVideo(video);
      prefetch(video);
    });
  }

  function bindVideo(video) {
    if (boundVideos.has(video)) return;
    boundVideos.add(video);
    boundList.push(video);
    video.addEventListener("timeupdate", onTimeUpdate);
    video.addEventListener("seeked", onTimeUpdate);
    video.addEventListener("loadedmetadata", onTimeUpdate);
    video.addEventListener("emptied", onTimeUpdate);
    if (video.textTracks && video.textTracks.addEventListener) {
      video.textTracks.addEventListener("addtrack", () => safe(() => {
        renderVideo(video);
        prefetch(video);
      }));
    }
    renderVideo(video);
    prefetch(video);
  }

  function unbindVideo(video) {
    video.removeEventListener("timeupdate", onTimeUpdate);
    video.removeEventListener("seeked", onTimeUpdate);
    video.removeEventListener("loadedmetadata", onTimeUpdate);
    video.removeEventListener("emptied", onTimeUpdate);
    restoreTrackModes(video);
    boundVideos.delete(video);
    const index = boundList.indexOf(video);
    if (index >= 0) boundList.splice(index, 1);
    const record = overlays.get(video);
    if (record && record.host && record.host.parentNode) {
      record.host.parentNode.removeChild(record.host);
    }
    overlays.delete(video);
  }

  function scan() {
    if (!enabled) return;
    listVideos().forEach(bindVideo);
    for (let i = boundList.length - 1; i >= 0; i--) {
      if (!boundList[i].isConnected) unbindVideo(boundList[i]);
    }
    renderAll();
  }

  function startObserver() {
    if (observer) return;
    observer = new MutationObserver(() => safe(scan));
    observer.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true
    });
  }

  function stopObserver() {
    if (observer) observer.disconnect();
    observer = null;
  }

  function startPaintLoop() {
    if (paintTimer) return;
    paintTimer = setInterval(() => {
      safe(() => {
        if (!enabled) return;
        scan();
        listVideos().forEach((video) => prefetch(video));
      });
    }, PAINT_MS);
  }

  function stopPaintLoop() {
    if (paintTimer) clearInterval(paintTimer);
    paintTimer = null;
  }

  function clearOverlays() {
    boundList.slice().forEach((video) => {
      try { unbindVideo(video); } catch (_error) {}
    });
    boundList.length = 0;
    overlays.forEach((record) => {
      if (record.host && record.host.parentNode) {
        record.host.parentNode.removeChild(record.host);
      }
    });
    overlays.clear();
  }

  function probeDelay() {
    if (Youtube && Youtube.isActivePage() && Youtube.YOUTUBE_PROBE_MS) {
      return Youtube.YOUTUBE_PROBE_MS;
    }
    return PROBE_MS;
  }

  function hasImmediateCues() {
    if (sidecarCues.length > 0) return true;
    const videos = listVideos();
    for (let i = 0; i < videos.length; i++) {
      if (youtubeCues(videos[i]).length > 0) return true;
    }
    if (Youtube && Youtube.isActivePage()) return false;
    for (let i = 0; i < videos.length; i++) {
      if (collectTrackCues(videos[i]).length > 0) return true;
    }
    return false;
  }

  function markProbedSoon() {
    if (probeTimer) clearTimeout(probeTimer);
    probed = hasImmediateCues();
    if (probed) {
      renderAll();
      return;
    }
    probeTimer = setTimeout(() => {
      probed = true;
      renderAll();
    }, probeDelay());
  }

  function onViewportChange() {
    safe(renderAll);
  }

  function start() {
    if (enabled) {
      scan();
      markProbedSoon();
      return;
    }
    enabled = true;
    serviceError = false;
    if (Youtube && typeof Youtube.start === "function") {
      Youtube.start(() => {
        if (!enabled) return;
        probed = true;
        scan();
        listVideos().forEach((video) => prefetch(video));
        renderAll();
      });
    }
    startObserver();
    startPaintLoop();
    scan();
    markProbedSoon();
    window.addEventListener("scroll", onViewportChange, true);
    window.addEventListener("resize", onViewportChange);
    document.addEventListener("fullscreenchange", onViewportChange);
  }

  function stop() {
    enabled = false;
    probed = false;
    serviceError = false;
    if (probeTimer) clearTimeout(probeTimer);
    probeTimer = null;
    stopObserver();
    stopPaintLoop();
    window.removeEventListener("scroll", onViewportChange, true);
    window.removeEventListener("resize", onViewportChange);
    document.removeEventListener("fullscreenchange", onViewportChange);
    if (Youtube && typeof Youtube.stop === "function") Youtube.stop();
    clearOverlays();
    translations.clear();
  }

  function applySidecar(payload) {
    sidecarCues = [];
    if (!payload || typeof payload.text !== "string" || !payload.text) {
      if (enabled) markProbedSoon();
      renderAll();
      return;
    }
    try {
      sidecarCues = Cues.parseSidecar(payload.text, payload.name || "");
    } catch (_error) {
      sidecarCues = [];
    }
    if (enabled) {
      if (sidecarCues.length > 0) {
        probed = true;
        scan();
        listVideos().forEach((video) => prefetch(video));
        renderAll();
      } else {
        markProbedSoon();
        scan();
        renderAll();
      }
    }
  }

  function syncDesktopPref() {
    try {
      chrome.runtime.sendMessage({ type: "ping" }, (response) => {
        if (chrome.runtime.lastError) {
          chrome.storage.local.set({ videoTranslateEnabled: false });
          return;
        }
        const on = !!(response && response.ok && response.videoTranslateEnabled === true);
        chrome.storage.local.set({ videoTranslateEnabled: on });
      });
    } catch (_error) {
      try { chrome.storage.local.set({ videoTranslateEnabled: false }); } catch (_ignored) {}
    }
  }

  function readPrefs() {
    try {
      chrome.storage.local.get({ videoTranslateEnabled: false }, (prefs) => {
        const on = prefs && prefs.videoTranslateEnabled === true;
        if (on) start();
        else stop();
      });
    } catch (_error) {
      stop();
    }
    try {
      if (chrome.storage.session) {
        chrome.storage.session.get({ videoSidecar: null }, (value) => {
          applySidecar(value && value.videoSidecar);
        });
      }
    } catch (_error) {}
    syncDesktopPref();
  }

  chrome.storage.onChanged.addListener((changes, area) => {
    safe(() => {
      if (area === "local" && changes.videoTranslateEnabled) {
        if (changes.videoTranslateEnabled.newValue === true) start();
        else stop();
      }
      if ((area === "session" || area === "local") && changes.videoSidecar) {
        applySidecar(changes.videoSidecar.newValue);
      }
    });
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => safe(readPrefs));
  } else {
    readPrefs();
  }

  setInterval(() => {
    safe(() => {
      if (document.visibilityState !== "visible") return;
      if (enabled || document.querySelector("video")) syncDesktopPref();
    });
  }, DESKTOP_SYNC_MS);
})();
