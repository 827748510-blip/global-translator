// Cue parsing, timing, and overlay-state helpers for video translation Phase A.
// Used by the content script, popup (sidecar validation), and Node tests.
(function (root) {
  const MESSAGES = Object.freeze({
    serviceUnavailable: "翻译服务不可用",
    noForeign: "未检测到外语内容"
  });

  const DEFAULTS = Object.freeze({
    videoTranslateEnabled: false
  });

  function stripTags(value) {
    return String(value || "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\{[^}]*\}/g, " ")
      .replace(/&#x([0-9a-f]+);/gi, (_, hex) => {
        const code = parseInt(hex, 16);
        return Number.isFinite(code) ? String.fromCharCode(code) : "";
      })
      .replace(/&#(\d+);/g, (_, n) => {
        const code = Number(n);
        return Number.isFinite(code) ? String.fromCharCode(code) : "";
      })
      .replace(/&nbsp;/gi, " ")
      .replace(/&amp;/gi, "&")
      .replace(/&lt;/gi, "<")
      .replace(/&gt;/gi, ">")
      .replace(/&quot;/gi, "\"")
      .replace(/&apos;/gi, "'");
  }

  function normalizeCueText(value) {
    return stripTags(value).replace(/\s+/g, " ").trim();
  }

  function parseTimestamp(value) {
    const match = String(value || "").trim().match(/^(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})$/);
    if (!match) return null;
    const hours = Number(match[1] || 0);
    const minutes = Number(match[2]);
    const seconds = Number(match[3]);
    const millis = Number(match[4].padEnd(3, "0"));
    if (!Number.isFinite(hours) || !Number.isFinite(minutes) || !Number.isFinite(seconds) || !Number.isFinite(millis)) {
      return null;
    }
    return hours * 3600 + minutes * 60 + seconds + millis / 1000;
  }

  function isNoteOrStyleBlock(lines) {
    const first = (lines[0] || "").trim();
    if (!first) return true;
    return /^(NOTE|STYLE|REGION)\b/i.test(first);
  }

  function timestampLine(line) {
    const match = String(line || "").match(
      /(\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3}\s*-->\s*(\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3}/
    );
    if (!match) return null;
    const parts = match[0].split("-->");
    const start = parseTimestamp(parts[0]);
    const end = parseTimestamp(parts[1]);
    if (start == null || end == null || end <= start) return null;
    return { start, end };
  }

  function parseBlocks(source, skipHeader) {
    const text = String(source || "").replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
    let body = text;
    if (skipHeader && /^\s*WEBVTT\b/i.test(body)) {
      const firstBlank = body.indexOf("\n\n");
      body = firstBlank === -1 ? "" : body.slice(firstBlank + 2);
    }
    const chunks = body.split(/\n{2,}/);
    const cues = [];
    for (let i = 0; i < chunks.length; i++) {
      const lines = chunks[i].split("\n").map((line) => line.trim()).filter(Boolean);
      if (lines.length === 0 || isNoteOrStyleBlock(lines)) continue;
      let stamp = timestampLine(lines[0]);
      let textStart = 1;
      if (!stamp && lines.length > 1) {
        stamp = timestampLine(lines[1]);
        textStart = 2;
      }
      if (!stamp) continue;
      const payload = normalizeCueText(lines.slice(textStart).join(" "));
      if (!payload) continue;
      cues.push({ start: stamp.start, end: stamp.end, text: payload });
    }
    return cues;
  }

  function parseSrt(source) {
    return parseBlocks(source, false);
  }

  function parseVtt(source) {
    return parseBlocks(source, true);
  }

  function looksLikeVtt(source) {
    return /^\s*WEBVTT\b/i.test(String(source || "").replace(/^\uFEFF/, ""));
  }

  function parseSidecar(source, filename) {
    const name = String(filename || "").toLowerCase();
    if (name.endsWith(".vtt") || looksLikeVtt(source)) return parseVtt(source);
    if (name.endsWith(".srt")) return parseSrt(source);
    if (looksLikeVtt(source)) return parseVtt(source);
    return parseSrt(source);
  }

  function activeCue(cues, timeSeconds) {
    const time = Number(timeSeconds);
    if (!Array.isArray(cues) || !Number.isFinite(time)) return null;
    let found = null;
    for (let i = 0; i < cues.length; i++) {
      const cue = cues[i];
      if (!cue) continue;
      if (time >= cue.start && time < cue.end) found = cue;
    }
    return found;
  }

  function hasLetterLikeScript(value) {
    return /\p{L}/u.test(value);
  }

  function isMostlySimplifiedChinese(value) {
    const letters = String(value || "").replace(/[\s\d.,!?;:'"()[\]{}<>/~@#$%^&*+=_|\\-]/g, "");
    if (!letters) return false;
    const cjk = (letters.match(/[\u3400-\u9FFF]/g) || []).length;
    const kana = (letters.match(/[\u3040-\u30FF]/g) || []).length;
    const hangul = (letters.match(/[\u1100-\u11FF\uAC00-\uD7AF]/g) || []).length;
    if (kana > 0 || hangul > 0) return false;
    if (cjk / letters.length >= 0.8) return true;
    // Long CJK captions with a few Latin names (hotel, Aethos) are still
    // already the target language — do not send them to /translate.
    if (cjk >= 8) {
      const latin = (letters.match(/[A-Za-z\u00C0-\u024F]/g) || []).length;
      return latin === 0 || cjk / (cjk + latin) >= 0.6;
    }
    return false;
  }

  function shouldSendForVideoTranslate(text) {
    const value = normalizeCueText(text);
    if (!value) return false;
    if (isMostlySimplifiedChinese(value)) return false;
    return hasLetterLikeScript(value);
  }

  function hasForeignCues(cues) {
    if (!Array.isArray(cues)) return false;
    for (let i = 0; i < cues.length; i++) {
      if (shouldSendForVideoTranslate(cues[i] && cues[i].text)) return true;
    }
    return false;
  }

  function noForeignOverlayMessage(input, cues) {
    const empty = !cues || cues.length === 0;
    if (empty && input && input.noForeignMessage) return input.noForeignMessage;
    return MESSAGES.noForeign;
  }

  function overlayState(input) {
    const enabled = !!(input && input.enabled);
    if (!enabled) {
      return { show: false, cueText: "", message: "" };
    }
    const cues = (input && input.cues) || [];
    const time = input && input.time;
    const translations = (input && input.translations) || {};
    const serviceError = !!(input && input.serviceError);
    const waitTimedOut = !!(input && input.waitTimedOut);
    const probed = !!(input && input.probed);
    const asrHold = asrHoldOrMessage(input);
    const cue = activeCue(cues, time);
    if (cue) {
      const source = normalizeCueText(cue.text);
      if (!shouldSendForVideoTranslate(source)) {
        // Live Chinese CC used to hide the pill AND stay `on wait`. After
        // probe, tell the user this track is already the target language.
        if (probed && !hasForeignCues(cues)) {
          return asrHold || { show: true, cueText: "", message: noForeignOverlayMessage(input, cues) };
        }
        return { show: false, cueText: "", message: "" };
      }
      if (serviceError || waitTimedOut) {
        return { show: true, cueText: "", message: MESSAGES.serviceUnavailable };
      }
      const translated = translations[source];
      if (translated) {
        return { show: true, cueText: String(translated), message: "" };
      }
      return { show: false, cueText: "", message: "" };
    }
    if (probed && !hasForeignCues(cues)) {
      return asrHold || { show: true, cueText: "", message: noForeignOverlayMessage(input, cues) };
    }
    return { show: false, cueText: "", message: "" };
  }

  function asrHoldOrMessage(input) {
    const asrStatus = input && input.asrStatus;
    const asrMessage = input && input.asrMessage;
    if (asrStatus === "running" && !asrMessage) {
      return { show: false, cueText: "", message: "" };
    }
    if (typeof asrMessage === "string" && asrMessage) {
      return { show: true, cueText: "", message: asrMessage };
    }
    return null;
  }

  /// Desktop /health is the source of truth. A transient lastError (service
  /// worker busy, message channel timeout) must not write false over true.
  function desktopVideoPrefFromPing(response, lastError) {
    if (lastError) return { write: false, enabled: false };
    if (!response) return { write: false, enabled: false };
    if (response.ok === true) {
      return { write: true, enabled: response.videoTranslateEnabled === true };
    }
    return { write: true, enabled: false };
  }

  const api = {
    MESSAGES,
    DEFAULTS,
    stripTags,
    normalizeCueText,
    parseTimestamp,
    parseSrt,
    parseVtt,
    parseSidecar,
    activeCue,
    shouldSendForVideoTranslate,
    hasForeignCues,
    overlayState,
    desktopVideoPrefFromPing,
    isMostlySimplifiedChinese
  };
  root.GlobalTranslatorSubtitleCues = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
