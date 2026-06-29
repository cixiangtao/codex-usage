import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const rootDir = resolve(import.meta.dirname, "..");
const packagePath = resolve(rootDir, "package.json");
const stableVersionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;

const fail = (message: string): never => {
  console.error(`error: ${message}`);
  process.exit(1);
};

const parseVersion = (version: string) => {
  if (!stableVersionPattern.test(version)) {
    fail("version must use X.Y.Z format without a v prefix");
  }

  return version.split(".").map(Number);
};

const isNewerVersion = (nextVersion: string, currentVersion: string) => {
  const nextParts = parseVersion(nextVersion);
  const currentParts = parseVersion(currentVersion);

  for (let index = 0; index < nextParts.length; index += 1) {
    const nextPart = nextParts[index]!;
    const currentPart = currentParts[index]!;
    if (nextPart !== currentPart) {
      return nextPart > currentPart;
    }
  }

  return false;
};

const [version] = process.argv.slice(2);
if (!version) {
  fail("usage: bun run release:prepare -- <version>");
}

const packageJSON = JSON.parse(await readFile(packagePath, "utf8")) as Record<string, unknown>;
const currentVersion =
  typeof packageJSON.version === "string"
    ? packageJSON.version
    : fail("package.json must contain a string version");

if (!isNewerVersion(version, currentVersion)) {
  fail(`version ${version} must be newer than ${currentVersion}`);
}

packageJSON.version = version;
await writeFile(packagePath, `${JSON.stringify(packageJSON, null, 2)}\n`);
console.log(`[release] Prepared version ${version}.`);
