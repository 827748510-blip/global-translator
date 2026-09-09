#!/usr/bin/env node
"use strict";

const { createBridgeQueue } = require("./bridge-queue");

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(label + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
  }
}

(async () => {
  const order = [];
  const q = createBridgeQueue();
  let releasePage;
  let pageStarted;
  const pageReady = new Promise((resolve) => { pageStarted = resolve; });
  const page1 = q.enqueue(() => new Promise((resolve) => {
    order.push("page-start");
    pageStarted();
    releasePage = resolve;
  }), "page");
  await pageReady;
  const page2 = q.enqueue(() => {
    order.push("page2");
  }, "page");
  const video = q.enqueue(() => {
    order.push("video");
  }, "video");
  assertEqual(order.join(","), "page-start", "in-flight page translate is not cancelled");
  releasePage();
  await Promise.all([page1, page2, video]);
  assertEqual(order.join(","), "page-start,video,page2", "video cue cuts in before queued page batches");

  const fifo = [];
  const q2 = createBridgeQueue();
  await Promise.all([
    q2.enqueue(() => { fifo.push("v1"); }, "video"),
    q2.enqueue(() => { fifo.push("v2"); }, "video")
  ]);
  assertEqual(fifo.join(","), "v1,v2", "video lane stays fifo among itself");

  console.log("extension/bridge-queue.test.js ok");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
