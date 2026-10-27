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
  "API 设置",
  "使用 SwiftUI 构建 macOS 应用",
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
  "Visit https://example.com/help for instructions.",
  "Bonjour le monde",
  "Guten Morgen, wie geht es dir?",
  "Hola mundo",
  "こんにちは世界",
  "日本語のテキスト",
  "안녕하세요 세계",
  "Привет, мир",
  "مرحبا بالعالم",
  "שלום עולם",
  "Γειά σου κόσμε",
  "สวัสดีชาวโลก",
  "Xin chào thế giới",
  "नमस्ते दुनिया",
  "請使用本地模型"
];

for (const text of skipPage) {
  assertEqual(filter.shouldSendForPageTranslate(text), false, "skip " + JSON.stringify(text));
}
for (const text of sendPage) {
  assertEqual(filter.shouldSendForPageTranslate(text), true, "send " + JSON.stringify(text));
}

// Page language disambiguates kanji-only nodes: 日本 is Chinese when the page
// declares nothing, but Japanese when the page declares ja.
assertEqual(filter.shouldSendForPageTranslate("日本", "ja"), true, "kanji-only japanese page");
assertEqual(filter.shouldSendForPageTranslate("日本"), false, "kanji-only without page lang");
assertEqual(filter.shouldSendForPageTranslate("中文", "zh-TW"), true, "traditional page");
assertEqual(filter.shouldSendForPageTranslate("这是简体中文", "zh-CN"), false, "simplified page");
assertEqual(filter.shouldSendForPageTranslate("日本", "en"), false, "kanji with unrelated page lang");

assertEqual(filter.shouldTranslate("https://example.com/a"), false, "url");
assertEqual(filter.shouldTranslate("name@example.com"), false, "email");
assertEqual(filter.shouldTranslate("timeout_ms"), false, "snake");
assertEqual(filter.shouldTranslate("Hello world"), true, "sentence");

console.log("extension/text-filter.test.js ok");
