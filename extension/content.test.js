#!/usr/bin/env node
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function makeTextNode(text) {
  return {
    nodeType: 3,
    nodeValue: text,
    isConnected: true,
    parentElement: {
      tagName: "P",
      closest() { return null; },
      getBoundingClientRect() { return { width: 120, height: 20 }; }
    }
  };
}

(async () => {
  const textNode = makeTextNode("Hello world");
  const storageListeners = [];
  let messageHandler = null;
  let visibility = "visible";

  class FakeMutationObserver {
    constructor(cb) { this.cb = cb; }
    observe() {}
    disconnect() {}
  }

  const context = vm.createContext({
    GlobalTranslatorTextFilter: require("./text-filter.js"),
    MutationObserver: FakeMutationObserver,
    NodeFilter: { SHOW_TEXT: 4 },
    getComputedStyle() { return { visibility: "visible", display: "block", opacity: "1" }; },
    document: {
      documentElement: { lang: "en" },
      body: {},
      get visibilityState() { return visibility; },
      createTreeWalker() {
        let done = false;
        return {
          nextNode() {
            if (done) return null;
            done = true;
            return textNode;
          }
        };
      },
      addEventListener() {}
    },
    chrome: {
      storage: {
        local: {
          get(_defaults, cb) { cb({ enabled: true }); }
        },
        onChanged: {
          addListener(fn) { storageListeners.push(fn); }
        }
      },
      runtime: {
        lastError: null,
        sendMessage(msg, cb) {
          messageHandler = msg;
          setTimeout(() => cb({ translations: ["你好，世界"], retry: [] }), 0);
        }
      }
    },
    setTimeout,
    clearTimeout
  });

  vm.runInContext(fs.readFileSync(path.join(__dirname, "content.js"), "utf8"), context);
  await new Promise((r) => setTimeout(r, 30));
  assert.ok(messageHandler && messageHandler.type === "translate");
  assert.equal(textNode.nodeValue, "你好，世界");

  // Disabling page translation restores the original text immediately.
  for (const listener of storageListeners) {
    listener({ enabled: { newValue: false } }, "local");
  }
  assert.equal(textNode.nodeValue, "Hello world");
  console.log("extension/content.test.js ok");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
