const $ = selector => document.querySelector(selector);
let previewId = null;
let aiExchanges = [];
let aiImportMetadata = null;
let memoryExchanges = [];
let memoryLoaded = false;
let showMemorySummaries = false;
let noticeResolver = null;
let transcriptionSelection = null;
let transcriptionJobId = null;
let remoteMemoryJobId = null;
const safely = handler => async event => {
  try {
    await handler(event);
  } catch (error) {
    showError(error);
  }
};

function closeNotice(result) {
  const resolver = noticeResolver;
  noticeResolver = null;
  $("#noticeLayer").hidden = true;
  if (resolver) resolver(result);
}

function openNotice({ title = "提示", message, confirmText = "确定", cancelText = "" }) {
  if (noticeResolver) closeNotice(false);
  $("#noticeTitle").textContent = title;
  $("#noticeMessage").textContent = message;
  $("#noticeConfirm").textContent = confirmText;
  $("#noticeCancel").textContent = cancelText;
  $("#noticeCancel").hidden = !cancelText;
  $("#noticeLayer").hidden = false;
  requestAnimationFrame(() => $("#noticeConfirm").focus());
  return new Promise(resolvePromise => noticeResolver = resolvePromise);
}

function confirmNotice(message) {
  return openNotice({ title: "请确认", message, confirmText: "确认", cancelText: "取消" });
}

