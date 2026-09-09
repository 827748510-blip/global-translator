#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");

require("./subtitle-cues");
const yt = require("./youtube-captions");
const cues = require("./subtitle-cues");

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
  if (left !== right) {
    throw new Error(label + ": expected " + right + ", got " + left);
  }
}

assert(yt.isYouTubeHost("www.youtube.com"), "www.youtube.com");
assert(yt.isYouTubeHost("youtube.com"), "youtube.com");
assert(yt.isYouTubeHost("m.youtube.com"), "m.youtube.com");
assert(yt.isYouTubeHost("www.youtube-nocookie.com"), "nocookie");
assert(yt.isYouTubeHost("youtu.be"), "youtu.be");
assert(!yt.isYouTubeHost("studio.youtube.com"), "studio excluded");
assert(!yt.isYouTubeHost("music.youtube.com"), "music excluded");
assert(!yt.isYouTubeHost("tv.youtube.com"), "tv excluded");
assert(!yt.isYouTubeHost("bilibili.com"), "not youtube");
assert(!yt.isYouTubeHost("example.com"), "random host");

assertEqual(yt.currentVideoId("https://www.youtube.com/watch?v=dQw4w9wgGcQ"), "dQw4w9wgGcQ", "watch id");
assertEqual(yt.currentVideoId("https://www.youtube.com/shorts/abcdef12345"), "abcdef12345", "shorts id");
assertEqual(yt.currentVideoId("https://www.youtube.com/embed/xyzXYZ78901"), "xyzXYZ78901", "embed id");
assertEqual(yt.currentVideoId("https://www.youtube.com/live/liveidABCDEF"), "liveidABCDEF", "live id");

assert(yt.isTimedTextUrl("https://www.youtube.com/api/timedtext?v=abc&lang=en&fmt=json3"), "timedtext url");
assert(yt.isTimedTextUrl("https://www.youtube.com/api/timedtext"), "timedtext no query");
assert(!yt.isTimedTextUrl("https://www.youtube.com/watch?v=dQw4w9wgGcQ"), "watch is not timedtext");
assert(!yt.isTimedTextUrl("https://www.youtube.com/youtubei/v1/player"), "player innertube is not timedtext");
assert(!yt.isTimedTextUrl("https://example.com/api/timedtext-not"), "lookalike");
assertEqual(yt.fmtHintFromUrl("https://www.youtube.com/api/timedtext?v=a&fmt=json3&lang=en"), "json3", "fmt hint");

const json3 = fs.readFileSync(path.join(__dirname, "fixtures/sample.youtube.json3"), "utf8");
const jsonCues = yt.parseTimedText(json3, "json3");
assertEqual(jsonCues.length, 3, "json3 count");
assertEqual(jsonCues[0].text, "Hello from YouTube", "json3 first");
assertEqual(jsonCues[0].start, 0, "json3 start");
assertEqual(jsonCues[0].end, 2.2, "json3 end");
assertEqual(jsonCues[1].text, "Second cue", "json3 joined segs");
assertEqual(jsonCues[2].text, "你好", "json3 chinese kept");

const srv1 = fs.readFileSync(path.join(__dirname, "fixtures/sample.youtube.srv1.xml"), "utf8");
const xmlCues = yt.parseTimedText(srv1, "srv1");
assertEqual(xmlCues.length, 3, "srv1 count");
assertEqual(xmlCues[0].start, 1.5, "srv1 start");
assertEqual(xmlCues[0].end, 3.5, "srv1 end");
assertEqual(xmlCues[0].text, "Hello from XML", "srv1 text");
assertEqual(xmlCues[1].text, "Second & last", "srv1 entity amp");
assertEqual(xmlCues[2].text, "'Quoted' line", "srv1 numeric entity");

const srv3 = '<timedtext format="3"><body><p t="1500" d="2000">Hello srv3</p><p t="4000" d="1000">Bye</p></body></timedtext>';
const srv3Cues = yt.parseTimedText(srv3);
assertEqual(srv3Cues.length, 2, "srv3 count");
assertEqual(srv3Cues[0].start, 1.5, "srv3 start");
assertEqual(srv3Cues[0].end, 3.5, "srv3 end");
assertEqual(srv3Cues[0].text, "Hello srv3", "srv3 text");

const jsonNoHint = yt.parseTimedText(json3);
assertEqual(jsonNoHint[0].text, "Hello from YouTube", "sniff json3");

let live = [];
live = yt.liveCueUpdate(live, "Hello now", 10);
assertEqual(live.length, 1, "live first");
assertEqual(live[0].text, "Hello now", "live text");
live = yt.liveCueUpdate(live, "Hello now", 10.4);
assertEqual(live.length, 1, "live extend same");
assert(live[0].end >= 11.65, "live end extended");
live = yt.liveCueUpdate(live, "Next line", 12);
assertEqual(live.length, 2, "live next");
assertEqual(live[0].end, 12, "previous closed");
live = yt.liveCueUpdate(live, "", 13);
assertEqual(live[1].end, 13, "empty closes current");

const fakeDoc = {
  querySelectorAll(selector) {
    if (selector.indexOf("ytp-caption-segment") !== -1) {
      return [{ textContent: "Hello " }, { textContent: "world" }];
    }
    return [];
  },
  querySelector() { return null; }
};
assertEqual(yt.collectDomCaptionText(fakeDoc), "Hello world", "dom segments");

