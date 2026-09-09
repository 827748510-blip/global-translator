#!/usr/bin/env node
"use strict";

const cues = require("./subtitle-cues");

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(label + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
  }
}

function assertDeep(actual, expected, label) {
  const left = JSON.stringify(actual);
  const right = JSON.stringify(expected);
  if (left !== right) {
    throw new Error(label + ": expected " + right + ", got " + left);
  }
}

assertEqual(cues.DEFAULTS.videoTranslateEnabled, false, "off-by-default");
assertEqual(cues.MESSAGES.serviceUnavailable, "翻译服务不可用", "service message");
assertEqual(cues.MESSAGES.noForeign, "未检测到外语内容", "no-foreign message");

const srt = [
  "1",
  "00:00:01,000 --> 00:00:04,000",
  "Hello world",
  "",
  "2",
  "00:00:04,500 --> 00:00:07,250",
  "Second <b>line</b>",
  "",
  "3",
  "00:01:00,000 --> 00:01:02,000",
  "这是中文"
].join("\n");

const srtCues = cues.parseSrt(srt);
assertEqual(srtCues.length, 3, "srt count");
assertEqual(srtCues[0].start, 1, "srt start");
assertEqual(srtCues[0].end, 4, "srt end");
assertEqual(srtCues[0].text, "Hello world", "srt text");
assertEqual(srtCues[1].text, "Second line", "srt strips tags");
assertEqual(srtCues[2].start, 60, "srt minute");

const vtt = [
  "WEBVTT",
  "",
  "NOTE skip me",
  "",
  "00:00:00.000 --> 00:00:02.000",
  "The weather is nice today.",
  "",
  "cue-2",
  "00:00:02.000 --> 00:00:05.000 align:start",
  "<c>Bonjour</c> le monde",
  "",
  "00:00:06.000 --> 00:00:08.000",
  "你好世界"
].join("\n");

const vttCues = cues.parseVtt(vtt);
assertEqual(vttCues.length, 3, "vtt count");
assertEqual(vttCues[0].text, "The weather is nice today.", "vtt first");
assertEqual(vttCues[1].text, "Bonjour le monde", "vtt strips voice tags");
assertEqual(cues.parseSidecar(vtt, "captions.vtt").length, 3, "sidecar vtt by name");
assertEqual(cues.parseSidecar(srt, "movie.srt")[0].text, "Hello world", "sidecar srt by name");

assertEqual(cues.activeCue(srtCues, 0.5), null, "before first cue");
assertEqual(cues.activeCue(srtCues, 1).text, "Hello world", "at start inclusive");
assertEqual(cues.activeCue(srtCues, 3.9).text, "Hello world", "near end");
assertEqual(cues.activeCue(srtCues, 4), null, "end exclusive");
assertEqual(cues.activeCue(srtCues, 4.5).text, "Second line", "second cue");
assertEqual(cues.activeCue(srtCues, 61).text, "这是中文", "chinese cue");

assertEqual(cues.normalizeCueText("Second &amp; last &#39;ok&#39;"), "Second & last 'ok'", "html entities");
assertEqual(cues.shouldSendForVideoTranslate("Hello world"), true, "english");
assertEqual(cues.shouldSendForVideoTranslate("Bonjour le monde"), true, "french");
assertEqual(cues.shouldSendForVideoTranslate("これは日本語です"), true, "japanese");
assertEqual(cues.shouldSendForVideoTranslate("안녕하세요"), true, "korean");
assertEqual(cues.shouldSendForVideoTranslate("这是中文"), false, "chinese skipped");
assertEqual(cues.shouldSendForVideoTranslate("你好世界！"), false, "chinese punct");
assertEqual(cues.shouldSendForVideoTranslate("我很兴奋能去一个有空调的地方。酒店就"), false, "native zh cue skipped");
assertEqual(cues.shouldSendForVideoTranslate("我很兴奋能去 Aethos 酒店住一晚"), false, "chinese with latin name");
assertEqual(cues.shouldSendForVideoTranslate(""), false, "empty");
assertEqual(cues.hasForeignCues(srtCues), true, "srt has foreign");
assertEqual(cues.hasForeignCues([{ start: 0, end: 1, text: "你好" }]), false, "chinese only");

