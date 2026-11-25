#!/usr/bin/env node
"use strict";

const cues = require("./subtitle-cues");
const asr = require("./video-asr");

function assert(condition, label) {
  if (!condition) throw new Error(label);
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(label + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
  }
}

function assertDeep(actual, expected, label) {
  const left = JSON.stringify(actual);
  const right = JSON.stringify(expected);
  if (left !== right) throw new Error(label + ": expected " + right + ", got " + left);
}

assertEqual(asr.shouldRequest(true), false, "captions win");
assertEqual(asr.shouldRequest(false), true, "no captions requests asr");
assertEqual(asr.messageFor("denied", ""), "系统音频未授权（请在屏幕录制中允许）", "denied copy");
assertEqual(asr.messageFor("whisper_missing", ""), "未安装本地 Whisper 模型", "model copy");
assertEqual(asr.messageFor("error", ""), "语音转写暂时不可用", "error copy");
assertEqual(asr.messageFor("denied", "系统音频未授权（请在屏幕录制中允许）"),
  "系统音频未授权（请在屏幕录制中允许）", "native message wins");
assertEqual(asr.overlayBits("running"), "asr1", "running bit");
assertEqual(asr.overlayBits("denied"), "asrErr", "error bit");
assertEqual(asr.overlayBits("idle"), "asr0", "idle bit");

const first = asr.mapNewCues([], [{ seq: 1, text: "Hello from the speaker", durationMs: 2500 }], 12, {});
assertEqual(first.cues.length, 1, "maps one cue");
assertEqual(first.cues[0].start, 12, "start is video time");
assertEqual(first.cues[0].end, 14.5, "duration mapped");
assertEqual(first.cues[0].text, "Hello from the speaker", "text kept");
assert(first.seenSeq[1], "seq recorded");

const dup = asr.mapNewCues(first.cues, [{ seq: 1, text: "Hello from the speaker", durationMs: 2500 }], 13, first.seenSeq);
assertEqual(dup.cues.length, 1, "duplicate seq ignored");

const chinese = asr.mapNewCues([], [{ seq: 2, text: "你好世界", durationMs: 2000 }], 0, {});
assertEqual(chinese.cues.length, 0, "already-chinese asr dropped");

const running = cues.overlayState({
  enabled: true,
  cues: [],
  time: 1,
  probed: true,
  asrStatus: "running",
  noForeignMessage: "未检测到外语字幕（请先打开 YouTube 字幕）"
});
assertDeep(running, { show: false, cueText: "", message: "" }, "running asr hides youtube hint");

const denied = cues.overlayState({
  enabled: true,
  cues: [],
  time: 1,
  probed: true,
  asrStatus: "denied",
  asrMessage: "系统音频未授权（请在屏幕录制中允许）"
});
assertDeep(denied, {
  show: true,
  cueText: "",
  message: "系统音频未授权（请在屏幕录制中允许）"
}, "denied shows message");

const live = cues.overlayState({
  enabled: true,
  cues: [{ start: 10, end: 14, text: "Hello from the speaker" }],
  time: 11,
  translations: { "Hello from the speaker": "来自扬声器的问候" },
  probed: true,
  asrStatus: "running"
});
assertEqual(live.cueText, "来自扬声器的问候", "asr cue uses existing overlay");

let cappedSeen = {};
for (let startSeq = 1; startSeq <= 300; startSeq += 50) {
  const batch = [];
  for (let s = startSeq; s < startSeq + 50; s++) {
    batch.push({ seq: s, text: "Caption line " + s, durationMs: 2000 });
  }
  const mapped = asr.mapNewCues([], batch, 10, cappedSeen);
  cappedSeen = mapped.seenSeq;
}
const seenKeys = Object.keys(cappedSeen);
assert(seenKeys.length <= 256, "seenSeq is bounded to at most 256 entries");
assertEqual(cappedSeen[300], true, "most recent seq stays in seenSeq");
assertEqual(cappedSeen[1], undefined, "oldest seq is evicted once past cap");

console.log("extension/video-asr.test.js ok");
