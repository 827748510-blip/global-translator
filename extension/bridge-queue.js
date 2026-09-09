// Serial loopback queue for the extension service worker.
// Page translate and video-cue translate share one Ollama/bridge process, so
// requests stay one-at-a-time. Video cues jump ahead of queued page batches
// (not the in-flight call) so a busy YouTube comments pass cannot starve the
// overlay. Failures never cancel playback; this file only orders fetches.
(function (root) {
  function createBridgeQueue() {
    const items = [];
    let busy = false;

    function enqueue(work, lane) {
      return new Promise((resolve, reject) => {
        const job = {
          work,
          lane: lane === "video" ? "video" : "page",
          resolve,
          reject
        };
        if (job.lane === "video") {
          let i = 0;
          while (i < items.length && items[i].lane === "video") i++;
          items.splice(i, 0, job);
        } else {
          items.push(job);
        }
        pump();
      });
    }

    function pump() {
      if (busy) return;
      const job = items.shift();
      if (!job) return;
      busy = true;
      Promise.resolve()
        .then(() => job.work())
        .then(job.resolve, job.reject)
        .finally(() => {
          busy = false;
          pump();
        });
    }

    return { enqueue };
  }

  const api = { createBridgeQueue };
  root.GlobalTranslatorBridgeQueue = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
