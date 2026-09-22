import {
  KEYCODES,
  CATEGORIES,
  DEFAULT_CODES,
  CONTROLS,
  labelFor as keyLabelFor,
  hex,
  validCode,
  parseProfile,
} from "./keycodes.js";

// 设备状态与键位草稿分开，后台保活刷新不会覆盖尚未应用的编辑。
const state = {
  page: "keymap",
  device: null,
  baseline: [],
  draft: new Map(),
  selected: 0,
  category: "basic",
  search: "",
  busy: false,
  error: "",
  errorSource: null,
  generation: 0,
  needsRefresh: false,
  profiles: readProfiles(),
  testing: false,
  pressed: new Set(),
  events: [],
};
const icons = {
  settings:
    '<path d="m9 3 1-2h4l1 2 2 1 2-1 2 4-2 2v3l2 2-2 4-2-1-2 1-1 3h-4l-1-3-2-1-2 1-2-4 2-2V9L3 7l2-4 2 1Z"/><circle cx="12" cy="11" r="3"/>',
  keys: '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M7 9h.01M11 9h.01M15 9h.01M7 13h.01M11 13h.01M15 13h.01M7 16h10"/>',
  test: '<path d="M3 12h4l3-7 4 14 3-7h4"/>',
  profiles:
    '<path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v10H3Z"/><path d="M8 12h8M8 15h5"/>',
  device:
    '<rect x="7" y="2" width="10" height="20" rx="4"/><circle cx="12" cy="7" r="2"/><path d="M10 12h4M10 16h4"/>',
  arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
  refresh:
    '<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6 7a7 7 0 0 1 12-1l2 3M4 15l2 3a7 7 0 0 0 12-1"/>',
  download: '<path d="M12 3v12m-4-4 4 4 4-4M4 16v5h16v-5"/>',
  upload: '<path d="M12 16V4m-4 4 4-4 4 4M4 16v5h16v-5"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 4 4"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  plug: '<path d="M9 3v5m6-5v5M7 8h10v4a5 5 0 0 1-10 0Zm5 9v4"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6m0-10h.01"/>',
};
const icon = (name) =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name] || icons.info}</svg>`;
const escapeHTML = (text) =>
  String(text ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
// 0x01 的设备值不变，只有本机转换开启后才具有 Fn 语义。
const labelFor = code => code === 1 && !state.device?.fnBridge?.enabled ? "0x01 · Fn 未启用" : keyLabelFor(code);
const connected = () => !!state.device?.connected;
const usable = () =>
  connected() && state.device?.online === true && state.baseline.length === 6;
const current = (index) =>
  state.draft.has(index)
    ? state.draft.get(index)
    : state.baseline.find((k) => k.index === index)?.code;
const disabled = (value) => (value ? " disabled" : "");
const timeLabel = (stamp) => {
  if (!stamp) return "尚未收到";
  const date = new Date(
    typeof stamp === "number" && stamp < 1e12 ? stamp * 1000 : stamp,
  );
  return Number.isNaN(+date)
    ? "未知"
    : date.toLocaleTimeString("zh-CN", { hour12: false });
};

function readProfiles() {
  try {
    const parsed = JSON.parse(
      localStorage.getItem("olanzi.profiles.v1") || "[]",
    );
    return Array.isArray(parsed)
      ? parsed
          .filter((p) => {
            try {
              parseProfile(p);
              return typeof p.name === "string";
            } catch {
              return false;
            }
          })
          .slice(0, 30)
      : [];
  } catch {
    return [];
  }
}
function persistProfiles() {
  try {
    localStorage.setItem("olanzi.profiles.v1", JSON.stringify(state.profiles));
    return true;
  } catch {
    toast("浏览器存储不可用，请导出 JSON 备份。", true);
    return false;
  }
}
function toast(message, error = false) {
  const el = document.querySelector("#toast");
  el.textContent = message;
  el.className = `visible ${error ? "error" : ""}`;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (el.className = ""), 4500);
}
async function confirmAction(title, message) {
  const dialog = document.querySelector("#confirm-dialog");
  document.querySelector("#dialog-title").textContent = title;
  document.querySelector("#dialog-message").textContent = message;
  dialog.returnValue = "cancel";
  dialog.showModal();
  return new Promise((resolve) =>
    dialog.addEventListener(
      "close",
      () => resolve(dialog.returnValue === "confirm"),
      { once: true },
    ),
  );
}
async function api(path, payload) {
  const response = await fetch(
    `/api/${path}`,
    payload === undefined
      ? {}
      : {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        },
  );
  const result = await response.json();
  if (!response.ok) {
    if (result.state) state.device = result.state;
    const error = new Error(result.error || "操作失败，请重试。");
    error.state = result.state;
    throw error;
  }
  return result;
}
async function operate(task, errorSource = "operation") {
  if (state.busy) return;
  state.busy = true;
  state.generation += 1;
  state.error = "";
  state.errorSource = null;
  render();
  try {
    await task();
  } catch (error) {
    state.error = error.message;
    state.errorSource = errorSource;
    toast(error.message, true);
  } finally {
    state.busy = false;
    render();
  }
}
function acceptDevice(device, preserveDraft = false) {
  state.device = device;
  state.baseline = structuredClone(device.keys || []);
  if (preserveDraft) {
    for (const [index, code] of state.draft) {
      if (state.baseline.find((k) => k.index === index)?.code === code)
        state.draft.delete(index);
    }
  } else state.draft.clear();
  state.needsRefresh = false;
}
function assign(index, code) {
  if (!usable() || state.busy || !validCode(code)) return;
  if (state.baseline.find((k) => k.index === index)?.code === code)
    state.draft.delete(index);
  else state.draft.set(index, code);
  render();
}
function profileData(name = "Vibe Key 配置") {
  const keys = CONTROLS.map((_, index) => ({ index, code: current(index) }));
  const profile = { version: 1, device: "AU05", name, keys };
  parseProfile(profile);
  return profile;
}
function loadProfile(profile) {
  if (!usable()) {
    toast("请先连接设备，再载入配置。", true);
    return;
  }
  const codes = parseProfile(profile);
  codes.forEach((code, index) => {
    if (state.baseline.find((k) => k.index === index)?.code === code)
      state.draft.delete(index);
    else state.draft.set(index, code);
  });
  state.page = "keymap";
  render();
  toast("已载入草稿，点击“应用到设备”后才会写入。");
}

function render() {
  const device = state.device;
  const online = device?.online;
  const status = connected()
    ? online === false
      ? "本体离线"
      : online !== true
        ? "状态待确认"
        : device?.demo
          ? "演示设备"
          : "设备已连接"
    : "未连接设备";
  const pages = {
    keymap: "键位配置",
    tester: "按键测试",
    profiles: "配置文件",
    device: "设备与连接",
  };
  document.querySelector("#app").innerHTML = `
    <header class="app-bar">
      <a class="brand" href="#" data-action="home" aria-label="Olanzi 首页">OLANZI</a>
      <nav class="main-nav" aria-label="主要导航">${[
        ["keymap", "keys", "键位配置"],
        ["tester", "test", "按键测试"],
        ["profiles", "profiles", "配置文件"],
        ["device", "settings", "设备与连接"],
      ]
        .map(
          ([id, i, label]) =>
            `<button class="nav-item ${state.page === id ? "active" : ""}" data-page="${id}" aria-label="${label}" title="${label}"${state.page === id ? ' aria-current="page"' : ""}>${icon(i)}<span class="nav-tooltip">${label}</span></button>`,
        )
        .join("")}</nav>
      <div class="header-status">${device?.demo ? '<span class="demo-badge">演示模式</span>' : ""}<button class="connection-chip" data-page="device"><span class="status-dot ${connected() && online === true ? "on" : ""}"></span>${status}</button></div>
    </header>
    <main id="main-content" class="page-${state.page}">
      ${state.page !== "keymap" ? `<div class="page-heading"><h1>${pages[state.page]}</h1>${connected() ? `<button class="button secondary" data-action="refresh"${disabled(state.busy)}>${icon("refresh")}重新读取</button>` : `<button class="button primary" data-action="connect"${disabled(state.busy)}>${icon("plug")}连接设备</button>`}</div>` : ""}
      ${state.error || device?.error ? `<div class="alert" role="alert">${icon("info")}<span>${escapeHTML(state.error || device.error)}</span></div>` : ""}
      ${state.page === "keymap" ? keymapPage() : state.page === "profiles" ? profilesPage() : state.page === "device" ? devicePage() : testerPage()}
    </main>`;
  bindEvents();
}
function hardwareKey(index, type) {
  const symbols = {
    mic: '<rect x="10" y="5" width="8" height="14" rx="4"/><path d="M6 14v2a8 8 0 0 0 16 0v-2M14 24v4"/>',
    yes: '<path d="M5 15a10 10 0 0 1 18-7M23 15a10 10 0 0 1-18 7M4 20l1 4 4-1M24 10l-1-4-4 1M9 15l4 4 7-8"/>',
    no: '<path d="M5 15a10 10 0 0 1 18-7M23 15a10 10 0 0 1-18 7M4 20l1 4 4-1M24 10l-1-4-4 1M10 10l9 10M19 10l-9 10"/>',
  };
  return `<button class="hardware-key key-${index} ${state.selected === index ? "selected" : ""}" data-control="${index}" aria-label="选择${CONTROLS[index]}" aria-pressed="${state.selected === index}"><span class="key-well"><svg viewBox="0 0 28 32" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${symbols[type]}</svg></span>${state.draft.has(index) ? '<i class="change-dot"></i>' : ""}</button>`;
}
function keymapPage() {
  const code = current(state.selected);
  const codeLabel = (i) =>
    escapeHTML(usable() ? labelFor(current(i)) : "未连接");
  return `<section class="device-panel" aria-label="设备键位预览">
    <div class="device-heading"><div><h1>Ulanzi Vibe Key</h1><span>AU05</span></div><div class="device-tools">${connected() ? `<button class="button text-button" data-action="refresh"${disabled(state.busy)} title="重新读取">${icon("refresh")}<span>重新读取</span></button>` : `<button class="button primary" data-action="connect"${disabled(state.busy)}>${icon("plug")}${state.busy ? "连接中…" : "连接 Vibe Key"}</button>`}</div></div>
    <div class="device-stage"><div class="device-canvas">
      <div class="hardware" aria-label="银色 Vibe Key：顶部格栅、圆形旋钮、三个白色按键">
        <div class="hardware-logo">Ulanzi</div><div class="speaker-grille" aria-hidden="true">${Array.from({ length: 6 }, () => "<i></i>").join("")}</div>
        <button class="knob ${state.selected === 3 ? "selected" : ""}" data-control="3" aria-label="选择旋钮按下" aria-pressed="${state.selected === 3}"><span class="knob-face"><i></i><i></i><i></i><i></i></span>${state.draft.has(3) ? '<i class="change-dot"></i>' : ""}</button>
        <div class="hardware-keys">${hardwareKey(0, "mic")}${hardwareKey(1, "yes")}${hardwareKey(2, "no")}</div>
      </div>
      <div class="knob-callout ${state.selected === 3 ? "active" : ""}"><small>旋钮按下</small><strong>${codeLabel(3)}</strong><span class="connector"></span></div>
      <div class="rotation-controls">${[
        [5, "↶", "左转"],
        [4, "↷", "右转"],
      ]
        .map(
          ([i, symbol, label]) =>
            `<button data-control="${i}" class="rotation-key ${state.selected === i ? "selected" : ""}" aria-label="选择旋钮${label}" aria-pressed="${state.selected === i}"><span class="rotation-symbol">${symbol}</span><span><small>${label}</small><strong>${codeLabel(i)}</strong></span>${state.draft.has(i) ? '<i class="change-dot"></i>' : ""}</button>`,
        )
        .join("")}</div>
      <div class="key-callouts">${[0, 1, 2].map((i) => `<div class="key-callout ${state.selected === i ? "active" : ""}"><span class="connector"></span><small>按键 ${i + 1}</small><strong>${codeLabel(i)}</strong>${state.draft.has(i) ? '<span class="draft-label">已修改</span>' : ""}</div>`).join("")}</div>
      <span class="canvas-hint">${usable() ? "点击设备上的按键或旋钮，再选择下方键码" : "连接设备后，读取并配置六个动作"}</span>
    </div></div>
    <div class="selection-bar"><span>当前选择</span><strong>${CONTROLS[state.selected]}</strong><span class="selection-arrow">→</span><div class="mapping-preview"><span>${usable() ? escapeHTML(labelFor(code)) : "—"}</span><small>${usable() ? hex(code) : ""}</small></div>${state.draft.has(state.selected) ? `<div class="previous-mapping">原键位 <span>${escapeHTML(labelFor(state.baseline.find((k) => k.index === state.selected)?.code))}</span> → <span>${escapeHTML(labelFor(code))}</span></div>` : ""}<span class="device-storage-note">${icon("device")}${state.device?.demo ? "模拟配置，不写硬件" : "配置保存在设备中"}</span></div>
  </section>
  <section class="key-library" aria-labelledby="key-library-title"><div class="library-sidebar"><h2 id="key-library-title">键码</h2><div class="library-tabs" role="tablist" aria-label="键码类别" aria-orientation="vertical">${CATEGORIES.map(([id, label]) => `<button role="tab" aria-selected="${id === state.category}" data-category="${id}" class="${id === state.category ? "active" : ""}">${label}</button>`).join("")}</div></div><div class="library-content"><div class="library-header"><span>选择一个按键，分配给 <strong>${CONTROLS[state.selected]}</strong></span><label class="search-box">${icon("search")}<input id="key-search" placeholder="搜索按键 / 键码" aria-label="搜索按键或键码" value="${escapeHTML(state.search)}"><kbd>/</kbd></label></div><div id="key-grid" class="key-grid" role="tabpanel" aria-label="可选键码">${keyGrid()}</div><div class="library-note">${icon("info")}<span>${state.category === "modifier" ? "修饰键作为单个按键发送；组合键尚未验证。" : "支持标准键盘键码。组合键、多媒体与宏将在协议验证后开放。"}</span></div></div></section>
  ${current(state.selected) === 1 || state.category === "modifier" ? fnPanel(true) : ""}<div class="apply-bar"><div><span class="status-dot ${usable() ? "on" : ""}"></span><span><strong>${state.needsRefresh ? "请重新读取设备状态" : state.draft.size ? `${state.draft.size} 个键位待应用` : usable() ? "所有更改已同步" : "等待设备连接"}</strong><small>${state.needsRefresh ? "写入结果未完整确认，草稿已保留" : state.draft.size ? "应用后写入设备，并读回核验" : ""}</small></span></div><div><button class="button text-button" data-action="discard"${disabled(!state.draft.size || state.busy)}>撤销更改</button><button class="button primary" data-action="apply"${disabled(!state.draft.size || !usable() || state.busy || state.needsRefresh)}>${state.busy ? "正在处理…" : "应用到设备"}${icon("arrow")}</button></div></div>`;
}
function keyGrid() {
  const search = state.search.trim().toLowerCase();
  const keys = KEYCODES.filter((k) =>
    search
      ? `${k.label} ${k.aliases} ${hex(k.code)} ${k.code}`
          .toLowerCase()
          .includes(search)
      : k.category === state.category,
  );
  return keys.length
    ? keys
        .map(
          (k) =>
            `<button class="keycap ${usable() && current(state.selected) === k.code ? "assigned" : ""}" data-code="${k.code}" title="${escapeHTML(k.label)} · ${hex(k.code)}" aria-label="分配 ${escapeHTML(k.label)}" aria-pressed="${usable() && current(state.selected) === k.code}"${disabled(!usable() || state.busy)}><span>${escapeHTML(k.label)}</span><small>${hex(k.code)}</small></button>`,
        )
        .join("")
    : '<div class="empty-search">没有找到匹配的按键。试试 F13、Enter 或 0x68。</div>';
}
function profilesPage() {
  return `<section class="surface profile-intro"><div class="profile-art">${icon("profiles")}</div><div><span class="panel-eyebrow">LOCAL PROFILES</span><h2>不同工作流，一键切换。</h2><p>配置文件保存在当前浏览器，也可以导出为 JSON。<br>载入只更新草稿，由你决定何时应用到设备。</p></div></section>
  <section class="surface"><div class="section-heading"><h2>保存当前配置</h2><span class="subtle-tag">仅本地</span></div><form id="save-profile-form" class="profile-form"><label for="profile-name">配置名称</label><div><input id="profile-name" maxlength="60" placeholder="例如：日常工作、剪辑、演示" required><button class="button primary"${disabled(!usable() || state.busy)}>保存配置</button></div></form><div class="profile-toolbar"><button class="button secondary" data-action="export"${disabled(!usable() || state.busy)}>${icon("download")}导出当前配置</button><button class="button secondary" data-action="import"${disabled(!usable() || state.busy)}>${icon("upload")}导入 JSON</button><button class="button text-button" data-action="defaults"${disabled(!usable() || state.busy)}>载入出厂键位</button></div></section>
  <section class="surface"><div class="section-heading"><h2>我的配置</h2><span class="muted">${state.profiles.length} 个配置</span></div>${state.profiles.length ? `<div class="profile-list">${state.profiles.map((p, i) => `<article class="profile-card"><div class="profile-card-icon">${icon("keys")}</div><div><h3>${escapeHTML(p.name)}</h3><p>${p.keys.map((k) => escapeHTML(labelFor(k.code))).join(" · ")}</p></div><button class="button secondary" data-load-profile="${i}"${disabled(!usable() || state.busy)}>载入</button><button class="button text-button" data-delete-profile="${i}"${disabled(state.busy)} aria-label="删除 ${escapeHTML(p.name)}">删除</button></article>`).join("")}</div>` : '<div class="empty-state"><span>还没有保存的配置</span><p>连接设备后，为你的第一套键位取个名字。</p></div>'}</section>`;
}
function fnPanel(compact = false) {
  const fn = state.device?.fnBridge;
  const permissions = value => state.device?.demo ? "演示不检查" : value === true ? "已授权" : value === false ? "未授权" : "待检查";
  return `<section class="fn-panel ${compact ? "compact" : "surface"}" aria-label="Mac Fn 转换设置">
    <div class="fn-heading"><div><h${compact ? "3" : "2"}>Mac Fn 转换</h${compact ? "3" : "2"}><span class="fn-status">${fn?.active ? "正在监听" : fn?.enabled ? state.device?.demo ? "演示开关已开启" : "等待就绪" : "未启用"}</span></div>
    <button class="button ${fn?.enabled ? "secondary" : "primary"}" role="switch" aria-label="Mac Fn 转换" aria-checked="${!!fn?.enabled}" data-action="toggle-fn"${disabled(state.busy || !state.device)}> ${fn?.enabled ? "关闭转换" : "启用转换"}</button></div>
    <p>将设备的 <code>0x01</code> 按下、松开转换为 Mac Fn。需要本地服务持续运行；所有使用此键码的控件共享此功能。</p>
    ${fn?.enabled ? `<div class="fn-permissions"><span>输入监控：${permissions(fn.inputPermission)}</span><span>辅助功能：${permissions(fn.accessibilityPermission)}</span><span>${fn.pressed ? "Fn 按住中" : "Fn 已松开"}</span>${!state.device?.demo && (fn.inputPermission !== true || fn.accessibilityPermission !== true) ? `<button class="button text-button" data-action="fn-permissions"${disabled(state.busy)}>请求系统权限</button>` : ""}</div>` : ""}
    ${fn?.error || fn?.settingsError ? `<p class="fn-error" role="status">${escapeHTML(fn.error || fn.settingsError)}</p>` : ""}
    ${!compact ? '<p class="fn-help">先启用转换，再在键位配置的“修饰键”中选择 Mac Fn 并应用。出厂顶部按键已经使用 0x01，开启后无需改键。系统地球键动作由 macOS 设置决定，不能用浏览器按键测试判断是否生效。</p>' : ""}
  </section>`;
}
function devicePage() {
  const d = state.device;
  const heartbeat = d?.heartbeat;
  return `<div class="device-info-grid"><section class="surface"><div class="section-heading"><h2>Vibe Key <span class="muted">AU05</span></h2><span class="subtle-tag">${d?.demo ? "模拟设备" : "USB 接收器"}</span></div><div class="device-identity">${icon("device")}<div><h3>你的创作搭档</h3><p>3 个按键 · 1 个旋钮 · 6 个动作</p></div></div><dl class="info-list"><div><dt>接收器连接</dt><dd>${connected() ? "已连接" : "未连接"}</dd></div><div><dt>本体在线状态</dt><dd>${d?.online === true ? "在线" : d?.online === false ? "离线 / 休眠" : "尚未确认"}</dd></div><div><dt>固件版本</dt><dd>${escapeHTML(d?.device?.firmware || "尚未读取")}</dd></div><div><dt>设备电量</dt><dd>${d?.device?.battery == null ? "尚未读取" : `${escapeHTML(d.device.battery)}%`}</dd></div><div><dt>连接方式</dt><dd>${d?.demo ? "本地模拟" : "本地 USB · 厂商通道"}</dd></div></dl><button class="button ${connected() ? "secondary" : "primary"}" data-action="${connected() ? "disconnect" : "connect"}"${disabled(state.busy)}>${icon("plug")}${connected() ? "断开设备" : "连接 Vibe Key"}</button></section>
  <section class="surface"><div class="section-heading"><h2>后台保活</h2><span class="subtle-tag ${heartbeat?.enabled ? "pink-text" : ""}">${heartbeat?.enabled ? "运行中" : "未运行"}</span></div><div class="heartbeat-visual"><svg viewBox="0 0 300 65" aria-hidden="true"><path d="M0 35H80L98 35 112 10 130 56 148 20 163 35H300"/></svg><span>1<span>秒 / 次</span></span></div><p class="body-copy">连接后每秒发送与 Studio 一致的心跳。只要本地服务仍在运行，关闭浏览器页面也会继续发送。</p><dl class="info-list"><div><dt>最近发送</dt><dd>${timeLabel(heartbeat?.lastSent)}</dd></div><div><dt>本体状态检测</dt><dd>独立查询 · 每 2 秒</dd></div></dl><div class="inline-note">${icon("info")}<p>心跳发送成功不代表本体在线。本体状态由独立查询确认；能否阻止长时间休眠仍需持续实测。</p></div></section></div>
  ${fnPanel()}<section class="surface"><div class="section-heading"><h2>连接帮助</h2></div><div class="help-steps"><div><span>01</span><h3>插入接收器</h3><p>将 AU05 的 USB 接收器连接到这台 Mac。</p></div><div><span>02</span><h3>唤醒 Vibe Key</h3><p>如果本体离线，短按电源键，再点“重新读取”。</p></div><div><span>03</span><h3>开始配置</h3><p>选择控件、分配键码，最后将更改应用到设备。</p></div></div><p class="help-footnote">出现“无权限”时，检查 macOS 隐私与安全性中的输入监控；出现“被占用”时，检查其他抓包或设备工具。Olanzi 会显示实际错误。</p></section>
  <section class="surface roadmap"><span class="panel-eyebrow">BUILT TO GROW</span><h2>不止于改键。</h2><p>Olanzi 是轻量的设备工作台。当前支持键位配置与后台保活；灯效、设备设置和更多工作流会在协议验证后逐步加入。</p></section>`;
}
function testerPage() {
  return `<section class="surface tester"><div class="section-heading"><div><span class="panel-eyebrow">KEY TESTER</span><h2>让每一次输入都看得见。</h2></div><span class="subtle-tag">浏览器输入测试</span></div><p class="body-copy">测试当前页面收到的键盘事件，包括 Vibe Key 和其他键盘。无法区分输入来源，部分系统快捷键可能被 macOS 拦截。</p><div class="test-stage ${state.testing ? "listening" : ""}" tabindex="0" id="test-stage" aria-label="按键测试区域"><span class="test-icon">${icon("test")}</span><strong>${state.testing ? "等待按键…" : "准备好试一下了吗？"}</strong><p>${state.testing ? "保持此页面聚焦 · Esc 结束测试" : "开始后，依次按下三个按键，再按下和转动旋钮。"}</p><div id="pressed-keys" aria-live="polite"></div></div><div class="tester-actions"><button class="button primary" data-action="toggle-test">${state.testing ? "结束测试" : "开始测试"}${icon("arrow")}</button><button class="button secondary" data-action="clear-test">清空记录</button><span class="muted">未启用转换时 0x01 会被系统忽略；Mac Fn 通常不会产生网页 keydown 事件。</span></div><div class="test-history"><div class="section-heading"><h3>最近输入</h3><span class="muted">最多保留 20 条，仅当前页面</span></div><div id="test-events">${eventsMarkup()}</div></div></section>`;
}
function eventsMarkup() {
  return state.events.length
    ? state.events
        .map(
          (e) =>
            `<div class="event-row"><span class="status-dot on"></span><strong>${escapeHTML(e.label)}</strong><code>${escapeHTML(e.code)}</code><span>${e.time}</span></div>`,
        )
        .join("")
    : '<p class="muted">还没有收到输入。</p>';
}
function bindEvents() {
  document.querySelectorAll("[data-page]").forEach(
    (el) =>
      (el.onclick = () => {
        state.page = el.dataset.page;
        stopTesting();
        render();
      }),
  );
  document.querySelectorAll("[data-control]").forEach(
    (el) =>
      (el.onclick = () => {
        state.selected = Number(el.dataset.control);
        render();
      }),
  );
  document.querySelectorAll("[data-category]").forEach((el) => {
    el.onclick = () => {
      state.category = el.dataset.category;
      state.search = "";
      render();
    };
    el.onkeydown = (event) => {
      if (
        ![
          "ArrowLeft",
          "ArrowRight",
          "ArrowUp",
          "ArrowDown",
          "Home",
          "End",
        ].includes(event.key)
      )
        return;
      event.preventDefault();
      const currentTab = CATEGORIES.findIndex(
        ([id]) => id === el.dataset.category,
      );
      const nextTab =
        event.key === "Home"
          ? 0
          : event.key === "End"
            ? CATEGORIES.length - 1
            : (currentTab +
                (["ArrowRight", "ArrowDown"].includes(event.key) ? 1 : -1) +
                CATEGORIES.length) %
              CATEGORIES.length;
      state.category = CATEGORIES[nextTab][0];
      state.search = "";
      render();
      document.querySelector(`[data-category="${state.category}"]`).focus();
    };
  });
  bindKeycaps();
  const search = document.querySelector("#key-search");
  if (search)
    search.oninput = () => {
      state.search = search.value;
      document.querySelector("#key-grid").innerHTML = keyGrid();
      bindKeycaps();
    };
  document.querySelectorAll("[data-action]").forEach(
    (el) =>
      (el.onclick = (event) => {
        event.preventDefault();
        actions[el.dataset.action]?.();
      }),
  );
  document.querySelectorAll("[data-load-profile]").forEach(
    (el) =>
      (el.onclick = async () => {
        if (
          state.draft.size &&
          !(await confirmAction(
            "替换当前草稿？",
            "已有未应用的更改，载入配置会替换这些更改。",
          ))
        )
          return;
        loadProfile(state.profiles[Number(el.dataset.loadProfile)]);
      }),
  );
  document.querySelectorAll("[data-delete-profile]").forEach(
    (el) =>
      (el.onclick = async () => {
        const i = Number(el.dataset.deleteProfile);
        if (
          !(await confirmAction(
            "删除这个本地配置？",
            `“${state.profiles[i].name}”将从当前浏览器移除，不影响设备键位。`,
          ))
        )
          return;
        state.profiles.splice(i, 1);
        persistProfiles();
        render();
      }),
  );
  const save = document.querySelector("#save-profile-form");
  if (save)
    save.onsubmit = (event) => {
      event.preventDefault();
      if (!usable() || state.busy) return;
      const name = document.querySelector("#profile-name").value.trim();
      if (!name) return;
      try {
        if (state.profiles.length >= 30)
          throw new Error("最多保存 30 个配置，请先删除不需要的配置。");
        state.profiles.push(profileData(name));
        if (persistProfiles()) toast("配置已保存到当前浏览器。");
        render();
      } catch (error) {
        toast(error.message, true);
      }
    };
}
function bindKeycaps() {
  document
    .querySelectorAll("[data-code]")
    .forEach(
      (el) =>
        (el.onclick = () => assign(state.selected, Number(el.dataset.code))),
    );
}
function stopTesting() {
  state.testing = false;
  state.pressed.clear();
}
const actions = {
  home: () => {
    state.page = "keymap";
    stopTesting();
    render();
  },
  connect: () =>
    operate(async () => {
      acceptDevice(await api("connect", {}), true);
      if (!usable())
        throw new Error(
          state.device.error || "设备尚未就绪，请查看设备与连接。",
        );
      toast(
        state.device.demo
          ? "演示设备已连接，不会访问真实硬件。"
          : "设备已连接，六个控件配置已读取。",
      );
    }, "connection"),
  refresh: async () => {
    if (
      state.draft.size &&
      !(await confirmAction(
        "重新读取设备？",
        "这会丢弃未应用的草稿，并读取设备上的实际配置。",
      ))
    )
      return;
    return operate(async () => {
      acceptDevice(await api("refresh", {}));
      toast("已重新读取设备配置。");
    }, "connection");
  },
  disconnect: async () => {
    if (
      state.draft.size &&
      !(await confirmAction(
        "断开设备？",
        "未应用的草稿将被丢弃，后台保活也会停止。",
      ))
    )
      return;
    return operate(async () => {
      acceptDevice(await api("disconnect", {}));
      toast("已断开设备，后台保活已停止。");
    });
  },
  discard: () => {
    state.draft.clear();
    render();
  },
  apply: () =>
    operate(async () => {
      if (!usable() || !state.draft.size || state.needsRefresh) return;
      const changes = [...state.draft].map(([index, code]) => ({
        index,
        code,
      }));
      const expected = state.baseline
        .filter((k) => state.draft.has(k.index))
        .map(({ index, entries }) => ({ index, entries }));
      try {
        acceptDevice(await api("apply", { changes, expected }));
        toast(
          state.device.demo
            ? "演示配置已更新。"
            : "已写入设备，并完成逐项读回校验。",
        );
      } catch (error) {
        if (error.state?.online === true && error.state?.keys?.length === 6) {
          acceptDevice(error.state, true);
          error.message += ` 已读取实际配置，剩余 ${state.draft.size} 个修改保留在草稿中。`;
        } else state.needsRefresh = true;
        throw error;
      }
    }),
  defaults: async () => {
    if (
      state.draft.size &&
      !(await confirmAction(
        "替换当前草稿？",
        "当前草稿会被出厂键位替换，暂不写入设备。",
      ))
    )
      return;
    loadProfile({
      version: 1,
      device: "AU05",
      keys: DEFAULT_CODES.map((code, index) => ({ index, code })),
    });
  },
  export: () => {
    try {
      const blob = new Blob([JSON.stringify(profileData(), null, 2) + "\n"], {
        type: "application/json",
      });
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = "olanzi-au05.json";
      anchor.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      toast("已导出当前配置（包含未应用的草稿）。");
    } catch (error) {
      toast(error.message, true);
    }
  },
  import: () => {
    if (usable() && !state.busy) document.querySelector("#import-file").click();
  },
  "toggle-fn": () => operate(async () => {
    state.device = await api("fn", {enabled: !state.device?.fnBridge?.enabled});
    const fn = state.device.fnBridge;
    toast(fn.enabled ? fn.active ? "Mac Fn 转换已启用。" : "Fn 开关已保存，请查看设备状态和权限提示。" : "Mac Fn 转换已关闭，设备键位未改变。");
  }),
  "fn-permissions": () => operate(async () => {
    state.device = await api("fn/permissions", {});
    toast("请在系统设置中授权运行 Olanzi 的终端；必要时重启终端和服务。");
  }),
  "toggle-test": () => {
    state.testing = !state.testing;
    state.pressed.clear();
    render();
    if (state.testing) document.querySelector("#test-stage").focus();
  },
  "clear-test": () => {
    state.events = [];
    state.pressed.clear();
    render();
    if (state.testing) document.querySelector("#test-stage").focus();
  },
};
document.querySelector("#import-file").onchange = async (event) => {
  const file = event.target.files[0];
  event.target.value = "";
  if (!file) return;
  try {
    if (file.size > 32 * 1024) throw new Error("配置文件太大，应小于 32 KB。");
    const profile = JSON.parse(await file.text());
    parseProfile(profile);
    if (
      state.draft.size &&
      !(await confirmAction(
        "替换当前草稿？",
        "导入文件会替换尚未应用的更改，暂不写入设备。",
      ))
    )
      return;
    loadProfile(profile);
  } catch (error) {
    toast(`导入失败：${error.message}`, true);
  }
};
window.addEventListener("beforeunload", (event) => {
  if (state.draft.size) {
    event.preventDefault();
    event.returnValue = "";
  }
});
window.addEventListener("blur", () => {
  state.pressed.clear();
  const el = document.querySelector("#pressed-keys");
  if (el) el.textContent = "";
});
window.addEventListener("keydown", (event) => {
  if (!state.testing) {
    if (
      event.key === "/" &&
      state.page === "keymap" &&
      !["INPUT", "TEXTAREA"].includes(document.activeElement.tagName) &&
      !document.querySelector("dialog[open]")
    ) {
      event.preventDefault();
      document.querySelector("#key-search")?.focus();
    }
    return;
  }
  if (event.key === "Escape") {
    stopTesting();
    render();
    return;
  }
  // 保留 Tab 的键盘导航；其他按键只在测试区域聚焦时截获。
  if (document.activeElement?.id !== "test-stage" || event.key === "Tab")
    return;
  event.preventDefault();
  if (event.repeat) return;
  const modifiers = [
    event.ctrlKey && "Ctrl",
    event.altKey && "Option",
    event.shiftKey && "Shift",
    event.metaKey && "Command",
  ].filter(Boolean);
  const label = [...modifiers, event.key === " " ? "Space" : event.key].join(
    " + ",
  );
  state.pressed.add(event.code);
  state.events.unshift({
    label,
    code: event.code,
    time: new Date().toLocaleTimeString("zh-CN", { hour12: false }),
  });
  state.events = state.events.slice(0, 20);
  document.querySelector("#pressed-keys").textContent = label;
  document.querySelector("#test-events").innerHTML = eventsMarkup();
});
window.addEventListener("keyup", (event) => {
  state.pressed.delete(event.code);
  if (!state.pressed.size) {
    const el = document.querySelector("#pressed-keys");
    if (el) el.textContent = "";
  }
});

render();
const initialGeneration = state.generation;
try {
  const initialState = await api("state");
  if (!state.busy && state.generation === initialGeneration) {
    acceptDevice(initialState);
    render();
  }
} catch {
  if (!state.busy && state.generation === initialGeneration) {
    state.error = "无法连接本地服务，请运行 python3 olanzi.py 后重新打开页面。";
    state.errorSource = "network";
    render();
  }
}
setInterval(async () => {
  if (state.busy || document.hidden) return;
  const generation = state.generation;
  try {
    const device = await api("state");
    if (state.busy || state.generation !== generation) return;
    const clearConnectionError =
      state.errorSource === "network" ||
      (state.errorSource === "connection" && device.online === true);
    if (clearConnectionError) {
      state.error = "";
      state.errorSource = null;
    }
    const statusChanged =
      device.connected !== state.device?.connected ||
      device.online !== state.device?.online ||
      device.error !== state.device?.error ||
      JSON.stringify(device.fnBridge) !== JSON.stringify(state.device?.fnBridge);
    state.device = device;
    const keysChanged =
      !state.draft.size &&
      device.online === true &&
      JSON.stringify(state.baseline) !== JSON.stringify(device.keys);
    if (keysChanged) state.baseline = structuredClone(device.keys || []);
    // 配置变化才重绘，恢复搜索焦点与光标，避免后台轮询打断编辑。
    if (
      (state.page === "device" ||
        statusChanged ||
        keysChanged ||
        clearConnectionError) &&
      !document.querySelector("dialog[open]")
    ) {
      const input =
        document.activeElement?.id === "key-search"
          ? document.activeElement
          : null;
      const selection = input
        ? [input.selectionStart, input.selectionEnd]
        : null;
      render();
      if (selection && state.page === "keymap") {
        const search = document.querySelector("#key-search");
        search.focus();
        search.setSelectionRange(...selection);
      }
    }
  } catch {
    if (state.busy || state.generation !== generation) return;
    const changed = state.device?.connected || !state.error;
    if (state.device)
      state.device = { ...state.device, connected: false, online: null };
    state.error = "本地服务连接中断。请检查运行 Olanzi 的终端。";
    state.errorSource = "network";
    if (changed && !document.querySelector("dialog[open]")) render();
  }
}, 3000);
