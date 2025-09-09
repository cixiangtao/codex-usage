import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

const rootDir = resolve(import.meta.dirname, "..");
const localEnvPath = resolve(rootDir, ".env.local");

const unquoteEnvValue = (value: string) => {
  const trimmed = value.trim();
  const quote = trimmed[0];
  if ((quote === '"' || quote === "'") && trimmed.endsWith(quote)) {
    return trimmed.slice(1, -1);
  }

  return trimmed;
};

const loadLocalEnv = async () => {
  let source = "";
  try {
    source = await readFile(localEnvPath, "utf8");
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT") {
      return;
    }

    throw error;
  }

  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) {
      continue;
    }

    const separatorIndex = line.indexOf("=");
    if (separatorIndex === -1) {
      continue;
    }

    const key = line.slice(0, separatorIndex).trim();
    const value = unquoteEnvValue(line.slice(separatorIndex + 1));
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key) && process.env[key] === undefined) {
      process.env[key] = value;
    }
  }
};

const releaseItArgs = () => {
  const [versionInput, ...releaseNoteParts] = process.argv.slice(2);
  const hasReleaseNotes = releaseNoteParts.length > 0 && releaseNoteParts.every((part) => !part.startsWith("-"));
  if (!versionInput || versionInput.startsWith("-") || !hasReleaseNotes) {
    return process.argv.slice(2);
  }

  process.env.RELEASE_IT_RELEASE_NOTES = releaseNoteParts.join(" ");

  return [versionInput, '--gitlab.releaseNotes=printf %s "$RELEASE_IT_RELEASE_NOTES"'];
};

const runReleaseIt = () =>
  new Promise<void>((resolvePromise, reject) => {
    const child = spawn(process.execPath, ["x", "release-it", ...releaseItArgs()], {
      cwd: rootDir,
      env: process.env,
      stdio: "inherit",
    });

    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolvePromise();
        return;
      }

      reject(new Error(`release-it exited with code ${code ?? "unknown"}`));
    });
  });

try {
  await loadLocalEnv();
  process.env.GITLAB_TOKEN ??= process.env.PRIVATE_TOKEN;
  await runReleaseIt();
} catch (error) {
  console.error(`error: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
}
