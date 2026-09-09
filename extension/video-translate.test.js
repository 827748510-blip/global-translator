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
const youtubeJs = fs.readFileSync(path.join(dir, "youtube-captions.js"), "utf8");
const youtubePage = fs.readFileSync(path.join(dir, "youtube-captions-page.js"), "utf8");
const manifest = fs.readFileSync(path.join(dir, "manifest.json"), "utf8");
const background = fs.readFileSync(path.join(dir, "background.js"), "utf8");
const content = fs.readFileSync(path.join(dir, "content.js"), "utf8");
const cuesSource = fs.readFileSync(path.join(dir, "subtitle-cues.js"), "utf8");

assert(popupHtml.indexOf("视频翻译") !== -1, "popup shows 视频翻译");
assert(popupHtml.indexOf("id=\"videoTranslate\"") === -1, "no separate popup toggle");
assert(popupHtml.indexOf("同一行") !== -1, "popup points at menu-bar same row");
assert(popupHtml.indexOf("SRT/VTT") !== -1, "popup offers sidecar picker");
assert(popupJs.indexOf("videoTranslateEnabled: false") !== -1, "storage default is off");
assert(popupJs.indexOf("response.videoTranslateEnabled === true") !== -1, "desktop ping is source of truth");
assert(videoJs.indexOf("videoTranslateEnabled: false") !== -1, "content default is off");
assert(videoJs.indexOf("videoTranslateEnabled === true") !== -1, "content only starts when true");
assert(background.indexOf("payload.videoTranslateEnabled === true") !== -1, "health forwards desktop toggle");

assert(content.indexOf("ytp-caption-segment") !== -1, "page translate skips youtube caption DOM");
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
assert(popupJs.indexOf("YouTube 请先打开播放器字幕") !== -1, "popup youtube range");
assert(videoJs.indexOf("GlobalTranslatorYouTubeCaptions") !== -1, "content uses youtube helper");
assert(videoJs.indexOf("noYouTubeCaptions") !== -1, "youtube empty copy wired");
assert(videoJs.indexOf("data-gt-video-translate") !== -1, "overlay host marker");
assert(videoJs.indexOf("#movie_player") === -1, "overlay not mounted inside youtube player");
assert(videoJs.indexOf("html5-main-video") !== -1, "prefers youtube main video");
assert(videoJs.indexOf("overlayParentNode") !== -1, "uses document/fullscreen overlay parent");
assert(videoJs.indexOf("syncFromDom") !== -1, "overlay path refreshes youtube live cues");
assert(videoJs.indexOf("data-gt-vt") !== -1, "inspectable overlay debug bits");
assert(videoJs.indexOf("lane: \"video\"") !== -1, "video cues use video bridge lane");
assert(videoJs.indexOf("all:initial") === -1, "overlay does not reset position via all:initial");
assert(videoJs.indexOf("gtVtDebug") !== -1, "gated console debug flag");
assert(videoJs.indexOf("html5-main-video, video") === -1, "video translate no comma selector");
assert(youtubePage.indexOf("post(\"live\"") !== -1, "page world live caption feed");
assert(youtubeJs.indexOf("getUserMedia") === -1, "youtube helper no getUserMedia");
assert(youtubePage.indexOf("getUserMedia") === -1, "youtube page no getUserMedia");
assert(youtubeJs.toLowerCase().indexOf("whisper") === -1, "no whisper in youtube helper");
assert(youtubePage.indexOf("setOption") === -1, "never enable captions via player");
assert(youtubePage.indexOf("loadModule") === -1, "never load caption module");
assert(background.indexOf("ENDPOINT + \"/translate\"") !== -1, "backend translate path unchanged");

assert(manifest.indexOf("\"version\": \"1.0.9\"") !== -1, "manifest version");
assert(background.indexOf("importScripts(\"bridge-queue.js\")") !== -1, "background loads bridge queue");
assert(background.indexOf("message.lane === \"video\"") !== -1, "background honors video lane");
assert(background.indexOf("message.type === \"ping\"") !== -1, "background health ping");
assert(background.indexOf("enqueueBridgeFetch(() =>\n      fetch(ENDPOINT + \"/health\"") === -1, "health ping is not queued behind translate");
assert(videoJs.indexOf("desktopVideoPrefFromPing") !== -1, "content uses ping decision helper");
assert(videoJs.indexOf("applyDesktopVideoPref") !== -1, "content applies desktop pref immediately");
assert(videoJs.indexOf("if (!enabled) start()") !== -1, "repeated health true does not restart probe");
assert(videoJs.indexOf("CUE_WAIT_MS") !== -1, "foreign cue wait timeout");
assert(videoJs.indexOf("waitTimedOut") !== -1, "overlay gets wait timeout");
assert(cuesSource.indexOf("desktopVideoPrefFromPing") !== -1, "ping helper is shared");
assert(youtubeJs.indexOf("\"skip\"") !== -1, "debug bits can skip chinese cues");
assert(youtubePage.indexOf("data-gt-ytcap") !== -1, "page script marks injection");
assert(manifest.indexOf("subtitle-cues.js") !== -1, "manifest loads cue helper");
assert(manifest.indexOf("youtube-captions.js") !== -1, "manifest loads youtube helper");
assert(manifest.indexOf("youtube-captions-page.js") !== -1, "manifest loads youtube page observer");
assert(manifest.indexOf("\"world\": \"MAIN\"") !== -1, "youtube observer is page world");
assert(manifest.indexOf("document_start") !== -1, "youtube observer starts before player fetch");
assert(manifest.indexOf("video-translate.js") !== -1, "manifest loads video script");
assert(manifest.indexOf("tabCapture") === -1, "no tabCapture permission");
assert(manifest.indexOf("desktopCapture") === -1, "no desktopCapture");

const visual = fs.readFileSync(path.join(dir, "../Sources/GlobalTranslatorCapture/WindowVisualUpdates.swift"), "utf8");
assert(visual.indexOf("configuration.capturesAudio = false") !== -1, "vision stream stays silent");
assert(visual.indexOf("capturesAudio = true") === -1, "B1 does not enable capturesAudio");

const settings = fs.readFileSync(path.join(dir, "../Sources/GlobalTranslatorUI/SettingsSections.swift"), "utf8");
assert(settings.indexOf("\"滑词翻译\"") !== -1, "settings has 滑词翻译");
assert(settings.indexOf("\"视频翻译\"") !== -1, "settings has 视频翻译");
assert(settings.indexOf("HStack(alignment: .center, spacing: GTSpacing.medium)") !== -1, "same-row HStack");
assert(settings.indexOf("\"滑词翻译\"") < settings.indexOf("\"视频翻译\""), "video toggle after selection on the row");

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
