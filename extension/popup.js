const checkbox = document.getElementById("enabled");
const videoToggle = document.getElementById("videoTranslateToggle");
const status = document.getElementById("status");
const videoHint = document.getElementById("videoHint");
const videoExtras = document.getElementById("videoExtras");
const pickSidecar = document.getElementById("pickSidecar");
const sidecarFile = document.getElementById("sidecarFile");
const sidecarName = document.getElementById("sidecarName");
const clearSidecar = document.getElementById("clearSidecar");
const sidecarError = document.getElementById("sidecarError");

const Cues = (typeof GlobalTranslatorSubtitleCues !== "undefined")
  ? GlobalTranslatorSubtitleCues
  : null;

const hasStorage = typeof chrome !== "undefined" && chrome.storage && chrome.storage.local;
const hasSessionStorage = typeof chrome !== "undefined" && chrome.storage && chrome.storage.session;
let activeTabId = null;

function setVideoExtrasVisible(on) {
  videoExtras.hidden = !on;
  videoToggle.checked = !!on;
  videoHint.textContent = on
    ? "视频翻译已开启：优先读取当前网页/YouTube 字幕或加载本地 SRT/VTT；无外语字幕时使用本机音频转写。"
    : "视频字幕翻译当前已关闭；开启后会在网页视频底部叠加简体中文译文。";
}

function showSidecarMeta(name) {
  sidecarName.textContent = name ? ("当前标签页已选：" + name) : "";
  clearSidecar.hidden = !name;
}

function setSidecarError(message) {
  sidecarError.textContent = message || "";
}

function applyDesktopVideoPref(on) {
  if (hasStorage) {
    chrome.storage.local.set({ videoTranslateEnabled: on });
  }
  setVideoExtrasVisible(on);
}

function sidecarStorageKey(tabId) {
  return tabId != null ? ("videoSidecarTab_" + tabId) : "videoSidecar";
}

function notifyActiveTabSidecar(sidecar) {
  if (activeTabId == null || typeof chrome === "undefined" || !chrome.tabs || !chrome.tabs.sendMessage) return;
  try {
    chrome.tabs.sendMessage(activeTabId, { type: "set-sidecar", sidecar }, () => {
      void chrome.runtime.lastError;
    });
  } catch (_error) {}
}

function loadActiveTabSidecar() {
  if (!hasSessionStorage) return;
  const key = sidecarStorageKey(activeTabId);
  chrome.storage.session.get({ [key]: null }, (value) => {
    const sidecar = value && value[key];
    showSidecarMeta(sidecar && sidecar.name);
  });
}

if (hasStorage) {
  chrome.storage.local.get({ enabled: true, videoTranslateEnabled: false }, (prefs) => {
    checkbox.checked = prefs.enabled !== false;
    setVideoExtrasVisible(prefs.videoTranslateEnabled === true);
  });
}

if (typeof chrome !== "undefined" && chrome.tabs && chrome.tabs.query) {
  chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    void chrome.runtime.lastError;
    activeTabId = tabs && tabs[0] && typeof tabs[0].id === "number" ? tabs[0].id : null;
    loadActiveTabSidecar();
  });
} else {
  loadActiveTabSidecar();
}

checkbox.addEventListener("change", () => {
  if (hasStorage) {
    chrome.storage.local.set({ enabled: checkbox.checked });
  }
});

videoToggle.addEventListener("change", () => {
  const desired = videoToggle.checked;
  videoToggle.disabled = true;
  if (typeof chrome === "undefined" || !chrome.runtime || !chrome.runtime.sendMessage) {
    videoToggle.disabled = false;
    return;
  }
  chrome.runtime.sendMessage({ type: "set-video-translate", enabled: desired }, (response) => {
    videoToggle.disabled = false;
    if (chrome.runtime.lastError || !response || !response.ok) {
      videoToggle.checked = !desired;
      setSidecarError("未能同步到桌面端，请确认桌面应用正在运行。");
      return;
    }
    setSidecarError("");
    applyDesktopVideoPref(response.videoTranslateEnabled === true);
  });
});

pickSidecar.addEventListener("click", () => {
  sidecarFile.click();
});

sidecarFile.addEventListener("change", () => {
  const file = sidecarFile.files && sidecarFile.files[0];
  sidecarFile.value = "";
  setSidecarError("");
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    const text = typeof reader.result === "string" ? reader.result : "";
    if (!Cues) {
      setSidecarError("字幕解析组件未加载");
      return;
    }
    let parsed = [];
    try {
      parsed = Cues.parseSidecar(text, file.name);
    } catch (_error) {
      parsed = [];
    }
    if (parsed.length === 0) {
      setSidecarError("字幕文件格式无效或为空（仅支持 SRT/VTT）");
      return;
    }
    if (!Cues.hasForeignCues(parsed)) {
      setSidecarError("未检测到外语内容（当前字幕无需翻译）");
      return;
    }
    const sidecar = { name: file.name, text };
    if (hasSessionStorage) {
      chrome.storage.session.set({ [sidecarStorageKey(activeTabId)]: sidecar });
    }
    notifyActiveTabSidecar(sidecar);
    showSidecarMeta(file.name);
  };
  reader.onerror = () => {
    setSidecarError("读取本地字幕文件失败");
  };
  reader.readAsText(file);
});

clearSidecar.addEventListener("click", () => {
  if (hasSessionStorage) {
    chrome.storage.session.remove(sidecarStorageKey(activeTabId));
  }
  notifyActiveTabSidecar(null);
  showSidecarMeta("");
  setSidecarError("");
});

if (typeof chrome !== "undefined" && chrome.runtime && chrome.runtime.sendMessage) {
  chrome.runtime.sendMessage({ type: "ping" }, (response) => {
    if (chrome.runtime.lastError || !response || !response.ok) {
      status.textContent = "未连接：请确认菜单栏的 Global Translator 正在运行";
      status.className = "bad";
      videoToggle.disabled = true;
      return;
    }
    videoToggle.disabled = false;
    applyDesktopVideoPref(response.videoTranslateEnabled === true);
    if (!response.autoTranslateEnabled) {
      const reason = response.blockedReason ? ("（" + response.blockedReason + "）") : "";
      status.textContent = "已连接，但桌面端“自动翻译”未开启" + reason;
      status.className = "warn";
      return;
    }
    if (!response.backendReady) {
      status.textContent = "已连接，但桌面端翻译服务未就绪，请先测试连接";
      status.className = "warn";
      return;
    }
    status.textContent = "已连接桌面端，网页翻译就绪";
    status.className = "ok";
  });
}
