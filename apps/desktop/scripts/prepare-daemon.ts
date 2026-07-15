import { $ } from "bun";
import { mkdir } from "node:fs/promises";
import { basename, resolve } from "node:path";

const desktopDir = resolve(import.meta.dir, "..");
const workspaceDir = resolve(desktopDir, "../..");
const release = process.argv.includes("--release");
const rustcVersion = await $`rustc -vV`.cwd(workspaceDir).text();
const host = rustcVersion
  .split("\n")
  .find((line) => line.startsWith("host: "))
  ?.slice("host: ".length);
const target = process.env.TAURI_ENV_TARGET_TRIPLE ?? host;
const universalTarget = "universal-apple-darwin";
const universalTargets = ["aarch64-apple-darwin", "x86_64-apple-darwin"];

if (!target) {
  throw new Error("rustc did not report a host target triple");
}

const executable = process.platform === "win32" ? "clumsiesd.exe" : "clumsiesd";
const profile = release ? "release" : "debug";
const binariesDir = resolve(desktopDir, "src-tauri", "binaries");
const outputName = `${basename(executable, ".exe")}-${target}${process.platform === "win32" ? ".exe" : ""}`;
const output = resolve(binariesDir, outputName);

await mkdir(binariesDir, { recursive: true });

const buildTargets = target === universalTarget ? universalTargets : [target];
for (const buildTarget of buildTargets) {
  const cargoArgs = [
    "build",
    "--locked",
    "-p",
    "daemon",
    "--bin",
    "clumsiesd",
    "--target",
    buildTarget,
  ];
  if (release) {
    cargoArgs.push("--release");
  }
  await $`cargo ${cargoArgs}`.cwd(workspaceDir);

  const source = resolve(workspaceDir, "target", buildTarget, profile, executable);
  const targetOutputName = `${basename(executable, ".exe")}-${buildTarget}${process.platform === "win32" ? ".exe" : ""}`;
  await Bun.write(resolve(binariesDir, targetOutputName), Bun.file(source));
}

if (target === universalTarget) {
  const sources = universalTargets.map((buildTarget) =>
    resolve(workspaceDir, "target", buildTarget, profile, executable),
  );
  await $`lipo -create ${sources} -output ${output}`;
}