async function api(path, options) {
  const response = await fetch(path, {
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const envelope = await response.json();
  if (envelope.code !== 0) throw new Error(envelope.message);
  return envelope.data;
}

function renderTaskProgress(prefix, job) {
  const progress = $(`#${prefix}Progress`);
  progress.dataset.state = job.state;
  progress.querySelector(".taskProgressTrack span").style.width = `${Math.max(0, Math.min(100, job.percent))}%`;
  $(`#${prefix}Stage`).textContent = job.message;
  $(`#${prefix}Percent`).textContent = `${job.percent}%`;
  if (job.modelState === undefined) return;
  const modelProgress = $(`#${prefix}ModelProgress`);
  modelProgress.hidden = job.modelState === "idle";
  modelProgress.dataset.state = job.modelState;
  modelProgress.querySelector(".taskProgressTrack span").style.width = `${job.modelPercent}%`;
  $(`#${prefix}ModelStage`).textContent = job.modelMessage;
  $(`#${prefix}ModelPercent`).textContent = `${job.modelPercent}%`;
}

async function pollTranscription() {
  if (!transcriptionJobId) return;
  const job = await api(`/admin/api/transcription/${encodeURIComponent(transcriptionJobId)}`);
  renderTaskProgress("transcription", job);
  if (job.state === "running") {
    setTimeout(() => pollTranscription().catch(showError), 650);
    return;
  }
  $("#startTranscription").disabled = !transcriptionSelection;
  $("#cancelTranscription").disabled = true;
  if (job.state !== "done") return;
  $("#rawTranscript").value = job.rawText;
  $("#organizedTranscript").value = job.organizedText;
}

async function pollRemoteMemory() {
  if (!remoteMemoryJobId) return;
  const job = await api(`/admin/api/remote-memory/${encodeURIComponent(remoteMemoryJobId)}`);
  renderTaskProgress("remoteMemory", job);
  if (job.state === "running") {
    setTimeout(() => pollRemoteMemory().catch(showError), 650);
    return;
  }
  $("#startRemoteMemory").disabled = false;
  $("#cancelRemoteMemory").disabled = true;
  if (job.state === "cancelled") {
    remoteMemoryJobId = null;
    return;
  }
  if (job.state !== "done") {
    const reason = job.error || job.message || "未知错误";
    renderTaskProgress("remoteMemory", { ...job, message: `导入失败：${reason}` });
    remoteMemoryJobId = null;
    await openNotice({ title: "一键导入失败", message: reason });
    return;
  }
  renderTaskProgress("remoteMemory", { state: "running", percent: 100, message: "正在导入本地记忆" });
  let result;
  try {
    result = await api(`/admin/api/remote-memory/${encodeURIComponent(remoteMemoryJobId)}/import`, {
      method: "POST",
      body: "{}",
    });
  } catch (error) {
    renderTaskProgress("remoteMemory", { ...job, state: "failed", message: `导入失败：${error.message}` });
    remoteMemoryJobId = null;
    await openNotice({ title: "一键导入失败", message: error.message });
    return;
  }
  memoryLoaded = false;
  remoteMemoryJobId = null;
  renderMemoryStatus(result);
  renderTaskProgress("remoteMemory", {
    state: "done",
    percent: 100,
    message: `已导入 ${result.total} 封`,
  });
}

function renderStatus(status) {
  $("#statusCards").innerHTML = `
    <article>
      <span>本地服务</span>
      <strong>${status.ready ? "已就绪" : "未就绪"}</strong>
    </article>`;
}

function renderIdentity(identity) {
  $("#offlineUid").value = !identity.uid || String(identity.uid) === "0" ? "" : identity.uid;
  $("#offlineNickname").value = identity.nickname;
  $(".avatar").textContent = Array.from(identity.nickname || "")[0] || "";
}

function renderMemoryStatus(status) {
  const progress = $("#memoryProgress");
  const previousState = progress.dataset.state;
  progress.dataset.state = status.state;
  progress.className = `memoryProgress ${status.state}`;
  progress.style.display = "grid";
  const labels = {
    idle: "记忆整理完成",
    pending: "等待整理 · 点击继续",
    paused: "整理暂停 · 点击继续",
    running: status.progressStage === "bulk"
      ? "正在整理旧信合集"
      : status.progressTotal
        ? `逐封摘要 ${status.progressCurrent}/${status.progressTotal}`
        : "记忆整理中",
    failed: "记忆整理失败 · 点击重试",
  };
  const label = $(".memoryProgressLabel");
  label.textContent = labels[status.state] ?? "记忆状态未知";
  label.classList.toggle("loadingShine", status.state === "running");
  if (status.state === "running") label.dataset.shine = label.textContent;
  else delete label.dataset.shine;
  const percent = status.state === "idle"
    ? 100
    : Math.max(0, Math.min(100, Number(status.progressPercent) || 0));
  progress.querySelector(".memoryProgressTrack span").style.width = `${percent}%`;
  progress.title = status.state === "failed" ? status.error ?? "记忆整理失败" : "";
  if (status.state === "idle" && previousState && previousState !== "idle" && memoryLoaded)
    loadMemory().catch(showError);
}

function renderClientMountStatus(status) {
  const badge = $("#serviceMountStatus");
  $("#clientExe").value = status.clientExe ?? "";
  badge.className = `mountStatus ${status.mounted ? "mounted" : "unmounted"}`;
  badge.textContent = status.mounted ? "服务已挂载" : "服务未挂载";
  if (!status.clientSelected) {
    $("#serviceMountDetail").textContent = "请先选择游戏 exe";
  } else if (status.mounted) {
    const synchronized = status.port === status.servicePort;
    $("#serviceMountDetail").textContent = synchronized
      ? ""
      : `客户端端口 ${status.port}，本机服务端口 ${status.servicePort}`;
  } else {
    $("#serviceMountDetail").textContent = `客户端使用原服务，本机服务端口 ${status.servicePort}`;
  }
  $("#mountService").hidden = status.mounted;
  $("#restoreClient").hidden = !status.mounted;
  $("#mountService").disabled = !status.clientSelected;
  $("#restoreClient").disabled = !status.clientSelected;
}

function renderDeepSeek(config) {
  $("#apiKey").value = config.apiKey;
  $("#apiKey").placeholder = "填写 API Key，默认 DeepSeek";
  $("#apiKey").type = "password";
  $("#toggleApiKey").classList.remove("isVisible");
  $("#toggleApiKey").title = "显示 API Key";
  $("#toggleApiKey").setAttribute("aria-label", "显示 API Key");
  $("#customModel").checked = config.custom;
  $("#modelName").value = config.model;
  $("#modelBaseUrl").value = config.baseUrl;
  $("#customFields").hidden = !config.custom;
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/gu, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}

function resetImportPreview() {
  previewId = null;
  aiExchanges = [];
  aiImportMetadata = null;
  $("#confirmImport").disabled = true;
  $("#importResult").textContent = "内容已修改，请重新识别";
}

function formatImportPreview(result) {
  const findings = result.findings.length ? `\n\n校验结果：\n${result.findings.join("\n")}` : "";
  const exchanges = result.exchanges.map((exchange, index) =>
    `往来 ${String(index + 1).padStart(2, "0")} · ${exchange.date || "日期未注明"} ${exchange.time || "12:00"}\n\n来信：\n${exchange.incoming}\n\n林离回信：\n${exchange.reply}`)
    .join("\n\n━━━━━━━━━━━━━━━━━━━━\n\n");
  return `共 ${result.exchangeCount} 组往来${findings}\n\n${exchanges}`;
}

async function previewAiExchanges() {
  const result = await api("/admin/api/memory/import/preview", {
    method: "POST",
    body: JSON.stringify({ exchanges: aiExchanges }),
  });
  previewId = result.blocked ? null : "ready";
  $("#confirmImport").disabled = !previewId;
  $("#importResult").textContent = formatImportPreview(result);
  return result;
}

function startLoading(selector, text) {
  const element = $(selector);
  element.textContent = text;
  element.dataset.shine = text;
  element.classList.add("loadingShine");
}

function stopLoading(selector) {
  const element = $(selector);
  element.classList.remove("loadingShine");
  delete element.dataset.shine;
}

function localToday() {
  const date = new Date();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}

function renderMemoryList() {
  $("#memoryList").innerHTML = memoryExchanges.length ? memoryExchanges.map((exchange, index) => {
    const summary = showMemorySummaries && exchange.summary ? `
      <div class="letterSummary">
        <span>逐封摘要 · ${escapeHtml(exchange.contentMd5.slice(0, 8))}</span>
        <p>${escapeHtml(exchange.summary)}</p>
      </div>` : "";
    const videoStatus = exchange.replyVideoUrl
      ? `<a href="${escapeHtml(exchange.replyVideoUrl)}" target="_blank" rel="noreferrer">已上传 MP4</a>`
      : `<span>${exchange.letterId ? "未上传" : "请先确认保存这封信"}</span>`;
    const videoAction = exchange.replyVideoUrl
      ? `<button class="secondary compact danger" type="button" data-action="remove-video">移除视频</button>`
      : `<label class="fileButton">
          加入视频
          <input type="file" data-action="video-file" accept=".mp4,video/mp4" ${exchange.letterId ? "" : "disabled"}>
        </label>`;
    return `<article class="exchangeCard" data-index="${index}">
      <div class="exchangeHead">
        <strong>往来 ${String(memoryExchanges.length - index).padStart(2, "0")}</strong>
        <input type="date" data-field="date" value="${escapeHtml(exchange.date)}" aria-label="往来日期">
        <input type="time" data-field="time" value="${escapeHtml(exchange.time || "12:00")}" aria-label="往来时间">
        <div class="exchangeActions">
          <button class="secondary compact" type="button" data-action="insert-above">上方插入</button>
          <button class="secondary compact" type="button" data-action="up" ${index === 0 ? "disabled" : ""} title="上移">↑</button>
          <button class="secondary compact" type="button" data-action="down" ${index === memoryExchanges.length - 1 ? "disabled" : ""} title="下移">↓</button>
          <button class="secondary compact danger" type="button" data-action="remove">删除</button>
        </div>
      </div>
      <label>来信</label>
      <textarea data-field="incoming">${escapeHtml(exchange.incoming)}</textarea>
      <label>林离回信</label>
      <textarea data-field="reply">${escapeHtml(exchange.reply)}</textarea>
      <div class="videoAttachment">
        <div>
          <strong>视频回信</strong>
          ${videoStatus}
        </div>
        <div class="videoActions">
          ${videoAction}
        </div>
      </div>
      ${summary}
      <div class="cardConfirm">
        <button type="button" data-action="save" ${exchange.dirty ? "" : "hidden"}>确认修改</button>
      </div>
    </article>`;
  }).join("") : `<p class="empty">还没有信件记忆。</p>`;
}

async function loadMemory() {
  const result = await api("/admin/api/memory");
  memoryExchanges = result.exchanges.map(exchange => ({ ...exchange, dirty: false }));
  memoryLoaded = true;
  renderMemoryList();
}

async function saveMemory() {
  for (const exchange of memoryExchanges)
    if (!exchange.time) exchange.time = "12:00";
  const result = await api("/admin/api/memory", {
    method: "POST",
    body: JSON.stringify({ exchanges: memoryExchanges }),
  });
  memoryExchanges.forEach(exchange => exchange.dirty = false);
  renderMemoryList();
  renderMemoryStatus(result);
  $("#memoryResult").textContent = memoryExchanges.length ? "已保存，等待整理" : "";
}

async function refresh() {
  const [status, identity, deepSeek, memoryStatus] = await Promise.all([
    api("/admin/api/status"),
    api("/admin/api/identity"),
    api("/admin/api/deepseek"),
    api("/admin/api/memory/status"),
  ]);
  renderStatus(status);
  renderIdentity(identity);
  renderDeepSeek(deepSeek);
  renderMemoryStatus(memoryStatus);
  if (window.oliviaDesktop) renderClientMountStatus(await window.oliviaDesktop.getClientStatus());
}

async function refreshStatus() {
  const [status, memoryStatus] = await Promise.all([
    api("/admin/api/status"),
    api("/admin/api/memory/status"),
  ]);
  renderStatus(status);
  renderMemoryStatus(memoryStatus);
}

async function loadDesktopSettings() {
  if (!window.oliviaDesktop) return;
  $("#desktopSettings").hidden = false;
  $("#serviceMountSettings").hidden = false;
  const [settings, clientStatus] = await Promise.all([
    window.oliviaDesktop.getSettings(),
    window.oliviaDesktop.getClientStatus(),
  ]);
  $("#autoStart").checked = settings.autoStart;
  $("#servicePort").value = settings.port;
  renderClientMountStatus(clientStatus);
}

function renderDebug(data) {
  $("#debugDelay").value = data.delaySeconds;
  $("#debugDelayLabel").textContent = `回信最小延迟（${data.delaySeconds}秒）`;
  $("#debugQuotaStatus").textContent = `今天还可发送 ${data.remainingToday} 封`;
  const show = $("#showSummaries").checked;
  $("#debugSummaries").hidden = !show;
  if (!show) return;
  $("#bulkSummarySection").hidden = !data.bulkSummary;
  $("#bulkSummary").textContent = data.bulkSummary;
}

async function loadDebug() {
  renderDebug(await api("/admin/api/debug"));
}

$("#noticeConfirm").addEventListener("click", () => closeNotice(true));
$("#noticeCancel").addEventListener("click", () => closeNotice(false));
$("#noticeClose").addEventListener("click", () => closeNotice(false));
document.addEventListener("keydown", event => {
  const target = event.target;
  const editable = target instanceof HTMLInputElement
    || target instanceof HTMLTextAreaElement
    || target.isContentEditable;
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "a" && !editable) {
    event.preventDefault();
    return;
  }
  if ($("#noticeLayer").hidden) return;
  if (event.key === "Escape") closeNotice(false);
  if (event.key === "Enter") closeNotice(true);
});
document.querySelectorAll(".sideTab").forEach(button => {
  button.addEventListener("click", safely(async () => {
    document.querySelectorAll(".sideTab").forEach(tab => tab.classList.toggle("active", tab === button));
    document.querySelectorAll(".tabPage").forEach(page => page.hidden = page.dataset.page !== button.dataset.tab);
    if (button.dataset.tab === "memory" && !memoryLoaded) await loadMemory();
    if (button.dataset.tab === "debug") await loadDebug();
  }));
});
document.querySelectorAll(".memoryTab").forEach(button => {
  button.addEventListener("click", safely(async () => {
    document.querySelectorAll(".memoryTab").forEach(tab => tab.classList.toggle("active", tab === button));
    document.querySelectorAll(".memoryView").forEach(view => view.hidden = view.dataset.memoryView !== button.dataset.memoryTab);
    if (button.dataset.memoryTab === "manage" && !memoryLoaded) await loadMemory();
  }));
});
$("#selectTranscriptionMedia").addEventListener("click", safely(async () => {
  if (!window.oliviaDesktop?.selectMediaFile) {
    $("#transcriptionMediaFile").click();
    return;
  }
  const selected = await window.oliviaDesktop.selectMediaFile();
  if (selected.cancelled) return;
  transcriptionSelection = { path: selected.path, name: selected.name };
  $("#transcriptionFileName").textContent = selected.name;
  $("#startTranscription").disabled = false;
}));
$("#transcriptionMediaFile").addEventListener("change", event => {
  const file = event.target.files[0];
  if (!file) return;
  transcriptionSelection = { file, name: file.name };
  $("#transcriptionFileName").textContent = file.name;
  $("#startTranscription").disabled = false;
});
$("#startTranscription").addEventListener("click", safely(async () => {
  if (!transcriptionSelection) throw new Error("请先选择视频或音频");
  $("#startTranscription").disabled = true;
  $("#selectTranscriptionMedia").disabled = true;
  $("#cancelTranscription").disabled = false;
  $("#rawTranscript").value = "";
  $("#organizedTranscript").value = "";
  renderTaskProgress("transcription", {
    state: "running",
    percent: 0,
    message: "正在创建转写任务",
    modelState: "idle",
    modelPercent: 0,
    modelMessage: "",
  });
  try {
    const job = transcriptionSelection.file
      ? await api(`/admin/api/transcription/upload?name=${encodeURIComponent(transcriptionSelection.name)}`, {
        method: "POST",
        headers: { "Content-Type": transcriptionSelection.file.type || "application/octet-stream" },
        body: transcriptionSelection.file,
      })
      : await api("/admin/api/transcription", {
        method: "POST",
        body: JSON.stringify({ path: transcriptionSelection.path }),
      });
    transcriptionJobId = job.id;
    renderTaskProgress("transcription", job);
    pollTranscription().catch(showError);
  } finally {
    $("#selectTranscriptionMedia").disabled = false;
    if (!transcriptionJobId) {
      $("#startTranscription").disabled = false;
      $("#cancelTranscription").disabled = true;
    }
  }
}));
$("#cancelTranscription").addEventListener("click", safely(async () => {
  if (!transcriptionJobId) return;
  renderTaskProgress("transcription", await api(
    `/admin/api/transcription/${encodeURIComponent(transcriptionJobId)}/cancel`,
    { method: "POST", body: "{}" },
  ));
}));
$("#startRemoteMemory")?.addEventListener("click", safely(async () => {
  if (!await confirmNotice("远端记忆会覆盖当前记忆。是否继续？")) return;
  $("#startRemoteMemory").disabled = true;
  $("#cancelRemoteMemory").disabled = false;
  renderTaskProgress("remoteMemory", {
    state: "running",
    percent: 0,
    message: "正在读取远端记忆",
    modelState: "idle",
    modelPercent: 0,
    modelMessage: "",
  });
  try {
    const job = await api("/admin/api/remote-memory", { method: "POST", body: "{}" });
    remoteMemoryJobId = job.id;
    renderTaskProgress("remoteMemory", job);
    pollRemoteMemory().catch(showError);
  } finally {
    if (!remoteMemoryJobId) {
      $("#startRemoteMemory").disabled = false;
      $("#cancelRemoteMemory").disabled = true;
    }
  }
}));
$("#cancelRemoteMemory")?.addEventListener("click", safely(async () => {
  if (!remoteMemoryJobId) return;
  renderTaskProgress("remoteMemory", await api(
    `/admin/api/remote-memory/${encodeURIComponent(remoteMemoryJobId)}/cancel`,
    { method: "POST", body: "{}" },
  ));
}));
$("#memoryProgress").addEventListener("click", safely(async () => {
  if (!["pending", "paused", "failed"].includes($("#memoryProgress").dataset.state)) return;
  renderMemoryStatus({ state: "running", error: null });
  renderMemoryStatus(await api("/admin/api/memory/refresh", { method: "POST", body: "{}" }));
}));
$("#toggleApiKey").addEventListener("click", event => {
  const visible = $("#apiKey").type === "text";
  $("#apiKey").type = visible ? "password" : "text";
  event.currentTarget.classList.toggle("isVisible", !visible);
  event.currentTarget.title = visible ? "显示 API Key" : "隐藏 API Key";
  event.currentTarget.setAttribute("aria-label", event.currentTarget.title);
});
$("#customModel").addEventListener("change", safely(async event => {
  $("#customFields").hidden = !event.target.checked;
  await saveDeepSeekConfig();
}));
$("#autoStart").addEventListener("change", safely(async event => {
  const requested = event.target.checked;
  try {
    event.target.checked = (await window.oliviaDesktop.setAutoStart(requested)).autoStart;
  } catch (error) {
    event.target.checked = !requested;
    throw error;
  }
}));
$("#showSummaries").addEventListener("change", safely(async event => {
  showMemorySummaries = event.target.checked;
  if (showMemorySummaries) await Promise.all([loadDebug(), loadMemory()]);
  else $("#debugSummaries").hidden = true;
  renderMemoryList();
}));
$("#debugDelay").addEventListener("change", safely(async () => {
  const result = await api("/admin/api/debug/delay", {
    method: "POST",
    body: JSON.stringify({ seconds: Number($("#debugDelay").value) }),
  });
  $("#debugDelay").value = result.delaySeconds;
  $("#debugDelayLabel").textContent = `回信最小延迟（${result.delaySeconds}秒）`;
  $("#debugDelayResult").textContent = "";
}));
$("#defaultDebugDelay").addEventListener("click", safely(async () => {
  const result = await api("/admin/api/debug/delay/default", { method: "POST", body: "{}" });
  $("#debugDelay").value = result.delaySeconds;
  $("#debugDelayLabel").textContent = `回信最小延迟（${result.delaySeconds}秒）`;
  $("#debugDelayResult").textContent = "已恢复默认";
}));
$("#resetTodayQuota").addEventListener("click", safely(async () => {
  if (!await confirmNotice("确认重置今天的信件次数？")) return;
  const result = await api("/admin/api/debug/quota/reset", { method: "POST", body: "{}" });
  $("#debugQuotaStatus").textContent = `今天还可发送 ${result.remainingToday} 封`;
}));
$("#selectClient").addEventListener("click", safely(async () => {
  const status = await window.oliviaDesktop.selectClient();
  renderClientMountStatus(status);
  if (status.selectionChanged) $("#serviceMountResult").textContent = "已选择客户端";
}));
$("#mountService").addEventListener("click", safely(async () => {
  $("#mountService").disabled = true;
  $("#restoreClient").disabled = true;
  startLoading("#serviceMountResult", "正在启用本机服务……");
  try {
    const status = await window.oliviaDesktop.mountClient($("#servicePort").value);
    renderClientMountStatus(status);
    $("#serviceMountResult").textContent = "";
  } finally {
    $("#mountService").disabled = false;
    stopLoading("#serviceMountResult");
    window.oliviaDesktop.getClientStatus().then(renderClientMountStatus).catch(console.error);
  }
}));
$("#restoreClient").addEventListener("click", safely(async () => {
  if (!await confirmNotice("确认停用客户端本机信件服务？本机后台仍会继续运行。")) return;
  $("#mountService").disabled = true;
  $("#restoreClient").disabled = true;
  startLoading("#serviceMountResult", "正在停用服务……");
  try {
    const status = await window.oliviaDesktop.restoreClient();
    renderClientMountStatus(status);
    $("#serviceMountResult").textContent = "服务已停用";
  } finally {
    $("#mountService").disabled = false;
    stopLoading("#serviceMountResult");
    window.oliviaDesktop.getClientStatus().then(renderClientMountStatus).catch(console.error);
  }
}));
const saveIdentity = safely(async () => {
  const identity = await api("/admin/api/identity", {
    method: "POST",
    body: JSON.stringify({
      uid: $("#offlineUid").value,
      nickname: $("#offlineNickname").value,
    }),
  });
  renderIdentity(identity);
  $("#identityResult").textContent = "已自动保存";
});
$("#offlineUid").addEventListener("change", saveIdentity);
$("#offlineNickname").addEventListener("change", saveIdentity);
async function saveDeepSeekConfig() {
  const result = await api("/admin/api/deepseek", {
    method: "POST",
    body: JSON.stringify({
      apiKey: $("#apiKey").value,
      custom: $("#customModel").checked,
      model: $("#modelName").value,
      baseUrl: $("#modelBaseUrl").value,
    }),
  });
  renderDeepSeek(result);
  $("#deepSeekResult").textContent = "已自动保存";
}
const saveDeepSeek = safely(saveDeepSeekConfig);
$("#apiKey").addEventListener("change", saveDeepSeek);
$("#modelName").addEventListener("change", saveDeepSeek);
$("#modelBaseUrl").addEventListener("change", saveDeepSeek);
$("#testDeepSeek").addEventListener("click", safely(async () => {
  $("#deepSeekResult").textContent = "正在测试……";
  await api("/admin/api/deepseek/test", {
    method: "POST",
    body: JSON.stringify({
      apiKey: $("#apiKey").value,
      custom: $("#customModel").checked,
      model: $("#modelName").value,
      baseUrl: $("#modelBaseUrl").value,
    }),
  });
  $("#deepSeekResult").textContent = "连接成功";
}));
$("#importContent").addEventListener("input", resetImportPreview);
$("#aiImport").addEventListener("click", safely(async () => {
  $("#aiImport").disabled = true;
  $("#confirmImport").disabled = true;
  previewId = null;
  aiExchanges = [];
  aiImportMetadata = null;
  let recognized = false;
  startLoading("#aiImportResult", "正在识别信件……");
  try {
    const result = await api("/admin/api/import/ai", {
      method: "POST",
      body: JSON.stringify({ content: $("#importContent").value }),
    });
    aiExchanges = result.exchanges;
    aiImportMetadata = {
      person: result.person,
      source: result.source,
      order: result.order,
      oldMemory: result.oldMemory,
    };
    recognized = true;
    startLoading("#aiImportResult", `已识别 ${aiExchanges.length} 组，正在校验……`);
    const preview = await previewAiExchanges();
    $("#aiImportResult").textContent = preview.blocked
      ? "识别结果未通过校验"
      : `AI 识别完成，已列出 ${aiExchanges.length} 组往来`;
  } catch (error) {
    $("#confirmImport").disabled = true;
    $("#importResult").textContent = error.message;
    $("#aiImportResult").textContent = recognized ? "识别结果格式不合法" : "识别失败";
    throw error;
  } finally {
    $("#aiImport").disabled = false;
    stopLoading("#aiImportResult");
  }
}));
$("#confirmImport").addEventListener("click", safely(async () => {
  if (!previewId) throw new Error("请先完成 AI 识别");
  $("#aiImport").disabled = true;
  $("#confirmImport").disabled = true;
  startLoading("#aiImportResult", "正在导入并整理记忆……");
  try {
    const result = await api("/admin/api/memory/import", {
      method: "POST",
      body: JSON.stringify({ ...aiImportMetadata, exchanges: aiExchanges }),
    });
    previewId = null;
    aiExchanges = [];
    aiImportMetadata = null;
    $("#importContent").value = "";
    $("#importResult").textContent = `导入完成：记忆新增 ${result.imported}，信箱新增 ${result.mailboxImported}，跳过 ${result.skipped}`;
    $("#aiImportResult").textContent = result.state === "running" ? "导入完成，记忆正在整理" : "导入完成";
    renderMemoryStatus(result);
    memoryLoaded = false;
    document.querySelector('[data-memory-tab="manage"]').click();
  } finally {
    $("#aiImport").disabled = false;
    $("#confirmImport").disabled = !previewId;
    stopLoading("#aiImportResult");
  }
}));
$("#selectSoul").addEventListener("click", () => $("#soulFile").click());
$("#soulFile").addEventListener("change", safely(async event => {
  const file = event.target.files[0];
  if (!file) return;
  if (!file.name.toLowerCase().endsWith(".soul")) {
    event.target.value = "";
    throw new Error("请选择 .soul 文件");
  }
  const firstConfirmed = await openNotice({
    title: ".soul 导入",
    message: "将覆盖当前全部记忆",
    confirmText: "继续",
    cancelText: "取消",
  });
  if (!firstConfirmed) {
    event.target.value = "";
    return;
  }
  const secondConfirmed = await openNotice({
    title: "再次确认",
    message: ".soul导入是覆盖式的！确保您已没有要保留的记忆！",
    confirmText: "确认覆盖",
    cancelText: "取消",
  });
  if (!secondConfirmed) {
    event.target.value = "";
    return;
  }
  $("#selectSoul").disabled = true;
  startLoading("#soulImportResult", "正在覆盖导入 .soul 信件与视频……");
  try {
    const result = await api("/admin/api/memory/import/soul", {
      method: "POST",
      headers: { "Content-Type": "application/x-olivia-soul" },
      body: file,
    });
    $("#soulImportResult").textContent = result.state === "running"
      ? `已覆盖 ${result.total} 组记忆和 ${result.videosImported} 个视频，正在整理`
      : `已覆盖 ${result.total} 组记忆和 ${result.videosImported} 个视频`;
    renderMemoryStatus(result);
    memoryLoaded = false;
    document.querySelector('[data-memory-tab="manage"]').click();
  } finally {
    event.target.value = "";
    $("#selectSoul").disabled = false;
    stopLoading("#soulImportResult");
  }
}));
$("#exportMemory").addEventListener("click", safely(async () => {
  if (!window.oliviaDesktop?.exportSoul) {
    $("#memoryResult").textContent = "请在桌面版中导出 .soul";
    return;
  }
  try {
    const result = await window.oliviaDesktop.exportSoul();
    $("#memoryResult").textContent = result.cancelled ? "已取消导出" : `已导出到 ${result.path}`;
  } catch (error) {
    if (error.message.includes("暂无记忆")) {
      $("#memoryResult").textContent = "无记忆可导出";
      return;
    }
    throw error;
  }
}));
$("#newMemoryExchange").addEventListener("click", () => {
  memoryExchanges.unshift({
    date: localToday(),
    time: "12:00",
    incoming: "",
    reply: "",
    replyLabel: "回信",
    dirty: true,
  });
  renderMemoryList();
  $("#memoryList .exchangeCard:first-child textarea").focus();
});
$("#memoryList").addEventListener("input", event => {
  const field = event.target.dataset.field;
  if (!field) return;
  const index = Number(event.target.closest(".exchangeCard").dataset.index);
  memoryExchanges[index][field] = event.target.value;
  memoryExchanges[index].dirty = true;
  memoryExchanges[index].summary = "";
  memoryExchanges[index].contentMd5 = "";
  event.target.closest(".exchangeCard").querySelector('[data-action="save"]').hidden = false;
});
$("#memoryList").addEventListener("change", safely(async event => {
  if (event.target.dataset.action !== "video-file") return;
  const file = event.target.files[0];
  if (!file) return;
  if (!file.name.toLowerCase().endsWith(".mp4")) throw new Error("请选择 MP4 视频");
  if (file.size > 512 * 1024 * 1024) throw new Error("视频不能超过 512 MB");
  const index = Number(event.target.closest(".exchangeCard").dataset.index);
  const exchange = memoryExchanges[index];
  const result = await api(`/admin/api/letters/${encodeURIComponent(exchange.letterId)}/video`, {
    method: "POST",
    headers: { "Content-Type": "video/mp4" },
    body: file,
  });
  exchange.replyVideoUrl = result.replyVideoUrl;
  renderMemoryList();
  $("#memoryResult").textContent = "视频已上传";
}));
$("#memoryList").addEventListener("click", safely(async event => {
  const button = event.target.closest("button[data-action]");
  if (!button) return;
  const index = Number(button.closest(".exchangeCard").dataset.index);
  if (button.dataset.action === "save") return saveMemory();
  if (button.dataset.action === "insert-above") {
    memoryExchanges.splice(index, 0, {
      date: localToday(),
      time: "12:00",
      incoming: "",
      reply: "",
      replyLabel: "回信",
      dirty: true,
    });
    renderMemoryList();
    document.querySelector(`.exchangeCard[data-index="${index}"] textarea`).focus();
    return;
  }
  if (button.dataset.action === "remove") {
    if (!await confirmNotice("确认删除这组往来？")) return;
    memoryExchanges.splice(index, 1);
    return saveMemory();
  }
  if (button.dataset.action === "remove-video") {
    if (!await confirmNotice("确认移除这封信的视频？")) return;
    await api(`/admin/api/letters/${encodeURIComponent(memoryExchanges[index].letterId)}/video`, { method: "DELETE" });
    memoryExchanges[index].replyVideoUrl = null;
    renderMemoryList();
    $("#memoryResult").textContent = "视频已移除";
    return;
  }
  if (button.dataset.action === "up" && index > 0)
    [memoryExchanges[index - 1], memoryExchanges[index]] = [memoryExchanges[index], memoryExchanges[index - 1]];
  if (button.dataset.action === "down" && index < memoryExchanges.length - 1)
    [memoryExchanges[index + 1], memoryExchanges[index]] = [memoryExchanges[index], memoryExchanges[index + 1]];
  await saveMemory();
}));

function showError(error) {
  void openNotice({ title: "操作失败", message: error.message });
}

Promise.all([refresh(), loadDesktopSettings()]).catch(showError);
setInterval(() => refreshStatus().catch(console.error), 5000);
