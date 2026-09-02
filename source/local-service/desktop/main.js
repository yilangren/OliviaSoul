import { app, BrowserWindow, dialog, ipcMain, Menu, nativeImage, shell, Tray } from "electron";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { access, cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { createServer as createNetServer } from "node:net";
import { dirname, extname, join, resolve } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { createOliviaService } from "../server.js";

const here = dirname(fileURLToPath(import.meta.url));
const developmentRoot = resolve(here, "..", "..");
const DEFAULT_PORT = 27149;
const hiddenAtLaunch = process.argv.includes("--hidden");
let mainWindow;
let tray;
let service;
let quitting = false;
let backendClosed = false;
let trayNoticeShown = false;
let autoStart = false;
let currentPort = DEFAULT_PORT;
let clientExePath = "";

function assertPort(value) {
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1024 || port > 65535)
    throw new Error("端口必须是 1024–65535 的整数");
  return port;
}

function adminUrl(port = currentPort) {
  return `http://127.0.0.1:${port}/admin`;
}

function runtimeSettingsPath() {
  return join(app.getPath("userData"), "desktop-settings.json");
}

async function readRuntimeSettings() {
  try {
    const settings = JSON.parse(await readFile(runtimeSettingsPath(), "utf8"));
    return {
      port: assertPort(settings.port),
      clientExe: typeof settings.clientExe === "string" ? settings.clientExe : "",
    };
  } catch (error) {
    if (error.code === "ENOENT") return { port: DEFAULT_PORT, clientExe: "" };
    throw error;
  }
}

async function writeRuntimeSettings() {
  const settings = { port: currentPort, clientExe: clientExePath };
  await writeFile(runtimeSettingsPath(), `${JSON.stringify(settings, null, 2)}\n`, "utf8");
}

function desktopAsset(name) {
  return app.isPackaged ? join(process.resourcesPath, "app.asar.unpacked", "desktop", name) : join(here, name);
}

function runProcess(command, args) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { windowsHide: true });
    let outputText = "";
    let errorText = "";
    child.stdout.on("data", chunk => outputText += chunk.toString());
    child.stderr.on("data", chunk => errorText += chunk.toString());
    child.once("error", reject);
    child.once("close", code => {
      if (code === 0) resolvePromise(outputText.trim());
      else reject(new Error(errorText.trim() || `命令执行失败：${code}`));
    });
  });
}

function queryAutoStart() {
  return new Promise(resolvePromise => {
    const command = "if (Get-ScheduledTask | Where-Object { $_.TaskName -eq 'OliviaLocalLettersAutoStart' -or $_.TaskName -like 'Olivia *' }) { exit 0 } else { exit 1 }";
    const child = spawn("powershell.exe", ["-NoProfile", "-Command", command], { windowsHide: true, stdio: "ignore" });
    child.once("error", () => resolvePromise(false));
    child.once("close", code => resolvePromise(code === 0));
  });
}

async function refreshAutoStart() {
  autoStart = await queryAutoStart();
  rebuildTrayMenu();
  return autoStart;
}

async function setAutoStart(enabled) {
  const executable = process.execPath;
  const argumentsValue = app.isPackaged ? "--hidden" : `"${resolve(here, "..")}" --hidden`;
  const helperCommand = [
    `& '${desktopAsset("startup-task.ps1").replaceAll("'", "''")}'`,
    `-Mode '${enabled ? "Enable" : "Disable"}'`,
    `-Executable '${executable.replaceAll("'", "''")}'`,
    `-Arguments '${argumentsValue.replaceAll("'", "''")}'`,
  ].join(" ");
  const encoded = Buffer.from(helperCommand, "utf16le").toString("base64");
  const elevate = `$process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ${encoded}' -Verb RunAs -WindowStyle Hidden -Wait -PassThru; exit $process.ExitCode`;
  await runProcess("powershell.exe", ["-NoProfile", "-Command", elevate]);
  return refreshAutoStart();
}

function workspacePath() {
  return app.isPackaged ? join(app.getPath("userData"), "workspace") : developmentRoot;
}

function powershellLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

