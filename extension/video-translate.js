// Video translation Phase A + B1 + B2 — overlay Simplified Chinese from
// textTracks, sidecar, YouTube in-session captions, or on-device ASR cues
// from the desktop bridge. The page never captures audio or pauses playback.
(() => {
  const Cues = (typeof GlobalTranslatorSubtitleCues !== "undefined")
    ? GlobalTranslatorSubtitleCues
    : null;
  const Youtube = (typeof GlobalTranslatorYouTubeCaptions !== "undefined")
    ? GlobalTranslatorYouTubeCaptions
    : null;
  const Asr = (typeof GlobalTranslatorVideoASR !== "undefined")
    ? GlobalTranslatorVideoASR
    : null;
  if (!Cues) return;

  const CHUNK_SIZE = 3;
  const PROBE_MS = 4000;
  const PREFETCH = 4;
  const DESKTOP_SYNC_MS = 3000;
  const CUE_WAIT_MS = 8000;
  const ASR_POLL_MS = 1000;
  const HOST_ATTR = "data-gt-video-translate";
  const PAINT_MS = 250;
  const OBSERVER_DEBOUNCE_MS = 250;

  let enabled = false;
  let sidecarCues = [];
  let probed = false;
  let probeTimer = null;
  let serviceError = false;
  let runningTranslate = false;
  let observer = null;
  let scanTimer = null;
  let paintTimer = null;
  let syncTimer = null;
  let rafId = 0;
  let resizeObserver = null;
  const translations = new Map();
  const originalTrackModes = new WeakMap();
  const trackListeners = new WeakMap();
  const pipListeners = new WeakMap();
  const dismissedVideos = new WeakSet();
  const overlays = new Map();
  const boundVideos = new WeakSet();
  const boundList = [];
  let cueWaitText = "";
  let cueWaitSince = 0;
  let asrTimer = null;
  let asrWanted = false;
  let asrStatus = "";
  let asrMessage = "";
  let asrCues = [];
  let asrSeenSeq = {};
  let asrInFlight = false;
  let asrQueued = null;

  function safe(fn) {
    try {
      fn();
    } catch (_error) {
      // Never interrupt the page or playback.
    }
  }

  function isDebugEnabled() {
    try {
      return typeof localStorage !== "undefined" && localStorage.getItem("gtVtDebug") === "1";
    } catch (_error) {
      return false;
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
    if (main && isVisibleVideo(main)) {
      const rest = all.filter((video) => video !== main && isVisibleVideo(video));
      return [main].concat(rest);
    }
    return all.filter(isVisibleVideo);
  }

  function isAudiblePlayingVideo(video) {
    if (!video || !isVisibleVideo(video)) return false;
    if (video.paused || video.ended || video.muted) return false;
    if (typeof video.volume === "number" && video.volume <= 0) return false;
    return true;
  }

  function primaryVideo(videos) {
    const list = videos || listVideos();
    for (let i = 0; i < list.length; i++) {
      if (!list[i].paused && !list[i].ended) return list[i];
    }
    return list[0] || null;
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
    if (typeof Youtube.syncFromDom === "function") {
      try { Youtube.syncFromDom(video); } catch (_error) {}
    }
    return Youtube.cuesFor(video) || [];
  }

  function captionCues(video) {
    if (sidecarCues.length > 0) return sidecarCues;
    const fromYoutube = youtubeCues(video);
    if (fromYoutube.length > 0) return fromYoutube;
    return collectTrackCues(video);
  }

  function cuesFor(video) {
    const captions = captionCues(video);
    if (Cues.hasForeignCues(captions)) return captions;
    if (asrCues.length > 0) return asrCues;
    return captions;
  }

  function youtubeNoForeignMessage() {
    if (sidecarCues.length > 0) return "";
    if (Youtube && Youtube.isActivePage() && Youtube.MESSAGES) {
      return Youtube.MESSAGES.noYouTubeCaptions || "";
    }
    return "";
  }

  function overlayParent(_video) {
    if (Youtube && typeof Youtube.overlayParentNode === "function") {
      return Youtube.overlayParentNode(document);
    }
    const full = document.fullscreenElement;
    if (full) return full;
    return document.body || document.documentElement;
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
      "position:fixed",
      "left:0",
      "top:0",
      "overflow:visible",
      "pointer-events:none",
      "z-index:2147483646",
      "will-change:transform",
      "contain:layout style"
    ].join(";");
    const shadow = host.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = [
      ".gt-box{display:none;width:100%;height:100%;box-sizing:border-box;pointer-events:none;align-items:flex-end;justify-content:center;text-align:center;font-family:-apple-system,'PingFang SC','Noto Sans CJK SC',sans-serif;font-size:clamp(13px,2.2vw,22px);line-height:1.38;color:#fff;}",
      ".gt-pill{display:inline-flex;align-items:center;gap:8px;max-width:88%;padding:5px 12px;border-radius:6px;background:rgba(16,16,18,0.78);border:1px solid rgba(255,255,255,0.12);white-space:pre-wrap;word-break:break-word;transition:opacity 120ms ease-out;}",
      ".gt-pill[data-kind='notice']{font-size:12px;background:rgba(16,16,18,0.68);color:#f0f0f3;pointer-events:auto;}",
      ".gt-close{display:none;appearance:none;border:0;background:transparent;color:inherit;font-size:14px;line-height:1;padding:2px 4px;border-radius:4px;cursor:pointer;opacity:0.8;}",
      ".gt-pill[data-kind='notice'] .gt-close{display:inline-flex;}",
      ".gt-close:hover{opacity:1;background:rgba(255,255,255,0.16);}",
      ".gt-close:focus-visible{outline:2px solid #fff;outline-offset:1px;}",
      "@media (prefers-reduced-motion: reduce){.gt-pill{transition:none;}}",
      "@media (forced-colors: active){.gt-pill{background:Canvas;color:CanvasText;border:1px solid ButtonText;}}"
    ].join("");
    const box = document.createElement("div");
    box.setAttribute("part", "box");
    box.className = "gt-box";
    const pill = document.createElement("div");
    pill.className = "gt-pill";
    pill.setAttribute("role", "status");
    pill.setAttribute("aria-live", "polite");
    pill.setAttribute("aria-atomic", "true");
    const label = document.createElement("span");
    const closeButton = document.createElement("button");
    closeButton.type = "button";
    closeButton.className = "gt-close";
    closeButton.textContent = "×";
    closeButton.setAttribute("aria-label", "关闭提示");
    closeButton.addEventListener("click", (event) => {
      event.stopPropagation();
      dismissedVideos.add(video);
      box.style.display = "none";
      label.textContent = "";
    });
    pill.appendChild(label);
    pill.appendChild(closeButton);
    box.appendChild(pill);
    shadow.appendChild(style);
    shadow.appendChild(box);
    (parent || document.body || document.documentElement).appendChild(host);
    record = { host, box, pill, label, lastLayoutKey: "" };
    overlays.set(video, record);
    return record;
  }

  function positionOverlay(record, video) {
    const rect = video.getBoundingClientRect();
    const host = record.host;
    const isPip = typeof document.pictureInPictureElement !== "undefined" && document.pictureInPictureElement === video;
    const vw = window.innerWidth || document.documentElement.clientWidth || 0;
    const vh = window.innerHeight || document.documentElement.clientHeight || 0;
    const offscreen = isPip || rect.width < 24 || rect.height < 24 ||
      rect.bottom < 8 || rect.top > vh - 8 || rect.right < 8 || rect.left > vw - 8;

    const visibleLeft = Math.max(0, rect.left);
    const visibleRight = Math.min(vw > 0 ? vw : rect.right, rect.right);
    const width = Math.max(0, Math.round(visibleRight - visibleLeft));
    const controlInset = Math.min(84, Math.max(52, Math.round(rect.height * 0.14)));
    const boxHeight = Math.min(120, Math.max(40, Math.round(rect.height * 0.28)));
    const bottomY = Math.max(8, Math.round(rect.bottom - controlInset));
    const topY = Math.max(0, bottomY - boxHeight);

    const parent = host.parentNode;
    const useAbsolute = parent && parent !== document.documentElement && parent !== document.body;
    let x = Math.round(visibleLeft);
    let y = topY;
    let positionMode = "fixed";
    if (useAbsolute) {
      const parentRect = parent.getBoundingClientRect();
      positionMode = "absolute";
      x = Math.max(0, Math.round(visibleLeft - parentRect.left));
      y = Math.max(0, Math.round(topY - parentRect.top));
    }

    const layoutKey = [offscreen ? 1 : 0, positionMode, x, y, width, boxHeight].join(":");
    if (record.lastLayoutKey === layoutKey) return;
    record.lastLayoutKey = layoutKey;

    if (offscreen || width < 24) {
      host.style.setProperty("display", "none", "important");
      host.style.setProperty("opacity", "0", "important");
      host.style.setProperty("visibility", "hidden", "important");
      return;
    }

    host.style.setProperty("display", "block", "important");
    host.style.setProperty("position", positionMode, "important");
    host.style.setProperty("opacity", "1", "important");
    host.style.setProperty("visibility", "visible", "important");
    host.style.setProperty("left", "0px", "important");
    host.style.setProperty("top", "0px", "important");
    host.style.setProperty("width", width + "px", "important");
    host.style.setProperty("height", boxHeight + "px", "important");
    host.style.setProperty("transform", "translate3d(" + x + "px," + y + "px,0)", "important");
  }

  function cueWaitTimedOut(cues, time, translationsNow) {
    const cue = Cues.activeCue(cues, time);
    const source = cue ? Cues.normalizeCueText(cue.text) : "";
    const foreign = !!(source && Cues.shouldSendForVideoTranslate(source));
    const hasZh = !!(source && translationsNow[source]);
    if (!foreign || hasZh || serviceError) {
      cueWaitText = "";
      cueWaitSince = 0;
      return false;
    }
    if (cueWaitText !== source) {
      cueWaitText = source;
      cueWaitSince = Date.now();
    }
    return cueWaitSince > 0 && (Date.now() - cueWaitSince) >= CUE_WAIT_MS;
  }

  function renderVideo(video, mainVideo) {
    if (!enabled || !video || !video.isConnected) return;
    const record = ensureOverlay(video);
    positionOverlay(record, video);
    const cues = cuesFor(video);
    const time = video.currentTime || 0;
    const translationsNow = translationObject();
    const waitTimedOut = cueWaitTimedOut(cues, time, translationsNow);
    const isPrimary = !mainVideo || video === mainVideo;
    const state = Cues.overlayState({
      enabled: true,
      cues,
      time,
      translations: translationsNow,
      serviceError,
      waitTimedOut,
      probed,
      noForeignMessage: youtubeNoForeignMessage(),
      asrStatus: isPrimary ? asrStatus : "",
      asrMessage: isPrimary ? asrMessage : ""
    });
    const asrBit = Asr && Asr.overlayBits ? Asr.overlayBits(asrStatus) : "asr0";
    if (isDebugEnabled()) {
      if (Youtube && typeof Youtube.overlayDebugBits === "function") {
        const bits = Youtube.overlayDebugBits({
          cues,
          time,
          translations: translationsNow,
          pageWorld: !!(Youtube.pageWorldAlive && Youtube.pageWorldAlive(document)),
          dom: !!(Youtube.collectDomCaptionText && Youtube.collectDomCaptionText(document))
        });
        record.host.setAttribute("data-gt-vt", bits + " " + asrBit);
        try { console.debug("[gt-vt]", bits, asrBit); } catch (_error) {}
      } else {
        record.host.setAttribute("data-gt-vt", asrBit);
      }
    } else {
      record.host.removeAttribute("data-gt-vt");
    }

    const isNotice = !state.cueText && !!state.message;
    const suppressNotice = isNotice && (dismissedVideos.has(video) || !isPrimary || (video.muted && video.paused));
    if (!state.show || (!state.cueText && !state.message) || suppressNotice) {
      record.box.style.display = "none";
      record.label.textContent = "";
      return;
    }
    record.box.style.display = "flex";
    record.pill.setAttribute("data-kind", state.cueText ? "cue" : "notice");
    const nextText = state.cueText || state.message;
    if (record.label.textContent !== nextText) {
      record.label.textContent = nextText;
    }
  }

  function renderAll() {
    const videos = listVideos();
    const main = primaryVideo(videos);
    for (let i = 0; i < videos.length; i++) {
      renderVideo(videos[i], main);
    }
  }

  function scheduleRenderAll() {
    if (rafId) return;
    rafId = requestAnimationFrame(() => {
      rafId = 0;
      safe(renderAll);
    });
  }

  function translateTexts(texts) {
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({ type: "translate", texts, lane: "video" }, (response) => {
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
      renderVideo(video, primaryVideo());
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
    const onPipChange = () => safe(scheduleRenderAll);
    pipListeners.set(video, onPipChange);
    video.addEventListener("enterpictureinpicture", onPipChange);
    video.addEventListener("leavepictureinpicture", onPipChange);
    if (video.textTracks && video.textTracks.addEventListener) {
      const onAddTrack = () => safe(() => {
        renderVideo(video, primaryVideo());
        prefetch(video);
      });
      trackListeners.set(video, onAddTrack);
      video.textTracks.addEventListener("addtrack", onAddTrack);
    }
    if (resizeObserver) {
      try { resizeObserver.observe(video); } catch (_error) {}
    }
    renderVideo(video, primaryVideo());
    prefetch(video);
  }

  function unbindVideo(video) {
    video.removeEventListener("timeupdate", onTimeUpdate);
    video.removeEventListener("seeked", onTimeUpdate);
    video.removeEventListener("loadedmetadata", onTimeUpdate);
    video.removeEventListener("emptied", onTimeUpdate);
    const onPipChange = pipListeners.get(video);
    if (onPipChange) {
      video.removeEventListener("enterpictureinpicture", onPipChange);
      video.removeEventListener("leavepictureinpicture", onPipChange);
      pipListeners.delete(video);
    }
    const onAddTrack = trackListeners.get(video);
    if (onAddTrack && video.textTracks && video.textTracks.removeEventListener) {
      video.textTracks.removeEventListener("addtrack", onAddTrack);
      trackListeners.delete(video);
    }
    if (resizeObserver) {
      try { resizeObserver.unobserve(video); } catch (_error) {}
    }
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
    syncAsr();
    renderAll();
  }

  function mutationTouchesVideo(mutations) {
    for (let i = 0; i < mutations.length; i++) {
      const list = mutations[i].addedNodes;
      for (let j = 0; j < list.length; j++) {
        const node = list[j];
        if (!node || node.nodeType !== 1) continue;
        if (node.tagName === "VIDEO" || (node.querySelector && node.querySelector("video"))) return true;
      }
      const removed = mutations[i].removedNodes;
      for (let j = 0; j < removed.length; j++) {
        const node = removed[j];
        if (!node || node.nodeType !== 1) continue;
        if (node.tagName === "VIDEO" || (node.querySelector && node.querySelector("video"))) return true;
      }
    }
    return false;
  }

  function scheduleScan() {
    if (scanTimer || !enabled) return;
    scanTimer = setTimeout(() => {
      scanTimer = null;
      safe(scan);
    }, OBSERVER_DEBOUNCE_MS);
  }

  function startObserver() {
    if (observer) return;
    if (typeof ResizeObserver !== "undefined" && !resizeObserver) {
      resizeObserver = new ResizeObserver(() => safe(scheduleRenderAll));
    }
    observer = new MutationObserver((mutations) => {
      if (mutationTouchesVideo(mutations)) scheduleScan();
    });
    observer.observe(document.documentElement || document.body, {
      childList: true,
      subtree: true
    });
  }

  function stopObserver() {
    if (observer) observer.disconnect();
    observer = null;
    if (scanTimer) clearTimeout(scanTimer);
    scanTimer = null;
    if (resizeObserver) {
      try { resizeObserver.disconnect(); } catch (_error) {}
      resizeObserver = null;
    }
  }

  function startPaintLoop() {
    if (paintTimer) return;
    paintTimer = setInterval(() => {
      safe(() => {
        if (!enabled || document.visibilityState !== "visible") return;
        const videos = listVideos();
        if (!videos.some((video) => !video.paused && !video.ended)) return;
        scan();
        const main = primaryVideo(videos);
        if (main) prefetch(main);
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
      syncAsr();
      return;
    }
    probeTimer = setTimeout(() => {
      probed = true;
      renderAll();
      syncAsr();
    }, probeDelay());
  }

  function clearAsrState() {
    asrCues = [];
    asrSeenSeq = {};
    asrStatus = "";
    asrMessage = "";
  }

  function applyAsrSnapshot(payload, video) {
    if (!payload || typeof payload !== "object") return;
    asrStatus = typeof payload.status === "string" ? payload.status : "";
    asrMessage = Asr && Asr.messageFor
      ? Asr.messageFor(asrStatus, payload.message)
      : (payload.message || "");
    if (!video) return;
    const mapped = Asr && Asr.mapNewCues
      ? Asr.mapNewCues(asrCues, payload.cues, video.currentTime || 0, asrSeenSeq)
      : { cues: asrCues, seenSeq: asrSeenSeq };
    asrCues = mapped.cues;
    asrSeenSeq = mapped.seenSeq;
  }

  function postAsr(needed, video) {
    if (asrInFlight) {
      asrQueued = { needed: needed === true, video };
      return;
    }
    asrInFlight = true;
    try {
      chrome.runtime.sendMessage({ type: "video-asr", needed: needed === true }, (response) => {
        asrInFlight = false;
        const queued = asrQueued;
        asrQueued = null;
        if (chrome.runtime.lastError) {
          if (queued) postAsr(queued.needed, queued.video);
          return;
        }
        safe(() => {
          applyAsrSnapshot(response, video || primaryVideo());
          renderAll();
          if (video) prefetch(video);
          else {
            const main = primaryVideo();
            if (main) prefetch(main);
          }
        });
        if (queued) postAsr(queued.needed, queued.video);
      });
    } catch (_error) {
      asrInFlight = false;
    }
  }

  function syncAsr() {
    if (!enabled) return;
    const video = primaryVideo();
    const captions = video ? captionCues(video) : [];
    const foreign = Cues.hasForeignCues(captions);
    const activeAudio = document.visibilityState === "visible" && isAudiblePlayingVideo(video);
    const want = activeAudio && (probed && Asr && Asr.shouldRequest ? Asr.shouldRequest(foreign) : (probed && !foreign));
    if (!want) {
      if (asrWanted) postAsr(false, video);
      asrWanted = false;
      clearAsrState();
      stopAsrPoll();
      return;
    }
    asrWanted = true;
    postAsr(true, video);
    startAsrPoll();
  }

  function startAsrPoll() {
    if (asrTimer) return;
    asrTimer = setInterval(() => {
      safe(() => {
        if (!enabled || !asrWanted || document.visibilityState !== "visible") return;
        syncAsr();
      });
    }, ASR_POLL_MS);
  }

  function stopAsrPoll() {
    if (asrTimer) clearInterval(asrTimer);
    asrTimer = null;
  }

  function onViewportChange() {
    safe(scheduleRenderAll);
  }

  function start() {
    const already = enabled;
    enabled = true;
    serviceError = false;
    if (Youtube && typeof Youtube.start === "function") {
      Youtube.start(() => {
        if (!enabled) return;
        probed = true;
        scan();
        const main = primaryVideo();
        if (main) prefetch(main);
        renderAll();
      });
    }
    if (already) {
      scan();
      markProbedSoon();
      return;
    }
    startObserver();
    startPaintLoop();
    scan();
    markProbedSoon();
    window.addEventListener("scroll", onViewportChange, { capture: true, passive: true });
    window.addEventListener("resize", onViewportChange, { passive: true });
    document.addEventListener("fullscreenchange", onViewportChange);
  }

  function stop() {
    enabled = false;
    probed = false;
    serviceError = false;
    if (probeTimer) clearTimeout(probeTimer);
    probeTimer = null;
    if (rafId) cancelAnimationFrame(rafId);
    rafId = 0;
    stopObserver();
    stopPaintLoop();
    stopAsrPoll();
    if (asrWanted) postAsr(false);
    asrWanted = false;
    clearAsrState();
    window.removeEventListener("scroll", onViewportChange, { capture: true });
    window.removeEventListener("resize", onViewportChange);
    document.removeEventListener("fullscreenchange", onViewportChange);
    if (Youtube && typeof Youtube.stop === "function") Youtube.stop();
    clearOverlays();
    translations.clear();
    cueWaitText = "";
    cueWaitSince = 0;
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
        const main = primaryVideo();
        if (main) prefetch(main);
        renderAll();
      } else {
        markProbedSoon();
        scan();
        renderAll();
      }
    }
  }

  function applyDesktopVideoPref(on) {
    try {
      chrome.storage.local.set({ videoTranslateEnabled: on });
    } catch (_error) {}
    if (on) {
      if (!enabled) start();
    } else if (enabled) {
      stop();
    }
  }

  function syncDesktopPref() {
    try {
      chrome.runtime.sendMessage({ type: "ping" }, (response) => {
        const lastError = chrome.runtime.lastError;
        const decision = Cues.desktopVideoPrefFromPing
          ? Cues.desktopVideoPrefFromPing(response, lastError)
          : null;
        if (!decision || !decision.write) return;
        applyDesktopVideoPref(decision.enabled === true);
      });
    } catch (_error) {
      // Transient channel errors must not force the default-profile pref off.
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

  chrome.runtime.onMessage.addListener((message) => {
    if (!message || message.type !== "set-sidecar") return false;
    safe(() => applySidecar(message.sidecar));
    return false;
  });

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

  syncTimer = setInterval(() => {
    safe(() => {
      if (document.visibilityState !== "visible") return;
      if (enabled || document.querySelector("video")) syncDesktopPref();
    });
  }, DESKTOP_SYNC_MS);

  window.addEventListener("pagehide", () => {
    if (syncTimer) clearInterval(syncTimer);
    syncTimer = null;
    stop();
  });
})();
