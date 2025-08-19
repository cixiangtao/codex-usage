import { createHash } from "node:crypto";
import { spawn, type ChildProcess } from "node:child_process";
import { readdir, stat } from "node:fs/promises";
import { basename, join, relative, resolve } from "node:path";

const rootDir = resolve(import.meta.dirname, "..");
const appName = process.env.APP_NAME ?? "CodexUsage";
const pollIntervalSeconds = Number.parseFloat(process.env.POLL_INTERVAL ?? "1");
const debounceSeconds = Number.parseFloat(process.env.DEBOUNCE_SECONDS ?? "0.35");

let childProcess: ChildProcess | undefined;

const printUsage = () => {
  console.log(`Usage: bun run dev:watch

Environment:
  APP_NAME           App executable name. Default: ${appName}
  POLL_INTERVAL      Seconds between file checks. Default: ${pollIntervalSeconds}
  DEBOUNCE_SECONDS   Delay before restart after changes. Default: ${debounceSeconds}`);
};

const fail = (message: string): never => {
  console.error(`error: ${message}`);
  process.exit(1);
};

const assertPositiveSeconds = (name: string, value: number) => {
  if (!Number.isFinite(value) || value <= 0) {
    fail(`${name} must be a positive number of seconds.`);
  }
};

const sleep = (seconds: number) =>
  new Promise<void>((resolvePromise) => {
    setTimeout(resolvePromise, seconds * 1000);
  });

const timestamp = () =>
  new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(new Date());

const capture = (command: string, args: string[], options: { allowFailure?: boolean } = {}) =>
  new Promise<string>((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: rootDir,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", (error) => {
      if (options.allowFailure) {
        resolvePromise("");
        return;
      }

      reject(error);
    });
    child.on("close", (code) => {
      if (code === 0 || options.allowFailure) {
        resolvePromise(stdout.trim());
        return;
      }

      reject(new Error(stderr.trim() || `${command} exited with code ${code ?? "unknown"}`));
    });
  });

const isProcessRunning = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

const waitForClose = (child: ChildProcess) =>
  new Promise<void>((resolvePromise) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolvePromise();
      return;
    }

    child.once("close", () => resolvePromise());
  });

const hasRootWorkingDirectory = async (pid: number) => {
  const output = await capture("lsof", ["-a", "-p", String(pid), "-d", "cwd"], { allowFailure: true });
  const lines = output.split("\n").slice(1);

  return lines.some((line) => {
    const columns = line.trim().split(/\s+/);
    return columns.at(-1) === rootDir;
  });
};

const devAppPids = async () => {
  const output = await capture("pgrep", ["-f", appName], { allowFailure: true });
  const pids = output
    .split("\n")
    .map((value) => Number.parseInt(value, 10))
    .filter((pid) => Number.isInteger(pid) && pid > 0 && pid !== process.pid && pid !== childProcess?.pid);

  const matchingPids: number[] = [];
  for (const pid of pids) {
    if (await hasRootWorkingDirectory(pid)) {
      matchingPids.push(pid);
    }
  }

  return matchingPids;
};

const stopApp = async () => {
  const child = childProcess;
  if (child?.pid && isProcessRunning(child.pid)) {
    process.kill(child.pid);
    await waitForClose(child);
  }

  for (const pid of await devAppPids()) {
    if (pid !== process.pid) {
      try {
        process.kill(pid);
      } catch {
        // The process may exit between discovery and termination.
      }
    }
  }

  childProcess = undefined;
};

const collectSourceFiles = async (path: string, files: string[]) => {
  let pathStat;
  try {
    pathStat = await stat(path);
  } catch {
    return;
  }

  if (pathStat.isDirectory()) {
    const entries = await readdir(path, { withFileTypes: true });
    await Promise.all(entries.map((entry) => collectSourceFiles(join(path, entry.name), files)));
    return;
  }

  if (pathStat.isFile() && (path.endsWith(".swift") || basename(path) === "Package.swift")) {
    files.push(path);
  }
};

const fingerprint = async () => {
  const files: string[] = [];
  await Promise.all(
    ["Package.swift", "Sources", "WidgetExtension"].map((entry) => collectSourceFiles(resolve(rootDir, entry), files)),
  );

  const hash = createHash("sha1");
  for (const file of files.sort()) {
    const fileStat = await stat(file);
    hash.update(`${fileStat.mtimeMs} ${fileStat.size} ${relative(rootDir, file)}\0`);
  }

  return hash.digest("hex");
};

const startApp = () => {
  console.log(`\n[${timestamp()}] Starting ${appName}...`);
  childProcess = spawn("swift", ["run", appName], {
    cwd: rootDir,
    stdio: "inherit",
  });
};

const restartApp = async () => {
  console.log(`[${timestamp()}] Stopping ${appName}...`);
  await stopApp();
  startApp();
};

const cleanupAndExit = async (exitCode: number) => {
  await stopApp();
  process.exit(exitCode);
};

const main = async () => {
  const [firstArg] = process.argv.slice(2);
  if (firstArg === "-h" || firstArg === "--help") {
    printUsage();
    return;
  }

  assertPositiveSeconds("POLL_INTERVAL", pollIntervalSeconds);
  assertPositiveSeconds("DEBOUNCE_SECONDS", debounceSeconds);

  process.on("SIGINT", () => {
    void cleanupAndExit(130);
  });
  process.on("SIGTERM", () => {
    void cleanupAndExit(143);
  });

  console.log(`[${timestamp()}] Watching ${rootDir}`);
  console.log(`[${timestamp()}] Press Ctrl-C to stop.`);

  let lastFingerprint = await fingerprint();
  await stopApp();
  startApp();

  while (true) {
    await sleep(pollIntervalSeconds);

    const nextFingerprint = await fingerprint();
    if (nextFingerprint === lastFingerprint) {
      continue;
    }

    await sleep(debounceSeconds);
    lastFingerprint = await fingerprint();

    console.log(`\n[${timestamp()}] Change detected. Rebuilding...`);
    await restartApp();
  }
};

try {
  await main();
} catch (error) {
  await stopApp();
  fail(error instanceof Error ? error.message : String(error));
}
