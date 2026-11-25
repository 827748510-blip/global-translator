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

  // Material Symbols / icon classes / translate="no" / aria-hidden icon spans are skipped,
  // and Simplified Chinese pages misdeclared as lang="en" send zero bridge requests.
  async function runDomFixture({ lang, nodes }) {
    const sentMessages = [];
    const ctx = vm.createContext({
      GlobalTranslatorTextFilter: require("./text-filter.js"),
      MutationObserver: FakeMutationObserver,
      NodeFilter: {
        SHOW_ELEMENT: 1,
        SHOW_TEXT: 4,
        FILTER_REJECT: 2,
        FILTER_ACCEPT: 1,
        FILTER_SKIP: 3
      },
      getComputedStyle(el) {
        return {
          visibility: "visible",
          display: "block",
          opacity: "1",
          fontFamily: el && el._fontFamily ? el._fontFamily : "Inter, sans-serif"
        };
      },
      document: {
        documentElement: { lang },
        body: {},
        visibilityState: "visible",
        createTreeWalker() {
          let idx = 0;
          return {
            nextNode() {
              if (idx >= nodes.length) return null;
              return nodes[idx++];
            }
          };
        },
        addEventListener() {}
      },
      chrome: {
        storage: {
          local: { get(_defaults, cb) { cb({ enabled: true }); } },
          onChanged: { addListener() {} }
        },
        runtime: {
          lastError: null,
          sendMessage(msg, cb) {
            sentMessages.push(msg);
            setTimeout(() => cb({ translations: msg.texts.map((t) => "译:" + t), retry: [] }), 0);
          }
        }
      },
      setTimeout,
      clearTimeout
    });
    vm.runInContext(fs.readFileSync(path.join(__dirname, "content.js"), "utf8"), ctx);
    await new Promise((r) => setTimeout(r, 30));
    return sentMessages;
  }

  function makeRichTextNode(text, opts = {}) {
    const parent = {
      tagName: opts.tagName || "SPAN",
      className: opts.className || "",
      translate: opts.translate !== undefined ? opts.translate : true,
      _fontFamily: opts.fontFamily || "",
      getAttribute(name) {
        if (name === "aria-hidden" && opts.ariaHidden) return "true";
        if (name === "translate" && opts.translateAttr) return opts.translateAttr;
        if (name === "class") return parent.className;
        return null;
      },
      closest(selector) {
        if (opts.noTranslateAncestor && selector.includes("notranslate")) return {};
        return null;
      },
      getBoundingClientRect() { return { width: 24, height: 24 }; }
    };
    return { nodeType: 3, nodeValue: text, isConnected: true, parentElement: parent };
  }

  const iconHome = makeRichTextNode("home", { className: "material-symbols-outlined", ariaHidden: true });
  const iconFontSpan = makeRichTextNode("delete", { fontFamily: '"Material Symbols Outlined"' });
  const noTransSpan = makeRichTextNode("Do not translate me", { noTranslateAncestor: true });
  const ariaIcon = makeRichTextNode("video_library", { ariaHidden: true });
  const realEnglish = makeRichTextNode("Create new project");
  const iconFilterMsgs = await runDomFixture({
    lang: "en",
    nodes: [iconHome, iconFontSpan, noTransSpan, ariaIcon, realEnglish]
  });
  assert.equal(iconFilterMsgs.length, 1);
  assert.deepEqual(Array.from(iconFilterMsgs[0].texts), ["Create new project"]);
  assert.equal(iconHome.nodeValue, "home");
  assert.equal(iconFontSpan.nodeValue, "delete");
  assert.equal(noTransSpan.nodeValue, "Do not translate me");
  assert.equal(ariaIcon.nodeValue, "video_library");
  assert.equal(realEnglish.nodeValue, "译:Create new project");

  const chinesePageNodes = [
    makeRichTextNode("所有媒体"),
    makeRichTextNode("图片"),
    makeRichTextNode("视频"),
    makeRichTextNode("角色"),
    makeRichTextNode("场景"),
    makeRichTextNode("上传的内容"),
    makeRichTextNode("创建工具"),
    makeRichTextNode("回收站"),
    makeRichTextNode("home", { fontFamily: '"Material Symbols Outlined"' }),
    makeRichTextNode("Flow")
  ];
  const chinesePageMsgs = await runDomFixture({ lang: "en", nodes: chinesePageNodes });
  assert.equal(chinesePageMsgs.length, 0, "misdeclared Simplified Chinese page sends zero translate calls");
  console.log("extension/content.test.js ok");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
