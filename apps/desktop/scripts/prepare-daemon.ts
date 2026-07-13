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

if (!target) {
  throw new Error("rustc did not report a host target triple");
}

const cargoArgs = [
  "build",
  "--locked",
  "-p",
  "daemon",
  "--bin",
  "clumsiesd",
  "--target",
  target,
];
if (release) {
  cargoArgs.push("--release");
}

await $`cargo ${cargoArgs}`.cwd(workspaceDir);

const executable = process.platform === "win32" ? "clumsiesd.exe" : "clumsiesd";
const profile = release ? "release" : "debug";
const source = resolve(workspaceDir, "target", target, profile, executable);
const binariesDir = resolve(desktopDir, "src-tauri", "binaries");
const outputName = `${basename(executable, ".exe")}-${target}${process.platform === "win32" ? ".exe" : ""}`;

await mkdir(binariesDir, { recursive: true });
await Bun.write(resolve(binariesDir, outputName), Bun.file(source));