async function runElevatedScript(script, args = []) {
  if (args.length % 2 !== 0) throw new Error("提权脚本参数必须成对传入");
  const formattedArgs = args.map((value, index) => {
    if (index % 2 === 1) return powershellLiteral(value);
    if (!/^-[A-Za-z][A-Za-z0-9]*$/u.test(value)) throw new Error(`非法脚本参数：${value}`);
    return value;
  });
  const errorFile = join(app.getPath("temp"), `olivia-elevated-${randomUUID()}.txt`);
  const invoke = [`& ${powershellLiteral(script)}`, ...formattedArgs].join(" ");
  const command = `try { ${invoke} } catch { [IO.File]::WriteAllText(${powershellLiteral(errorFile)}, $_.Exception.Message, (New-Object Text.UTF8Encoding $false)); exit 1 }`;
  const encoded = Buffer.from(command, "utf16le").toString("base64");
  const elevate = `$process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ${encoded}' -Verb RunAs -WindowStyle Hidden -Wait -PassThru; exit $process.ExitCode`;
  try {
    await runProcess("powershell.exe", ["-NoProfile", "-Command", elevate]);
  } catch (error) {
    try {
      const detail = (await readFile(errorFile, "utf8")).trim();
      if (detail) throw new Error(detail);
    } catch (detailError) {
      if (detailError.code !== "ENOENT") throw detailError;
    }
    throw error;
  } finally {
    await rm(errorFile, { force: true });
  }
}

async function selectedClientLayout() {
  if (!clientExePath) return null;
  if (extname(clientExePath).toLowerCase() !== ".exe") throw new Error("请选择游戏 exe 文件");
  await access(clientExePath);
  const gameRoot = dirname(clientExePath);
  const candidates = [];
  for (const entry of await readdir(gameRoot, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const feappPath = join(gameRoot, entry.name, "resources", "feapp.dat");
    try {
      await access(feappPath);
      candidates.push({ version: entry.name, feappPath });
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
  }
  if (candidates.length !== 1) throw new Error(`所选 exe 目录应包含一个客户端版本，当前找到 ${candidates.length} 个`);
  return { gameRoot, ...candidates[0] };
}

async function readFeappStatus(feappPath) {
  const script = join(workspacePath(), "tools", "get-feapp-status.ps1");
  const output = await runProcess("powershell.exe", [
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-FeappPath", feappPath,
  ]);
  return JSON.parse(output);
}

async function getClientMountStatus() {
  const layout = await selectedClientLayout();
  if (!layout) {
    return {
      clientSelected: false,
      clientExe: "",
      mounted: false,
      port: null,
      servicePort: currentPort,
    };
  }
  return {
    clientSelected: true,
    clientExe: clientExePath,
    ...(await readFeappStatus(layout.feappPath)),
    servicePort: currentPort,
  };
}

async function selectClientExe() {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: "选择游戏客户端",
    defaultPath: clientExePath || undefined,
    properties: ["openFile"],
    filters: [{ name: "Windows 可执行文件", extensions: ["exe"] }],
  });
  if (result.canceled) return { ...(await getClientMountStatus()), selectionChanged: false };
  const previous = clientExePath;
  clientExePath = result.filePaths[0];
  try {
    await selectedClientLayout();
    await writeRuntimeSettings();
  } catch (error) {
    clientExePath = previous;
    throw error;
  }
  return { ...(await getClientMountStatus()), selectionChanged: true };
}

