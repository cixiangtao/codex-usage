import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawn } from "node:child_process";
import { input as promptInput, password as promptPassword, select } from "@inquirer/prompts";
import { inc, valid } from "semver";
import type { ReleaseType } from "semver";

interface Config {
  appName: string;
  packageName: string;
  gitLabHost: string;
  projectPath: string;
  outputDir: string;
  token: string;
  version: string;
  tagName: string;
  buildNumber: string;
  releaseRef: string;
  releaseName: string;
  releaseNotes: string;
}

interface GitLabAssetLink {
  id: number;
  name: string;
}

interface PackageManifest {
  version?: unknown;
  [key: string]: unknown;
}

const rootDir = resolve(import.meta.dirname, "..");
const packageJSONPath = resolve(rootDir, "package.json");
const localEnvPath = resolve(rootDir, ".env.local");

const printUsage = () => {
  console.log(`Usage: bun run release:local -- [version] [release notes]

Examples:
  bun run release:local
  bun run release:local -- 0.0.2
  bun run release:local -- v0.0.2 "Fix update checks"

Environment:
  GITLAB_TOKEN       Optional GitLab personal access token with API access.
  GITLAB_HOST        GitLab host. Default: gitlab-ee.zhenguanyu.com
  PROJECT_PATH       GitLab project path. Default: cixiangtao/codex-usage
  APP_NAME           App name. Default: CodexUsage
  PACKAGE_NAME       Generic package name. Default: codex-usage
  BUILD_NUMBER       CFBundleVersion. Default: YYYYMMDDHHMMSS
  OUTPUT_DIR         Build output directory. Default: <repo>/dist
  RELEASE_REF        Git ref used if the release tag does not exist. Default: current commit SHA`);
};

const fail = (message: string): never => {
  console.error(`error: ${message}`);
  process.exit(1);
};

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

const resolveToken = async (): Promise<string> => {
  const token = process.env.GITLAB_TOKEN ?? process.env.PRIVATE_TOKEN;
  if (token) {
    return token;
  }

  if (!process.stdin.isTTY) {
    fail("GITLAB_TOKEN is required in non-interactive shells.");
  }

  const promptedToken = await promptPassword({
    message: "GitLab token",
    mask: "*",
  });

  return promptedToken.trim() || fail("GitLab token is required.");
};

const timestampBuildNumber = () => {
  const date = new Date();
  const parts = [
    date.getFullYear(),
    date.getMonth() + 1,
    date.getDate(),
    date.getHours(),
    date.getMinutes(),
    date.getSeconds(),
  ];

  return parts.map((part) => String(part).padStart(2, "0")).join("");
};

const run = (command: string, args: string[], env: NodeJS.ProcessEnv = {}) =>
  new Promise<void>((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: rootDir,
      env: { ...process.env, ...env },
      stdio: "inherit",
    });

    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolvePromise();
        return;
      }

      reject(new Error(`${command} exited with code ${code ?? "unknown"}`));
    });
  });

const capture = (command: string, args: string[]) =>
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
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolvePromise(stdout.trim());
        return;
      }

      reject(new Error(stderr.trim() || `${command} exited with code ${code ?? "unknown"}`));
    });
  });

const normalizeVersion = (value: string) => {
  const normalized = value.trim().replace(/^v/i, "");
  return valid(normalized) ?? fail(`invalid semantic version: ${value}`);
};

const readPackageVersion = async () => {
  const packageJSON = JSON.parse(await readFile(packageJSONPath, "utf8")) as PackageManifest;
  const { version } = packageJSON;
  if (typeof version === "string") {
    return normalizeVersion(version);
  }

  return fail("package.json must define a version.");
};

const nextVersion = (currentVersion: string, releaseType: ReleaseType) =>
  inc(currentVersion, releaseType) ?? fail(`cannot bump ${currentVersion} as ${releaseType}.`);

const promptVersion = async (currentVersion: string) => {
  const patchVersion = nextVersion(currentVersion, "patch");
  const minorVersion = nextVersion(currentVersion, "minor");
  const majorVersion = nextVersion(currentVersion, "major");
  const selected = await select({
    message: `Current version is ${currentVersion}. Select next release version`,
    choices: [
      { name: `patch: ${patchVersion}`, value: patchVersion },
      { name: `minor: ${minorVersion}`, value: minorVersion },
      { name: `major: ${majorVersion}`, value: majorVersion },
      { name: `current: ${currentVersion}`, value: currentVersion },
      { name: "custom...", value: "custom" },
    ],
  });

  if (selected !== "custom") {
    return selected;
  }

  const customVersion = await promptInput({
    message: "Release version",
    default: patchVersion,
    validate: (value) => Boolean(valid(value.trim().replace(/^v/i, ""))) || "Enter a semantic version like 1.2.3",
  });

  return normalizeVersion(customVersion);
};

const resolveReleaseNotes = async (tagName: string, releaseNotesInput: string | undefined) => {
  if (releaseNotesInput?.trim()) {
    return releaseNotesInput.trim();
  }

  if (!process.stdin.isTTY) {
    return `Release ${tagName}`;
  }

  const notes = await promptInput({
    message: "Release notes",
    default: `Release ${tagName}`,
  });

  return notes.trim() || `Release ${tagName}`;
};

