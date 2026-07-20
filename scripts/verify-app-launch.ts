import { constants as fsConstants } from "node:fs";
import { access } from "node:fs/promises";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

const rootDir = resolve(import.meta.dirname, "..");
const appPathArgument = process.argv.slice(2).find((argument) => argument !== "--");
const appPath = resolve(appPathArgument ?? resolve(rootDir, "dist", "CodexUsage.app"));
const executablePath = resolve(appPath, "Contents", "MacOS", "CodexUsage");
const launchCheckMilliseconds = 2_000;
const terminationTimeoutMilliseconds = 3_000;

const fail = (message: string): never => {
  console.error(`error: ${message}`);
  process.exit(1);
};

const delay = (milliseconds: number) =>
  new Promise<void>((resolvePromise) => {
    setTimeout(resolvePromise, milliseconds);
  });

try {
  await access(executablePath, fsConstants.X_OK);
} catch {
  fail(`application executable not found at ${executablePath}`);
}

const child = spawn(executablePath, [], {
  cwd: appPath,
  env: process.env,
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

type ExitResult = {
  kind: "exit";
  code: number | null;
  signal: NodeJS.Signals | null;
};

const exitResult = new Promise<ExitResult>((resolvePromise, reject) => {
  child.once("error", reject);
  child.once("exit", (code, signal) => {
    resolvePromise({ kind: "exit", code, signal });
  });
});

const launchResult = await Promise.race([
  exitResult,
  delay(launchCheckMilliseconds).then(() => ({ kind: "running" as const })),
]);

if (launchResult.kind === "exit") {
  const output = [stdout.trim(), stderr.trim()].filter(Boolean).join("\n");
  fail(
    `application exited before the ${launchCheckMilliseconds}ms launch check `
      + `(code ${launchResult.code ?? "null"}, signal ${launchResult.signal ?? "none"})`
      + (output ? `\n${output}` : ""),
  );
}

child.kill("SIGTERM");
const terminationResult = await Promise.race([
  exitResult,
  delay(terminationTimeoutMilliseconds).then(() => ({ kind: "timeout" as const })),
]);

if (terminationResult.kind === "timeout") {
  child.kill("SIGKILL");
  await exitResult;
}

console.log(`[verify] ${appPath} launched successfully.`);
