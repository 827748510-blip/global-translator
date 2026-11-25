#!/usr/bin/env node
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");

(async () => {
  let listener;
  const requests = [];
  const context = vm.createContext({
    chrome: { runtime: { onMessage: { addListener(fn) { listener = fn; } } } },
    fetch: async (url, options) => {
      requests.push({ url, options });
      return { ok: true, json: async () => ({ translations: ["邮票"], retry: [] }) };
    }
  });
  context.importScripts = (file) => vm.runInContext(fs.readFileSync(path.join(__dirname, file), "utf8"), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, "background.js"), "utf8"), context);
  const send = (message) => new Promise(resolve => assert.equal(listener(message, {}, resolve), true));
  assert.deepEqual(JSON.parse(JSON.stringify(await send({ type: "translate", texts: ["切手"], sourceLanguage: "ja" }))),
    { translations: ["邮票"], retry: [] });
  assert.deepEqual(JSON.parse(requests[0].options.body), { texts: ["切手"], sourceLanguage: "ja" });
  await send({ type: "translate", texts: ["Hello"], lane: "video" });
  assert.deepEqual(JSON.parse(requests[1].options.body), { texts: ["Hello"] });
  await send({ type: "translate", texts: ["普通中文"] });
  assert.deepEqual(JSON.parse(requests[2].options.body), { texts: ["普通中文"] });
  for (const { url, options } of requests) {
    assert.equal(url, "http://127.0.0.1:9233/translate");
    assert.equal(options.method, "POST");
  }

  const healthContext = vm.createContext({
    chrome: { runtime: { onMessage: { addListener(fn) { listener = fn; } } } },
    fetch: async (url, options) => {
      requests.push({ url, options });
      if (url.endsWith("/health")) {
        return {
          ok: true,
          json: async () => ({
            ok: true,
            videoTranslateEnabled: true,
            autoTranslateEnabled: false,
            backendReady: true,
            blockedReason: "桌面端未开启“自动翻译”",
            videoAsrStatus: "idle"
          })
        };
      }
      return { ok: true, json: async () => ({ ok: true, videoTranslateEnabled: true }) };
    }
  });
  healthContext.importScripts = (file) => vm.runInContext(fs.readFileSync(path.join(__dirname, file), "utf8"), healthContext);
  vm.runInContext(fs.readFileSync(path.join(__dirname, "background.js"), "utf8"), healthContext);
  const sendHealth = (message) => new Promise(resolve => assert.equal(listener(message, {}, resolve), true));
  const ping = await sendHealth({ type: "ping" });
  assert.equal(ping.ok, true);
  assert.equal(ping.autoTranslateEnabled, false);
  assert.equal(ping.backendReady, true);
  assert.equal(ping.blockedReason, "桌面端未开启“自动翻译”");
  const toggleRes = await sendHealth({ type: "set-video-translate", enabled: true });
  assert.equal(toggleRes.ok, true);
  assert.equal(toggleRes.videoTranslateEnabled, true);
  console.log("extension/background.test.js ok");
})().catch(error => { console.error(error); process.exitCode = 1; });
