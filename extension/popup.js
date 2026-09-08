const checkbox = document.getElementById("enabled");
const status = document.getElementById("status");

chrome.storage.local.get({ enabled: true }, (prefs) => {
  checkbox.checked = prefs.enabled !== false;
});

checkbox.addEventListener("change", () => {
  chrome.storage.local.set({ enabled: checkbox.checked });
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