const off = cues.overlayState({
  enabled: false,
  cues: srtCues,
  time: 2,
  translations: { "Hello world": "你好世界" },
  probed: true
});
assertDeep(off, { show: false, cueText: "", message: "" }, "disabled hides overlay");

const translated = cues.overlayState({
  enabled: true,
  cues: srtCues,
  time: 2,
  translations: { "Hello world": "你好世界" }
});
assertDeep(translated, { show: true, cueText: "你好世界", message: "" }, "shows translation");

const waiting = cues.overlayState({
  enabled: true,
  cues: srtCues,
  time: 2,
  translations: {},
  serviceError: false
});
assertDeep(waiting, { show: false, cueText: "", message: "" }, "in-flight stays quiet");

const failed = cues.overlayState({
  enabled: true,
  cues: srtCues,
  time: 2,
  translations: {},
  serviceError: true
});
assertDeep(failed, { show: true, cueText: "", message: "翻译服务不可用" }, "service failure");

const waitTimedOut = cues.overlayState({
  enabled: true,
  cues: srtCues,
  time: 2,
  translations: {},
  waitTimedOut: true
});
assertDeep(waitTimedOut, { show: true, cueText: "", message: "翻译服务不可用" }, "cue wait timeout");

const chineseActive = cues.overlayState({
  enabled: true,
  cues: srtCues,
  time: 61,
  translations: {},
  probed: true
});
assertDeep(chineseActive, { show: false, cueText: "", message: "" }, "keep original chinese cue");

const nativeZhActive = cues.overlayState({
  enabled: true,
  cues: [{ start: 10, end: 20, text: "我很兴奋能去一个有空调的地方。酒店就" }],
  time: 12,
  translations: {},
  probed: true
});
assertDeep(nativeZhActive, {
  show: true,
  cueText: "",
  message: "未检测到外语内容"
}, "zh-only live cue is no-foreign not silent wait");

const youtubeHint = cues.overlayState({
  enabled: true,
  cues: [],
  time: 1,
  probed: true,
  noForeignMessage: "未检测到外语字幕（请先打开 YouTube 字幕）"
});
assertDeep(youtubeHint, { show: true, cueText: "", message: "未检测到外语字幕（请先打开 YouTube 字幕）" }, "youtube empty hint");

const noForeign = cues.overlayState({
  enabled: true,
  cues: [{ start: 0, end: 1, text: "你好" }],
  time: 3,
  probed: true
});
assertDeep(noForeign, { show: true, cueText: "", message: "未检测到外语内容" }, "no foreign after probe");

const probing = cues.overlayState({
  enabled: true,
  cues: [],
  time: 1,
  probed: false
});
assertDeep(probing, { show: false, cueText: "", message: "" }, "do not flash no-foreign while probing");

const betweenCues = cues.overlayState({
  enabled: true,
  cues: srtCues,
  time: 4.2,
  translations: { "Hello world": "你好世界" },
  probed: true
});
assertDeep(betweenCues, { show: false, cueText: "", message: "" }, "hide between foreign cues");

assertDeep(cues.desktopVideoPrefFromPing({ ok: true, videoTranslateEnabled: true }, null),
  { write: true, enabled: true }, "health true writes on");
assertDeep(cues.desktopVideoPrefFromPing({ ok: true, videoTranslateEnabled: false }, null),
  { write: true, enabled: false }, "health false writes off");
assertDeep(cues.desktopVideoPrefFromPing({ ok: false, videoTranslateEnabled: false }, null),
  { write: true, enabled: false }, "desktop down writes off");
assertDeep(cues.desktopVideoPrefFromPing({ ok: true, videoTranslateEnabled: true }, { message: "timeout" }),
  { write: false, enabled: false }, "lastError must not clobber");
assertDeep(cues.desktopVideoPrefFromPing(undefined, null),
  { write: false, enabled: false }, "missing response does not write");

console.log("extension/subtitle-cues.test.js ok");
