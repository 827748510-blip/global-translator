// Video translation Phase A — overlay Simplified Chinese from textTracks
// or an optional local SRT/VTT sidecar. No ASR, no media capture, never
// pauses playback or rewrites the original video / subtitle files.
(() => {
  const Cues = (typeof GlobalTranslatorSubtitleCues !== "undefined")
    ? GlobalTranslatorSubtitleCues
    : null;
  if (!Cues) return;

  const CHUNK_SIZE = 3;
  const PROBE_MS = 4000;
  const PREFETCH = 4;
  const HOST_ATTR = "data-gt-video-translate";

  let enabled = false;
  let sidecarCues = [];
  let probed = false;
  let probeTimer = null;
  let serviceError = false;
  let runningTranslate = false;
  let observer = null;
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

  function listVideos() {
    return Array.prototype.slice.call(document.querySelectorAll("video"));
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

  function cuesFor(video) {
    if (sidecarCues.length > 0) return sidecarCues;
    return collectTrackCues(video);
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
    if (record && record.host.isConnected) return record;
    const host = document.createElement("div");
    host.setAttribute(HOST_ATTR, "");
    host.style.all = "initial";
    host.style.pointerEvents = "none";
    host.style.zIndex = "2147483646";
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
    (document.documentElement || document.body).appendChild(host);
    record = { host, box, pill };
    overlays.set(video, record);
    return record;
  }

  function positionOverlay(record, video) {
    const rect = video.getBoundingClientRect();
    const host = record.host;
    host.style.position = "fixed";
    host.style.left = Math.max(0, rect.left) + "px";
    host.style.width = Math.max(0, rect.width) + "px";
    const height = 56;
    host.style.height = height + "px";
    host.style.top = Math.max(0, rect.bottom - height - 8) + "px";
    const offscreen = rect.width < 24 || rect.height < 24 ||
      rect.bottom < 8 || rect.top > window.innerHeight - 8;
    host.style.display = offscreen ? "none" : "block";
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
      probed
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

  function markProbedSoon() {
    if (probeTimer) clearTimeout(probeTimer);
    probed = sidecarCues.length > 0;
    if (probed) {
      renderAll();
      return;
    }
    probeTimer = setTimeout(() => {
      probed = true;
      renderAll();
    }, PROBE_MS);
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
    startObserver();
    scan();
    markProbedSoon();
    window.addEventListener("scroll", onViewportChange, true);
    window.addEventListener("resize", onViewportChange);
  }

  function stop() {
    enabled = false;
    probed = false;
    serviceError = false;
    if (probeTimer) clearTimeout(probeTimer);
    probeTimer = null;
    stopObserver();
    window.removeEventListener("scroll", onViewportChange, true);
    window.removeEventListener("resize", onViewportChange);
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
})();
