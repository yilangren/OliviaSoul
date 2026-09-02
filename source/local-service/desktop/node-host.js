import { cp, mkdir, rm } from "node:fs/promises";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { DesktopController } from "./controller.js";

const PREFIX = "OLIVIA\t";

function argument(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || index === process.argv.length - 1) throw new Error(`缺少参数 ${name}`);
  return process.argv[index + 1];
}

function send(message) {
  process.stdout.write(`${PREFIX}${JSON.stringify(message)}\n`);
}

async function copyIfPresent(source, destination) {
  try {
    await cp(source, destination, { recursive: true, force: true });
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

async function prepareWorkspace(template, root) {
  await mkdir(root, { recursive: true });
  await Promise.all([
    copyIfPresent(join(template, ".cursor", "skills"), join(root, ".cursor", "skills")),
    copyIfPresent(join(template, "harness"), join(root, "harness")),
    copyIfPresent(join(template, "tools"), join(root, "tools")),
    copyIfPresent(join(template, "林离人设.md"), join(root, "林离人设.md")),
  ]);
  await Promise.all([
    rm(join(root, ".cursor", "rules"), { recursive: true, force: true }),
    rm(join(root, "harness", "00-strict-precheck.md"), { force: true }),
    rm(join(root, "harness", "00-脚本算术.md"), { force: true }),
    rm(join(root, "harness", "02-读信感.md"), { force: true }),
    rm(join(root, "harness", "02-历史检索.md"), { force: true }),
    rm(join(root, "harness", "02-账本校正.md"), { force: true }),
    rm(join(root, "harness", "06-实时回信.md"), { force: true }),
    rm(join(root, ".cursor", "skills", "fit-letters", "scripts", "history-retrieval.ps1"), { force: true }),
  ]);
  await Promise.all([
    mkdir(join(root, "信件往来"), { recursive: true }),
    mkdir(join(root, "信件往来_原始语料"), { recursive: true }),
  ]);
}

const root = argument("--root");
const dataDir = argument("--data-dir");
const template = argument("--template");
const appData = argument("--app-data");
const executable = argument("--executable");
const parentPid = Number(argument("--parent-pid"));
if (!Number.isInteger(parentPid) || parentPid < 1) throw new Error("父进程 PID 无效");
await mkdir(appData, { recursive: true });
await mkdir(dataDir, { recursive: true });
await prepareWorkspace(template, root);

const controller = new DesktopController({
  root,
  dataDir,
  appData,
  executable,
  onPortChanged: port => send({ type: "port", port }),
});
const port = await controller.initialize();
send({ type: "ready", port });
console.log(`[host] ready pid=${process.pid} parent=${parentPid} port=${port}`);

let closing = false;
async function close(reason) {
  if (closing) return;
  closing = true;
  clearInterval(parentWatch);
  console.log(`[host] closing reason=${reason}`);
  await controller.close();
  console.log("[host] backend closed");
}

const handlers = {
  getSettings: () => controller.getSettings(),
  setAutoStart: enabled => controller.setAutoStart(enabled === true),
  setClient: path => controller.setClient(path),
  getClientStatus: () => controller.getClientStatus(),
  mountClient: portValue => controller.mountClient(portValue),
  restoreClient: () => controller.restoreClient(),
  assertSoulExport: () => controller.assertSoulExport(),
  exportSoul: path => controller.exportSoul(path),
  assertRemoteSoulExport: jobId => controller.assertRemoteSoulExport(jobId),
  exportRemoteSoul: (jobId, path) => controller.exportRemoteSoul(jobId, path),
  shutdown: async () => {
    await close("desktop-command");
    return { stopped: true };
  },
};

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
const parentWatch = setInterval(() => {
  try {
    process.kill(parentPid, 0);
  } catch {
    close("parent-missing").finally(() => process.exit(0));
  }
}, 1000);
parentWatch.unref();
lines.on("line", async line => {
  let command;
  try {
    command = JSON.parse(line);
    if (command.type !== "command" || typeof handlers[command.method] !== "function")
      throw new Error(`不支持的桌面命令：${command.method ?? ""}`);
    const data = await handlers[command.method](...(Array.isArray(command.args) ? command.args : []));
    send({ type: "response", id: command.id, ok: true, data });
    if (command.method === "shutdown") {
      lines.close();
      process.exit(0);
    }
  } catch (error) {
    send({
      type: "response",
      id: command?.id ?? "",
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    });
  }
});
lines.once("close", () => {
  if (closing) return;
  close("stdin-closed").finally(() => process.exit(0));
});
process.once("SIGINT", () => close("sigint").finally(() => process.exit(0)));
process.once("SIGTERM", () => close("sigterm").finally(() => process.exit(0)));
process.once("uncaughtException", error => {
  process.stderr.write(`${error.stack ?? error.message}\n`);
  close("uncaught-exception").finally(() => process.exit(1));
});
