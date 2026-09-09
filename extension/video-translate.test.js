#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

function assert(condition, label) {
  if (!condition) throw new Error(label);
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(label + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
  }
}

const dir = __dirname;
const popupJs = fs.readFileSync(path.join(dir, "popup.js"), "utf8");
const popupHtml = fs.readFileSync(path.join(dir, "popup.html"), "utf8");
const videoJs = fs.readFileSync(path.join(dir, "video-translate.js"), "utf8");
const manifest = fs.readFileSync(path.join(dir, "manifest.json"), "utf8");
const background = fs.readFileSync(path.join(dir, "background.js"), "utf8");

assert(popupHtml.indexOf("视频翻译") !== -1, "popup shows 视频翻译");
assert(popupHtml.indexOf("id=\"videoTranslate\"") !== -1, "popup has video toggle");
assert(popupHtml.indexOf("SRT/VTT") !== -1, "popup offers sidecar picker");
assert(popupJs.indexOf("videoTranslateEnabled: false") !== -1, "storage default is off");
assert(popupJs.indexOf("prefs.videoTranslateEnabled === true") !== -1, "only true enables");
assert(videoJs.indexOf("videoTranslateEnabled: false") !== -1, "content default is off");
assert(videoJs.indexOf("videoTranslateEnabled === true") !== -1, "content only starts when true");

const cuesSource = fs.readFileSync(path.join(dir, "subtitle-cues.js"), "utf8");
assert(cuesSource.indexOf("翻译服务不可用") !== -1, "service failure copy");
assert(cuesSource.indexOf("未检测到外语内容") !== -1, "no-foreign copy");
assert(popupJs.indexOf("翻译服务不可用") !== -1, "popup service copy");
assert(popupJs.indexOf("未检测到外语内容") !== -1, "popup no-foreign copy");
assert(videoJs.indexOf("overlayState") !== -1, "content uses overlay state");

assert(videoJs.indexOf("getUserMedia") === -1, "no getUserMedia");
assert(videoJs.indexOf("mediaDevices") === -1, "no mediaDevices");
assert(videoJs.indexOf("SpeechRecognition") === -1, "no speech recognition");
assert(videoJs.toLowerCase().indexOf("whisper") === -1, "no whisper");
assert(videoJs.indexOf("captureStream") === -1, "no captureStream");
assert(videoJs.indexOf(".pause(") === -1, "never pause playback");
assert(videoJs.indexOf(".play(") === -1, "never play/stop playback");
assert(videoJs.indexOf("type: \"translate\"") !== -1, "reuses existing translate bridge");
assert(background.indexOf("ENDPOINT + \"/translate\"") !== -1, "backend translate path unchanged");

assert(manifest.indexOf("\"version\": \"1.0.6\"") !== -1, "manifest version");
assert(manifest.indexOf("subtitle-cues.js") !== -1, "manifest loads cue helper");
assert(manifest.indexOf("video-translate.js") !== -1, "manifest loads video script");
assert(manifest.indexOf("tabCapture") === -1, "no tabCapture permission");
assert(manifest.indexOf("desktopCapture") === -1, "no desktopCapture");

const cues = require("./subtitle-cues");
assertEqual(cues.parseSidecar(fs.readFileSync(path.join(dir, "fixtures/sample.en.srt"), "utf8"), "sample.en.srt")[0].text,
  "Hello, this is an English subtitle.", "fixture srt");
assertEqual(cues.parseSidecar(fs.readFileSync(path.join(dir, "fixtures/sample.en.vtt"), "utf8"), "sample.en.vtt").length,
  3, "fixture vtt count");
const nativeLike = [
  { start: 1.0, end: 2.5, text: "Hello from the track" },
  { start: 2.5, end: 4.0, text: "Second cue" }
];
assertEqual(cues.activeCue(nativeLike, 1.0).text, "Hello from the track", "overlay timing start");
assertEqual(cues.activeCue(nativeLike, 2.499).text, "Hello from the track", "overlay timing before switch");
assertEqual(cues.activeCue(nativeLike, 2.5).text, "Second cue", "overlay timing switch");
assertEqual(cues.activeCue(nativeLike, 4.0), null, "overlay timing end exclusive");

const mid = cues.overlayState({
  enabled: true,
  cues: nativeLike,
  time: 1.2,
  translations: { "Hello from the track": "来自轨道的问候" }
});
assertEqual(mid.cueText, "来自轨道的问候", "translated overlay text");
assertEqual(mid.message, "", "no failure message when translated");

console.log("extension/video-translate.test.js ok");
