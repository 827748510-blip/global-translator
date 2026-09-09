#!/usr/bin/env node
"use strict";

const filter = require("./text-filter");

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(label + ": expected " + expected + ", got " + actual);
  }
}

const skipPage = [
  "这是简体中文",
  "你好世界",
  "A",
  "123,!?",
  "https://example.com/a",
  "name@example.com",
  "/Users/example/file.txt",
  "timeout_ms",
  "getUserProfile",
  "TranslationSession",
  "package.json U",
  ".gitignore",
  "0xDEADBEEF",
  "v1.2.3",
  "32 GB",
  "60 FPS",
  "Swift 6 + SwiftUI + ScreenCaptureKit"
];

const sendPage = [
  "Translate this sentence",
  "Hello world",
  "Open",
  "SAVE",
  "Apply Settings",
  "Visit https://example.com/help for instructions."
];

for (const text of skipPage) {
  assertEqual(filter.shouldSendForPageTranslate(text), false, "skip " + JSON.stringify(text));
}
for (const text of sendPage) {
  assertEqual(filter.shouldSendForPageTranslate(text), true, "send " + JSON.stringify(text));
}

assertEqual(filter.shouldTranslate("https://example.com/a"), false, "url");
assertEqual(filter.shouldTranslate("name@example.com"), false, "email");
assertEqual(filter.shouldTranslate("timeout_ms"), false, "snake");
assertEqual(filter.shouldTranslate("Hello world"), true, "sentence");

console.log("extension/text-filter.test.js ok");