async function originalFeapp(layout, createOnMount = false) {
  const key = createHash("md5").update(layout.gameRoot.toLowerCase(), "utf8").digest("hex");
  const backupDir = join(app.getPath("userData"), "client-backups");
  const managedBackup = join(backupDir, `${key}.feapp.dat`);
  try {
    await access(managedBackup);
    if ((await readFeappStatus(managedBackup)).mounted) throw new Error("本机保存的客户端原版备份无效");
    return managedBackup;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  if (!createOnMount) throw new Error("未找到挂载前保存的客户端原版备份");
  const current = await readFeappStatus(layout.feappPath);
  if (current.mounted) throw new Error("当前客户端已挂载，但没有挂载前的原版备份");
  return managedBackup;
}

async function mountClientService(value) {
  const port = assertPort(value);
  const changed = port !== currentPort;
  const layout = await selectedClientLayout();
  if (!layout) throw new Error("请先选择游戏 exe");
  const originalFile = await originalFeapp(layout, true);
  if (port !== currentPort) await assertPortAvailable(port);
  const patchScript = join(workspacePath(), "tools", "patch-feapp-local.ps1");
  const patchArgs = [
    "-GameRoot", layout.gameRoot,
    "-Version", layout.version,
    "-OriginalFile", originalFile,
    "-ServiceUrl", `http://127.0.0.1:${port}`,
  ];
  await runElevatedScript(patchScript, patchArgs);
  try {
    await changeServicePort(port);
  } catch (error) {
    if (port !== currentPort) {
      try {
        patchArgs[patchArgs.length - 1] = `http://127.0.0.1:${currentPort}`;
        await runElevatedScript(patchScript, patchArgs);
      } catch (rollbackError) {
        throw new Error(`${error.message}；客户端端口回滚失败：${rollbackError.message}`);
      }
    }
    throw error;
  }
  const status = await getClientMountStatus();
  if (changed) setTimeout(() => mainWindow.loadURL(adminUrl()), 250);
  return status;
}

async function restoreClient() {
  const layout = await selectedClientLayout();
  if (!layout) throw new Error("请先选择游戏 exe");
  const originalFile = await originalFeapp(layout);
  const restoreScript = join(workspacePath(), "tools", "restore-feapp-original.ps1");
  await runElevatedScript(restoreScript, [
    "-GameRoot", layout.gameRoot,
    "-Version", layout.version,
    "-OriginalFile", originalFile,
  ]);
  return getClientMountStatus();
}

async function executableWindowIcon() {
  const command = `Add-Type -AssemblyName System.Drawing; $icon = [Drawing.Icon]::ExtractAssociatedIcon(${powershellLiteral(process.execPath)}); $bitmap = $icon.ToBitmap(); $stream = New-Object IO.MemoryStream; try { $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png); [Convert]::ToBase64String($stream.ToArray()) } finally { $stream.Dispose(); $bitmap.Dispose(); $icon.Dispose() }`;
  const base64 = await runProcess("powershell.exe", ["-NoProfile", "-Command", command]);
  const icon = nativeImage.createFromDataURL(`data:image/png;base64,${base64}`);
  if (icon.isEmpty()) throw new Error("无法读取窗口图标");
  return icon;
}

function showWindow() {
  if (!mainWindow) return;
  mainWindow.show();
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.focus();
}

function rebuildTrayMenu() {
  if (!tray) return;
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: "打开管理窗口", click: showWindow },
    {
      label: "开机自动启动",
      type: "checkbox",
      checked: autoStart,
      click: item => setAutoStart(item.checked).catch(error => {
        dialog.showErrorBox("开机自启设置失败", error.message);
        refreshAutoStart();
      }),
    },
    { type: "separator" },
    { label: "退出", click: () => app.quit() },
  ]));
}

function createTray(windowIcon) {
  tray = new Tray(windowIcon.resize({ width: 16, height: 16 }));
  tray.setToolTip("Olivia 本机信件");
  tray.on("click", showWindow);
  rebuildTrayMenu();
}

