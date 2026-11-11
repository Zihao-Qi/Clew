// Builds the unpacked extension into dist/: load it from chrome://extensions
// (Developer mode › Load unpacked › Extension/dist).
import { cpSync, mkdirSync, rmSync } from "node:fs";

const root = new URL("..", import.meta.url).pathname;
rmSync(`${root}dist`, { recursive: true, force: true });
mkdirSync(`${root}dist`);

const run = async (entry: string, format: "esm" | "iife") => {
  const out = await Bun.build({ entrypoints: [`${root}src/${entry}`], outdir: `${root}dist`, format, target: "browser" });
  if (!out.success) {
    for (const log of out.logs) console.error(log);
    process.exit(1);
  }
};
await run("background.ts", "esm");
await run("popup.ts", "esm");
await run("content.ts", "iife"); // content scripts can't be modules
await run("content-x.ts", "iife");
cpSync(`${root}static`, `${root}dist`, { recursive: true });
// A release stamps its version (CLEW_VERSION, e.g. 1.4.0) into the built manifest, so the
// extension and the app it ships with carry the same number (.github/workflows/release.yml).
const version = process.env.CLEW_VERSION;
if (version) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    console.error(`CLEW_VERSION must look like 1.4.0, not ${version}`);
    process.exit(1);
  }
  const path = `${root}dist/manifest.json`;
  const manifest = JSON.parse(await Bun.file(path).text());
  manifest.version = version;
  await Bun.write(path, JSON.stringify(manifest, null, 2) + "\n");
}
console.log(`Built ${root}dist${version ? ` (version ${version})` : ""}`);
