// Serial loopback queue for the extension service worker.
// Page translate and video-cue translate share one Ollama/bridge process, so
// requests stay one-at-a-time. Video cues jump ahead of queued page batches
// (not the in-flight call) so a busy YouTube comments pass cannot starve the
// overlay. Failures never cancel playback; this file only orders fetches.
(function (root) {
  function createBridgeQueue(options) {
    const maxSize = (options && Number.isFinite(options.maxSize) && options.maxSize > 0)
      ? Math.floor(options.maxSize)
      : 64;
    const items = [];
    let busy = false;

    function enqueue(work, lane, tabId) {
      return new Promise((resolve, reject) => {
        const job = {
          work,
          lane: lane === "video" ? "video" : "page",
          tabId: tabId !== undefined && tabId !== null ? tabId : null,
          resolve,
          reject
        };
        if (items.length >= maxSize) {
          let evictIndex = -1;
          for (let i = 0; i < items.length; i++) {
            if (items[i].lane === "page") {
              evictIndex = i;
              break;
            }
          }
          if (evictIndex === -1 && job.lane === "video" && items.length > 0) {
            evictIndex = 0;
          }
          if (evictIndex === -1) {
            reject(new Error("bridge queue full"));
            return;
          }
          const evicted = items.splice(evictIndex, 1)[0];
          if (evicted) evicted.reject(new Error("bridge queue full"));
        }
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

    function cancelByTab(tabId) {
      if (tabId === undefined || tabId === null) return 0;
      let removed = 0;
      for (let i = items.length - 1; i >= 0; i--) {
        if (items[i].tabId === tabId) {
          const cancelled = items.splice(i, 1)[0];
          removed++;
          if (cancelled) cancelled.reject(new Error("tab cancelled"));
        }
      }
      return removed;
    }

    function size() {
      return items.length;
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

    return { enqueue, cancelByTab, size };
  }

  const api = { createBridgeQueue };
  root.GlobalTranslatorBridgeQueue = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