function createWindow(windowIcon) {
  mainWindow = new BrowserWindow({
    width: 1298,
    height: 858,
    minWidth: 820,
    minHeight: 620,
    show: false,
    icon: windowIcon,
    backgroundColor: "#111114",
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(here, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  mainWindow.loadURL(adminUrl());
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/u.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });
  mainWindow.webContents.on("will-navigate", event => event.preventDefault());
  mainWindow.on("minimize", event => {
    event.preventDefault();
    mainWindow.hide();
    if (!trayNoticeShown) {
      tray.displayBalloon({
        title: "Olivia 本机信件",
        content: "应用仍在托盘运行，信件服务不会中断。",
      });
      trayNoticeShown = true;
    }
  });
  mainWindow.on("close", event => {
    if (quitting) return;
    event.preventDefault();
    mainWindow.hide();
  });
  mainWindow.once("ready-to-show", () => {
    if (!hiddenAtLaunch) showWindow();
  });
}

async function packagedWorkspace() {
  const root = join(app.getPath("userData"), "workspace");
  const template = join(process.resourcesPath, "workspace-template");
  await mkdir(root, { recursive: true });
  await cp(join(template, ".cursor", "skills"), join(root, ".cursor", "skills"), { recursive: true, force: true });
  await rm(join(root, ".cursor", "rules"), { recursive: true, force: true });
  await cp(join(template, "harness"), join(root, "harness"), { recursive: true, force: true });
  await rm(join(root, "harness", "02-历史检索.md"), { force: true });
  await rm(join(root, "harness", "02-账本校正.md"), { force: true });
  await rm(join(root, ".cursor", "skills", "fit-letters", "scripts", "history-retrieval.ps1"), { force: true });
  await cp(join(template, "tools"), join(root, "tools"), { recursive: true, force: true });
  await cp(join(template, "林离人设.md"), join(root, "林离人设.md"), { force: true });
  await mkdir(join(root, "信件往来"), { recursive: true });
  await mkdir(join(root, "信件往来_原始语料"), { recursive: true });
  return root;
}

async function createOwnedBackend(port) {
  const root = app.isPackaged ? await packagedWorkspace() : developmentRoot;
  const dataDir = app.isPackaged ? join(app.getPath("userData"), "data") : join(resolve(here, ".."), "data");
  const nextService = await createOliviaService({ root, dataDir });
  try {
    await nextService.listen(port, "127.0.0.1");
  } catch (error) {
    await nextService.close();
    throw error;
  }
  service = nextService;
}

async function startBackend(port) {
  const running = await fetch(`${adminUrl(port)}/api/status`).catch(() => null);
  if (running?.ok) return;
  try {
    await createOwnedBackend(port);
  } catch (error) {
    if (error.code === "EADDRINUSE") throw new Error(`端口 ${port} 已被其他程序占用`);
    throw error;
  }
}

function assertPortAvailable(port) {
  return new Promise((resolvePromise, reject) => {
    const probe = createNetServer();
    probe.once("error", error => {
      if (error.code === "EADDRINUSE") reject(new Error(`端口 ${port} 已被其他程序占用`));
      else reject(error);
    });
    probe.listen(port, "127.0.0.1", () => probe.close(resolvePromise));
  });
}

async function changeServicePort(value) {
  const port = assertPort(value);
  if (port === currentPort) return currentPort;
  if (!service) throw new Error("当前本机服务不是由此应用启动，无法安全切换端口");
  await assertPortAvailable(port);
  const oldPort = currentPort;
  await service.close();
  service = null;
  try {
    await createOwnedBackend(port);
  } catch (error) {
    await createOwnedBackend(oldPort);
    throw error;
  }
  currentPort = port;
  try {
    await writeRuntimeSettings();
  } catch (error) {
    await service.close();
    service = null;
    currentPort = oldPort;
    await createOwnedBackend(oldPort);
    throw error;
  }
  return currentPort;
}

async function exportSoul() {
  const url = `${adminUrl()}/api/memory/export/soul`;
  const check = await fetch(url, { method: "HEAD" });
  if (check.status === 409) throw new Error("暂无记忆");
  if (!check.ok) throw new Error(`导出检查失败：HTTP ${check.status}`);
  const selected = await dialog.showSaveDialog(mainWindow, {
    title: "导出 Olivia Soul 记忆",
    defaultPath: `OliviaSoul-memory-${new Date().toISOString().slice(0, 10)}.soul`,
    filters: [{ name: "Olivia Soul 记忆", extensions: ["soul"] }],
  });
  if (selected.canceled) return { cancelled: true };
  const response = await fetch(url);
  if (!response.ok) throw new Error(`导出失败：HTTP ${response.status}`);
  try {
    await pipeline(Readable.fromWeb(response.body), createWriteStream(selected.filePath));
    return { cancelled: false, path: selected.filePath };
  } catch (error) {
    await rm(selected.filePath, { force: true });
    throw error;
  }
}

const singleInstance = app.requestSingleInstanceLock();
if (!singleInstance) {
  app.quit();
} else {
  app.setAppUserModelId("study.olivia.localletters");
  app.on("second-instance", (_event, commandLine) => {
    if (commandLine.includes("--quit")) app.quit();
    else showWindow();
  });
  app.on("before-quit", event => {
    if (backendClosed) return;
    event.preventDefault();
    if (quitting) return;
    quitting = true;
    if (!service) {
      backendClosed = true;
      app.quit();
      return;
    }
    service.close().finally(() => {
      service = null;
      backendClosed = true;
      app.quit();
    });
  });
  app.on("window-all-closed", () => {});
  ipcMain.handle("desktop:get-settings", async () => ({
    autoStart: await refreshAutoStart(),
    port: currentPort,
    clientExe: clientExePath,
  }));
  ipcMain.handle("desktop:set-auto-start", async (_event, enabled) => ({ autoStart: await setAutoStart(enabled === true) }));
  ipcMain.handle("client:select", () => selectClientExe());
  ipcMain.handle("client:get-status", () => getClientMountStatus());
  ipcMain.handle("client:mount", (_event, port) => mountClientService(port));
  ipcMain.handle("client:restore", () => restoreClient());
  ipcMain.handle("desktop:export-soul", () => exportSoul());
  ipcMain.handle("desktop:hide", () => mainWindow.hide());
  app.whenReady().then(async () => {
    try {
      app.setLoginItemSettings({ openAtLogin: false });
      const settings = await readRuntimeSettings();
      currentPort = settings.port;
      clientExePath = settings.clientExe;
      await startBackend(currentPort);
      await refreshAutoStart();
      const windowIcon = await executableWindowIcon();
      createTray(windowIcon);
      createWindow(windowIcon);
    } catch (error) {
      dialog.showErrorBox("Olivia 本机信件启动失败", error.message);
      backendClosed = true;
      app.quit();
    }
  });
}
