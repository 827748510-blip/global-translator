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
  console.log("extension/background.test.js ok");
})().catch(error => { console.error(error); process.exitCode = 1; });
