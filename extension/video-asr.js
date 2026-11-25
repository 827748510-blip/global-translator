// Video translation Phase B2 helpers — map on-device ASR cues onto the
// existing overlay clock. The page never captures audio; system/window
// capture and local speech-to-text stay in the macOS app.
(function (root) {
  function cuesApi() {
    return root.GlobalTranslatorSubtitleCues;
  }

  const MESSAGES = Object.freeze({
    denied: "系统音频未授权（请在屏幕录制中允许）",
    whisperMissing: "未安装本地 Whisper 模型",
    error: "语音转写暂时不可用"
  });

  function shouldRequest(hasForeignCaptionCues) {
    return !hasForeignCaptionCues;
  }

  function messageFor(status, nativeMessage) {
    if (typeof nativeMessage === "string" && nativeMessage.trim()) {
      return nativeMessage.trim();
    }
    if (status === "denied") return MESSAGES.denied;
    if (status === "whisper_missing") return MESSAGES.whisperMissing;
    if (status === "error") return MESSAGES.error;
    return "";
  }

  function overlayBits(status) {
    if (status === "running") return "asr1";
    if (status === "denied" || status === "whisper_missing" || status === "error") return "asrErr";
    return "asr0";
  }

  function mapNewCues(existing, incoming, videoTime, seenSeq) {
    const next = Array.isArray(existing) ? existing.slice() : [];
    const seen = seenSeq && typeof seenSeq === "object" ? Object.assign({}, seenSeq) : {};
    const now = Number(videoTime);
    const time = Number.isFinite(now) ? now : 0;
    const list = Array.isArray(incoming) ? incoming : [];
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (!item) continue;
      const seq = item.seq;
      if (seq == null || seen[seq]) continue;
      const Cues = cuesApi();
      const text = Cues && Cues.normalizeCueText
        ? Cues.normalizeCueText(item.text)
        : String(item.text || "").trim();
      if (!text) continue;
      if (Cues && Cues.shouldSendForVideoTranslate && !Cues.shouldSendForVideoTranslate(text)) {
        continue;
      }
      seen[seq] = true;
      const duration = Math.min(8, Math.max(1.2, Number(item.durationMs || 3000) / 1000));
      next.push({ start: time, end: time + duration, text, seq });
    }
    const cutoff = time - 12;
    const kept = next.filter((cue) => cue && cue.end > cutoff);
    const MAX_SEEN_SEQ = 256;
    const seenKeys = Object.keys(seen);
    if (seenKeys.length > MAX_SEEN_SEQ) {
      seenKeys.sort((a, b) => Number(a) - Number(b));
      const removeCount = seenKeys.length - MAX_SEEN_SEQ;
      for (let i = 0; i < removeCount; i++) {
        delete seen[seenKeys[i]];
      }
    }
    return { cues: kept.slice(-8), seenSeq: seen };
  }

  const api = {
    MESSAGES,
    shouldRequest,
    messageFor,
    overlayBits,
    mapNewCues
  };
  root.GlobalTranslatorVideoASR = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
