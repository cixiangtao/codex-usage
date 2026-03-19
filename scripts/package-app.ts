import { constants as fsConstants } from "node:fs";
import { access, copyFile, mkdir, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

const rootDir = resolve(import.meta.dirname, "..");
const appName = process.env.APP_NAME ?? "CodexUsage";
const bundleIdentifier = process.env.BUNDLE_IDENTIFIER ?? "com.anys.codexusage";
const version = process.env.VERSION ?? "1.0.0";
const buildNumber = process.env.BUILD_NUMBER ?? "1";
const outputDir = process.env.OUTPUT_DIR ?? resolve(rootDir, "dist");
const appPath = resolve(outputDir, `${appName}.app`);
const signingIdentity = process.env.APPLE_SIGNING_IDENTITY?.trim() || "-";
const notaryKeychainProfile = process.env.APPLE_NOTARY_KEYCHAIN_PROFILE?.trim();
const notaryAppleId = process.env.APPLE_NOTARY_APPLE_ID?.trim();
const notaryTeamId = process.env.APPLE_NOTARY_TEAM_ID?.trim();
const notaryPassword = process.env.APPLE_NOTARY_PASSWORD?.trim();
const skipNotarization = ["1", "true", "yes"].includes((process.env.SKIP_NOTARIZATION ?? "").toLowerCase());

const printUsage = () => {
  console.log(`Usage: bun run package:app

Environment:
  APP_NAME            App executable name. Default: ${appName}
  BUNDLE_IDENTIFIER   Bundle identifier. Default: ${bundleIdentifier}
  VERSION             CFBundleShortVersionString. Default: ${version}
  BUILD_NUMBER        CFBundleVersion. Default: ${buildNumber}
  OUTPUT_DIR          Output directory. Default: ${outputDir}
  APPLE_SIGNING_IDENTITY
                      Developer ID identity for distributed builds. Default: ad-hoc signing
  APPLE_NOTARY_KEYCHAIN_PROFILE
                      notarytool keychain profile. Preferred for notarization
  APPLE_NOTARY_APPLE_ID / APPLE_NOTARY_TEAM_ID / APPLE_NOTARY_PASSWORD
                      notarytool credentials used when no keychain profile is provided
  SKIP_NOTARIZATION   Set to 1 to skip notarization for Developer ID builds`);
};

const fail = (message: string): never => {
  console.error(`error: ${message}`);
  process.exit(1);
};

const run = (command: string, args: string[]) =>
  new Promise<void>((resolvePromise, reject) => {
    const child = spawn(command, args, {
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

      reject(new Error(`${command} exited with code ${code ?? "unknown"}`));
    });
  });

const capture = (command: string, args: string[]) =>
  new Promise<string>((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: rootDir,
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
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolvePromise(stdout.trim());
        return;
      }

      reject(new Error(stderr.trim() || `${command} exited with code ${code ?? "unknown"}`));
    });
  });

const notaryAuthArguments = () => {
  if (notaryKeychainProfile) {
    return ["--keychain-profile", notaryKeychainProfile];
  }

  if (notaryAppleId && notaryTeamId && notaryPassword) {
    return ["--apple-id", notaryAppleId, "--team-id", notaryTeamId, "--password", notaryPassword];
  }

  return [];
};

const assertExecutable = async (path: string) => {
  try {
    await access(path, fsConstants.X_OK);
  } catch {
    fail(`release executable not found at ${path}`);
  }
};

const escapePlistString = (value: string) =>
  value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;");

const infoPlist = () => `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>${escapePlistString(appName)}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${escapePlistString(bundleIdentifier)}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${escapePlistString(appName)}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${escapePlistString(version)}</string>
  <key>CFBundleVersion</key>
  <string>${escapePlistString(buildNumber)}</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 anys.</string>
</dict>
</plist>
`;

const signApp = async () => {
  await run("xattr", ["-cr", appPath]);

  const args = ["--force", "--deep", "--sign", signingIdentity];
  if (signingIdentity !== "-") {
    args.push("--options", "runtime", "--timestamp");
  }

  await run("codesign", [...args, appPath]);
  await run("codesign", ["--verify", "--deep", "--strict", "--verbose=2", appPath]);
};

const notarizeApp = async () => {
  const authArgs = notaryAuthArguments();
  if (signingIdentity === "-") {
    console.warn("[package] Using ad-hoc signing. Downloaded builds will not pass Gatekeeper notarization.");
    return;
  }

  if (skipNotarization) {
    console.warn("[package] Skipped notarization. Downloaded Developer ID builds may still be blocked by Gatekeeper.");
    return;
  }

  if (authArgs.length === 0) {
    console.warn("[package] Missing notarytool credentials. Set APPLE_NOTARY_KEYCHAIN_PROFILE or APPLE_NOTARY_APPLE_ID / APPLE_NOTARY_TEAM_ID / APPLE_NOTARY_PASSWORD.");
    console.warn("[package] Downloaded Developer ID builds may still be blocked by Gatekeeper.");
    return;
  }

  const archivePath = resolve(outputDir, `${appName}-notary.zip`);
  await rm(archivePath, { force: true });
  await run("ditto", ["-c", "-k", "--keepParent", "--norsrc", "--noextattr", appPath, archivePath]);
  await run("xcrun", ["notarytool", "submit", archivePath, "--wait", ...authArgs]);
  await rm(archivePath, { force: true });
  await run("xcrun", ["stapler", "staple", appPath]);
  await run("spctl", ["--assess", "--type", "execute", "--verbose=4", appPath]);
};

const packageApp = async () => {
  const [firstArg] = process.argv.slice(2);
  if (firstArg === "-h" || firstArg === "--help") {
    printUsage();
    return;
  }

  console.log("[package] Building release executable...");
  await run("swift", ["build", "-c", "release", "--product", appName]);

  const binDir = await capture("swift", ["build", "-c", "release", "--show-bin-path"]);
  const executablePath = resolve(binDir, appName);
  const appMacOSDir = resolve(appPath, "Contents", "MacOS");
  const appResourcesDir = resolve(appPath, "Contents", "Resources");
  const sourceIconPath = resolve(rootDir, "Sources", "CodexUsage", "Resources", "AppIcon.icns");

  await assertExecutable(executablePath);
  try {
    await access(sourceIconPath);
  } catch {
    fail(`application icon not found at ${sourceIconPath}`);
  }

  await rm(appPath, { recursive: true, force: true });
  await mkdir(appMacOSDir, { recursive: true });
  await mkdir(appResourcesDir, { recursive: true });

  await copyFile(executablePath, resolve(appMacOSDir, appName));
  await copyFile(sourceIconPath, resolve(appResourcesDir, "AppIcon.icns"));

  await writeFile(resolve(appPath, "Contents", "Info.plist"), infoPlist());
  await signApp();
  await notarizeApp();

  console.log(`[package] Created ${appPath}`);
};

try {
  await packageApp();
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
