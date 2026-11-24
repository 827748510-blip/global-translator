#!/usr/bin/env node
"use strict";
// Launched by BridgeLanguageIntegrationTests with GT_BRIDGE_BROWSER=1.
// Requires an installed Playwright module/browser; never downloads either.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { chromium } = require(process.env.GT_PLAYWRIGHT_MODULE || "playwright");

async function main() {
  const bridgePort = Number(process.argv[2]);
  assert(Number.isInteger(bridgePort) && bridgePort > 0 && bridgePort <= 65535);
  const root = path.resolve(__dirname, "..");
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "gt-bridge-browser-"));
  const extension = path.join(temporary, "extension");
  fs.cpSync(path.join(root, "extension"), extension, { recursive: true });
  // Only this throwaway test copy targets the fixture's ephemeral port. Keep
  // the shipped manifest key, origin gate, and production scripts intact.
  const endpoint = "http://127.0.0.1:" + bridgePort;
  const backgroundFile = path.join(extension, "background.js");
  fs.writeFileSync(backgroundFile, fs.readFileSync(backgroundFile, "utf8").replace("http://127.0.0.1:9233", endpoint));
  const manifest = JSON.parse(fs.readFileSync(path.join(extension, "manifest.json"), "utf8"));
  manifest.host_permissions = [endpoint + "/*"];
  manifest.content_scripts = manifest.content_scripts.filter(entry => !entry.world);
  manifest.content_scripts[0].matches = ["http://127.0.0.1/*"];
  fs.writeFileSync(path.join(extension, "manifest.json"), JSON.stringify(manifest));

  const postLines = [
    "Qwen4 is coming.",
    "",
    "Deeper knowledge and stronger coding capabilities.",
    "",
    "普通中文",
    "https://example.com/info",
    "  Built for real-world tasks.  ",
    "",
    "Available now in preview.",
    "",
    "Token Plan: "
  ];
  const translatedPostLines = postLines.map((line, index) =>
    [0, 2, 6, 8, 10].includes(index) ? line.replace(line.trim(), "译文：" + line.trim()) : line
  );
  const fixtures = {
    "/ja": ['ja', '<p id="first">切手</p><p id="second">大丈夫</p>'],
    "/zh": ['zh-Hans', '<p id="first">普通中文</p>'],
    "/traditional": ['zh-TW', '<p id="first">歡迎使用</p>'],
    "/missing": ['', '<p id="first">普通中文</p><p id="second">Hello world</p>'],
    "/invalid": ['java', '<p id="first">普通中文</p><p id="second">Hello world</p>'],
    "/multiline": ['en', `<article><div data-testid="tweetText" style="white-space:pre-wrap"><span id="post">${postLines.join("\n")}</span><a id="plan" href="/token-plan">example.com/token-plan</a></div></article>`],
    "/video": ['ja', `<video width="640" height="360" controls></video><script>
      const track = document.querySelector('video').addTextTrack('subtitles', 'English', 'en');
      track.mode = 'hidden';
      track.addCue(new VTTCue(0, 10, 'Hello world'));
      track.addCue(new VTTCue(10, 20, '普通中文'));
    </script>`]
  };
  const server = http.createServer((request, response) => {
    const fixture = fixtures[request.url];
    response.writeHead(fixture ? 200 : 404, { "Content-Type": "text/html; charset=utf-8" });
    response.end(fixture ? `<!doctype html><html lang="${fixture[0]}"><head><meta charset="utf-8"></head><body>${fixture[1]}</body></html>` : "");
  });
  let context;
  try {
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const fixtureEndpoint = "http://127.0.0.1:" + server.address().port;
    context = await chromium.launchPersistentContext(path.join(temporary, "profile"), {
      executablePath: process.env.GT_CHROMIUM_PATH,
      headless: true,
      args: ["--disable-extensions-except=" + extension, "--load-extension=" + extension],
      viewport: { width: 1000, height: 700 }
    });
    const worker = context.serviceWorkers()[0] || await context.waitForEvent("serviceworker", { timeout: 10000 });
    assert.equal(new URL(worker.url()).protocol + "//" + new URL(worker.url()).host, "chrome-extension://fjggaipmhcfmgikhkjppkdliaoopaefc");
    const calls = [];
    const replies = [];
    const errors = [];
    context.on("request", request => {
      if (request.url() === endpoint + "/translate") calls.push(JSON.parse(request.postData()));
    });
    context.on("response", async response => {
      if (response.url() === endpoint + "/translate") replies.push(await response.json());
    });
    const page = context.pages()[0] || await context.newPage();
    page.on("pageerror", error => errors.push(String(error)));
    async function navigate(route) {
      await page.bringToFront();
      await page.goto(fixtureEndpoint + route);
    }
    async function textIs(id, value) {
      await page.waitForFunction(([id, value]) => document.getElementById(id)?.textContent === value, [id, value], { timeout: 7000 });
    }
    async function settle() { await page.waitForTimeout(1200); }

    await navigate("/ja");
    await textIs("first", "邮票");
    await textIs("second", "没关系");
    await settle();
    assert.equal(calls.length, 1, "own translated DOM must not be resubmitted");
    assert.deepEqual(calls[0], { texts: ["切手", "大丈夫"], sourceLanguage: "ja" });
    await page.evaluate(() => { document.getElementById("first").firstChild.nodeValue = "切手"; });
    await textIs("first", "邮票");
    await settle();
    assert.equal(calls.length, 1, "reverted source must reuse the node's translation");
    await page.evaluate(() => { document.getElementById("first").firstChild.nodeValue = "銀行"; });
    await textIs("first", "译文：銀行");
    await settle();
    assert.equal(calls.length, 2, "genuinely changed source must translate once");

    // Exercise the shipped video-translate.js against a synthetic TextTrack.
    // A ja page must never contaminate a subtitle's legacy, text-only request.
    await navigate("/video");
    await page.waitForSelector("[data-gt-video-translate]", { state: "attached" });
    await page.waitForFunction(() => document.querySelector("video").textTracks[0].cues.length === 2);
    for (let i = 0; i < 50 && calls.length < 3; i++) await page.waitForTimeout(100);
    assert.equal(calls.length, 3, "native subtitle must reach the bridge");
    assert.deepEqual(calls[2], { texts: ["Hello world"] });
    // Inspect the closed overlay via browser DevTools, without changing its
    // production visibility boundary or adding a test API to the extension.
    const devtools = await context.newCDPSession(page);
    let overlayHasChinese = false;
    for (let i = 0; i < 50 && !overlayHasChinese; i++) {
      const tree = await devtools.send("DOM.getDocument", { depth: -1, pierce: true });
      overlayHasChinese = JSON.stringify(tree).includes("你好世界");
      if (!overlayHasChinese) await page.waitForTimeout(100);
    }
    assert(overlayHasChinese, "subtitle overlay must display the fake backend's Chinese response");
    await devtools.detach();
    await settle();
    assert.equal(calls.length, 3, "subtitle overlay mutation must not feed page translation");

    await navigate("/zh");
    await settle();
    assert.equal(await page.locator("#first").textContent(), "普通中文");
    assert.equal(calls.length, 3, "ordinary Chinese must not request translation");
    await navigate("/traditional");
    await textIs("first", "欢迎使用");
    await settle();
    assert.equal(calls.length, 4);
    assert.equal(calls[3].sourceLanguage, "zh-tw");
    for (const route of ["/missing", "/invalid"]) {
      const before = calls.length;
      await navigate(route);
      await textIs("second", "你好世界");
      await settle();
      assert.equal(await page.locator("#first").textContent(), "普通中文");
      assert.equal(calls.length, before + 1);
      assert.deepEqual(calls.at(-1), { texts: ["Hello world"] });
    }

    const beforePost = calls.length;
    const sourcePost = postLines.join("\n");
    const translatedPost = translatedPostLines.join("\n");
    await navigate("/multiline");
    await textIs("post", translatedPost);
    await settle();
    assert.deepEqual(calls.slice(beforePost), [
      { texts: [postLines[0], postLines[2], postLines[6].trim()], sourceLanguage: "en" },
      { texts: [postLines[8], postLines[10].trim()], sourceLanguage: "en" }
    ]);
    assert.equal(await page.locator("#plan").getAttribute("href"), "/token-plan");
    assert.equal(await page.locator("#plan").textContent(), "example.com/token-plan");
    await page.locator("#post").evaluate((element, source) => {
      element.firstChild.nodeValue = source;
    }, sourcePost);
    await textIs("post", translatedPost);
    await settle();
    assert.equal(calls.length, beforePost + 2, "reverted multiline text must reuse the complete translation");
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ origin: new URL(worker.url()).protocol + "//" + new URL(worker.url()).host, calls, replies, checks: ["ja Han", "own mutations", "source revert", "source update", "native subtitle", "ordinary Chinese", "Traditional", "missing hint", "invalid hint", "multiline post", "post link", "multiline source revert"] }));
  } finally {
    if (context) await context.close();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
