const checkbox = document.getElementById("enabled");
const status = document.getElementById("status");
const videoToggle = document.getElementById("videoTranslate");
const videoExtras = document.getElementById("videoExtras");
const pickSidecar = document.getElementById("pickSidecar");
const sidecarFile = document.getElementById("sidecarFile");
const sidecarName = document.getElementById("sidecarName");
const clearSidecar = document.getElementById("clearSidecar");
const sidecarError = document.getElementById("sidecarError");

const Cues = (typeof GlobalTranslatorSubtitleCues !== "undefined")
  ? GlobalTranslatorSubtitleCues
  : null;

function setVideoExtrasVisible(on) {
  videoExtras.hidden = !on;
}

function showSidecarMeta(name) {
  sidecarName.textContent = name ? ("已选：" + name) : "";
  clearSidecar.hidden = !name;
}

function setSidecarError(message) {
  sidecarError.textContent = message || "";
}

chrome.storage.local.get({ enabled: true, videoTranslateEnabled: false }, (prefs) => {
  checkbox.checked = prefs.enabled !== false;
  videoToggle.checked = prefs.videoTranslateEnabled === true;
  setVideoExtrasVisible(videoToggle.checked);
});

if (chrome.storage.session) {
  chrome.storage.session.get({ videoSidecar: null }, (value) => {
    const sidecar = value && value.videoSidecar;
    showSidecarMeta(sidecar && sidecar.name);
  });
}

checkbox.addEventListener("change", () => {
  chrome.storage.local.set({ enabled: checkbox.checked });
});

videoToggle.addEventListener("change", () => {
  const on = videoToggle.checked === true;
  chrome.storage.local.set({ videoTranslateEnabled: on });
  setVideoExtrasVisible(on);
  if (!on && chrome.storage.session) {
    chrome.storage.session.remove("videoSidecar");
    showSidecarMeta("");
    setSidecarError("");
  }
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
      setSidecarError("翻译服务不可用");
      return;
    }
    let parsed = [];
    try {
      parsed = Cues.parseSidecar(text, file.name);
    } catch (_error) {
      parsed = [];
    }
    if (parsed.length === 0) {
      setSidecarError("未检测到外语内容");
      return;
    }
    if (!Cues.hasForeignCues(parsed)) {
      setSidecarError("未检测到外语内容");
      return;
    }
    if (chrome.storage.session) {
      chrome.storage.session.set({ videoSidecar: { name: file.name, text } });
    }
    showSidecarMeta(file.name);
  };
  reader.onerror = () => {
    setSidecarError("翻译服务不可用");
  };
  reader.readAsText(file);
});

clearSidecar.addEventListener("click", () => {
  if (chrome.storage.session) chrome.storage.session.remove("videoSidecar");
  showSidecarMeta("");
  setSidecarError("");
});

chrome.runtime.sendMessage({ type: "ping" }, (response) => {
  if (chrome.runtime.lastError || !response || !response.ok) {
    status.textContent = "未连接：请确认菜单栏的 Global Translator 正在运行";
    status.className = "bad";
    return;
  }
  status.textContent = "已连接桌面端";
  status.className = "ok";
});