const shadowSegment = { textContent: "Hello from shadow" };
const shadowRoot = {
  querySelectorAll(sel) {
    if (String(sel).indexOf("ytp-caption-segment") !== -1) return [shadowSegment];
    return [];
  }
};
const shadowHost = { shadowRoot, querySelectorAll() { return []; } };
const shadowDoc = {
  querySelectorAll(sel) {
    if (sel === "*") return [shadowHost];
    return [];
  },
  querySelector() { return null; }
};
assertEqual(yt.collectDomCaptionText(shadowDoc), "Hello from shadow", "shadow captions");

const parentDoc = { documentElement: { id: "html" }, body: { id: "body" } };
assertEqual(yt.overlayParentNode(parentDoc).id, "html", "overlay mounts on documentElement");
const fullDoc = { fullscreenElement: { id: "full" }, documentElement: { id: "html" } };
assertEqual(yt.overlayParentNode(fullDoc).id, "full", "overlay follows fullscreen");

const timed = [{ start: 0, end: 2, text: "Hello from YouTube" }];
const liveOnly = [{ start: 10, end: 12, text: "Hello now" }];
assertEqual(yt.selectCues(timed, liveOnly, 1)[0].text, "Hello from YouTube", "timedtext feeds overlay when active");
assertEqual(yt.selectCues(timed, liveOnly, 10.5)[0].text, "Hello now", "live fills overlay when timedtext misses");
assertEqual(yt.selectCues([], liveOnly, 10.5)[0].text, "Hello now", "dom fallback alone");
const livePaint = cues.overlayState({
  enabled: true,
  cues: liveOnly,
  time: 10.5,
  translations: { "Hello now": "现在你好" }
});
assertEqual(livePaint.cueText, "现在你好", "live cue paints chinese overlay");

assertEqual(yt.parseTimedText(")]}'\n" + json3)[0].text, "Hello from YouTube", "json3 xssi prefix");

const captionsOff = {
  querySelectorAll() { return []; },
  querySelector() { return null; }
};
assertEqual(yt.userCaptionsEnabledFromDom(captionsOff), false, "cc off");
const captionsOn = {
  querySelectorAll() { return []; },
  querySelector(selector) {
    if (String(selector).indexOf("ytp-subtitles-button") !== -1) {
      return { getAttribute(name) { return name === "aria-pressed" ? "true" : null; } };
    }
    return null;
  }
};
assertEqual(yt.userCaptionsEnabledFromDom(captionsOn), true, "cc button on");

const overlay = cues.overlayState({
  enabled: true,
  cues: jsonCues,
  time: 0.5,
  translations: { "Hello from YouTube": "来自 YouTube 的问候" }
});
assertDeep(overlay, { show: true, cueText: "来自 YouTube 的问候", message: "" }, "json3 overlay");

const missing = cues.overlayState({
  enabled: true,
  cues: [],
  time: 1,
  probed: true,
  noForeignMessage: yt.MESSAGES.noYouTubeCaptions
});
assertEqual(missing.message, "未检测到外语字幕（请先打开 YouTube 字幕）", "youtube empty hint");

const chineseOnly = cues.overlayState({
  enabled: true,
  cues: [{ start: 0, end: 1, text: "你好" }],
  time: 3,
  probed: true,
  noForeignMessage: yt.MESSAGES.noYouTubeCaptions
});
assertEqual(chineseOnly.message, "未检测到外语内容", "chinese-only keeps generic hint");

assertEqual(yt.cuesFor({}).length, 0, "no session cues in node");

const pageJs = fs.readFileSync(path.join(__dirname, "youtube-captions-page.js"), "utf8");
const isolatedJs = fs.readFileSync(path.join(__dirname, "youtube-captions.js"), "utf8");
assert(pageJs.indexOf("kind: \"hello\"") !== -1 || pageJs.indexOf('kind === "hello"') !== -1, "hello handshake");
assert(pageJs.indexOf("kind: \"bye\"") !== -1 || pageJs.indexOf('kind === "bye"') !== -1, "bye handshake");
assert(pageJs.indexOf("response.clone()") !== -1, "clone in-session body");
assert(pageJs.indexOf("origFetch.apply") !== -1, "wrap existing fetch");
assert(pageJs.indexOf("setOption") === -1, "never setOption");
assert(pageJs.indexOf("loadModule") === -1, "never loadModule");
assert(pageJs.indexOf("click(") === -1, "never click CC");
assert(pageJs.indexOf("pot=") === -1, "never copy pot");
assert(pageJs.indexOf("getUserMedia") === -1, "no getUserMedia in page");
assert(isolatedJs.indexOf("fetch(") === -1, "isolated never fetches");
assert(isolatedJs.toLowerCase().indexOf("whisper") === -1, "no whisper in isolated");
assert(pageJs.toLowerCase().indexOf("whisper") === -1, "no whisper in page");
assert(isolatedJs.indexOf("/api/timedtext") === -1, "isolated does not name timedtext path for fetching");
assert(pageJs.indexOf("https://www.youtube.com/api/timedtext?") === -1, "page does not build timedtext urls");
assert(pageJs.indexOf("post(\"live\"") !== -1 || pageJs.indexOf("post('live'") !== -1 || pageJs.indexOf('kind: "live"') !== -1, "page relays live captions");
assert(isolatedJs.indexOf("data.kind === \"live\"") !== -1, "isolated consumes live captions");
assert(isolatedJs.indexOf("overlayParentNode") !== -1, "overlay parent helper");
assert(isolatedJs.indexOf("selectCues") !== -1, "cue selection for overlay");

console.log("extension/youtube-captions.test.js ok");