const syncPackageVersion = async (version: string) => {
  console.log(`[release] Syncing package.json version to ${version}...`);
  const packageJSON = JSON.parse(await readFile(packageJSONPath, "utf8")) as PackageManifest;
  packageJSON.version = version;
  await writeFile(packageJSONPath, `${JSON.stringify(packageJSON, null, 2)}\n`);
  await run("bun", ["install", "--lockfile-only"]);
};

const createConfig = async (): Promise<Config> => {
  const [versionInput, ...releaseNoteParts] = process.argv.slice(2);

  if (versionInput === "--help" || versionInput === "-h") {
    printUsage();
    process.exit(0);
  }

  const currentVersion = await readPackageVersion();
  if (!versionInput && !process.stdin.isTTY) {
    fail("version is required in non-interactive shells.");
  }

  const version = versionInput ? normalizeVersion(versionInput) : await promptVersion(currentVersion);
  const tagName = `v${version}`;
  const appName = process.env.APP_NAME ?? "CodexUsage";
  const outputDir = process.env.OUTPUT_DIR ?? resolve(rootDir, "dist");
  const releaseNotesInput = releaseNoteParts.length > 0 ? releaseNoteParts.join(" ") : undefined;

  return {
    appName,
    packageName: process.env.PACKAGE_NAME ?? "codex-usage",
    gitLabHost: process.env.GITLAB_HOST ?? "gitlab-ee.zhenguanyu.com",
    projectPath: process.env.PROJECT_PATH ?? "cixiangtao/codex-usage",
    outputDir,
    token: await resolveToken(),
    version,
    tagName,
    buildNumber: process.env.BUILD_NUMBER ?? timestampBuildNumber(),
    releaseRef: process.env.RELEASE_REF ?? (await capture("git", ["rev-parse", "HEAD"])),
    releaseName: `${appName} ${tagName}`,
    releaseNotes: await resolveReleaseNotes(tagName, releaseNotesInput),
  };
};

const gitLabRequest = async (
  config: Config,
  path: string,
  init: RequestInit = {},
  options: { allowNotFound?: boolean } = {},
) => {
  const response = await fetch(`https://${config.gitLabHost}/api/v4/projects/${encodeURIComponent(config.projectPath)}${path}`, {
    ...init,
    headers: {
      "PRIVATE-TOKEN": config.token,
      ...init.headers,
    },
  });

  if (options.allowNotFound && response.status === 404) {
    return response;
  }

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`GitLab API ${path} failed with ${response.status}: ${text}`);
  }

  return response;
};

const formBody = (values: Record<string, string>) => {
  const body = new URLSearchParams();
  for (const [key, value] of Object.entries(values)) {
    body.set(key, value);
  }

  return body;
};

const publishRelease = async (config: Config) => {
  const encodedTag = encodeURIComponent(config.tagName);
  const zipName = `${config.appName}-${config.tagName}.zip`;
  const zipPath = resolve(config.outputDir, zipName);
  const packageURL = `https://${config.gitLabHost}/api/v4/projects/${encodeURIComponent(config.projectPath)}/packages/generic/${config.packageName}/${config.version}/${zipName}`;
  const directAssetPath = `/downloads/${zipName}`;

  await syncPackageVersion(config.version);

  console.log(`[release] Packaging ${config.appName} ${config.tagName}...`);
  await run("bun", ["run", "package:app", "--"], {
    VERSION: config.version,
    BUILD_NUMBER: config.buildNumber,
    OUTPUT_DIR: config.outputDir,
  });

  console.log(`[release] Creating ${zipPath}...`);
  await run("ditto", ["-c", "-k", "--keepParent", `${config.outputDir}/${config.appName}.app`, zipPath]);

  console.log("[release] Uploading package asset...");
  const file = await readFile(zipPath);
  await gitLabRequest(config, `/packages/generic/${config.packageName}/${config.version}/${zipName}`, {
    method: "PUT",
    body: file,
  });

  console.log("[release] Creating or updating GitLab release...");
  const existingRelease = await gitLabRequest(config, `/releases/${encodedTag}`, {}, { allowNotFound: true });
  const releaseBody = formBody({
    name: config.releaseName,
    description: config.releaseNotes,
  });

  if (existingRelease.status === 404) {
    releaseBody.set("tag_name", config.tagName);
    releaseBody.set("ref", config.releaseRef);
    await gitLabRequest(config, "/releases", {
      method: "POST",
      body: releaseBody,
    });
  } else {
    await gitLabRequest(config, `/releases/${encodedTag}`, {
      method: "PUT",
      body: releaseBody,
    });
  }

  console.log("[release] Linking release asset...");
  const linksResponse = await gitLabRequest(config, `/releases/${encodedTag}/assets/links`);
  const links = (await linksResponse.json()) as GitLabAssetLink[];
  const existingLink = links.find((link) => link.name === zipName);
  const linkBody = formBody({
    name: zipName,
    url: packageURL,
    link_type: "package",
    direct_asset_path: directAssetPath,
  });

  if (existingLink) {
    await gitLabRequest(config, `/releases/${encodedTag}/assets/links/${existingLink.id}`, {
      method: "PUT",
      body: linkBody,
    });
  } else {
    await gitLabRequest(config, `/releases/${encodedTag}/assets/links`, {
      method: "POST",
      body: linkBody,
    });
  }

  console.log(`[release] Published ${config.tagName}`);
  console.log(`[release] Download asset: ${packageURL}`);
};

try {
  await loadLocalEnv();
  await publishRelease(await createConfig());
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
