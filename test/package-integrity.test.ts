import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

// Package integrity: bin wiring, published-file manifest, license/version
// hygiene, and the cli.js → scripts/ dispatch mapping (parsed from source,
// never hardcoded).
const pkgDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const pkgPath = join(pkgDir, "package.json");
const pkg = JSON.parse(readFileSync(pkgPath, "utf8")) as {
  name: string;
  version: string;
  license: string;
  bin: Record<string, string>;
  files: string[];
};

const ALL_COMMANDS = [
  "deploy",
  "bluegreen",
  "vm-prepare",
  "status",
  "image-import",
  "migrate",
  "env",
  "dns",
] as const;

const SEMVER_RE =
  /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

function isFile(path: string): boolean {
  return existsSync(path) && statSync(path).isFile();
}

/** Extract the `const commands = { … }` dispatch table from cli.js source. */
function parseCliDispatchTable(): Record<string, string> {
  const source = readFileSync(join(pkgDir, "cli.js"), "utf8");
  const block = source.match(/const commands = \{([\s\S]*?)\};/);
  expect(block, "cli.js must declare a `const commands = { … }` table").not.toBeNull();
  const table: Record<string, string> = {};
  for (const match of block![1].matchAll(
    /(?:"([^"]+)"|([A-Za-z_$][\w$]*)):\s*"([^"]+)"/g,
  )) {
    table[match[1] ?? match[2]] = match[3];
  }
  return table;
}

describe("kampodine package integrity", () => {
  test("name is kampodine and bin maps kampodine → ./cli.js on disk", () => {
    expect(pkg.name).toBe("kampodine");
    expect(pkg.bin).toEqual({ kampodine: "./cli.js" });
    expect(isFile(join(pkgDir, pkg.bin.kampodine))).toBe(true);
  });

  test("version parses as semver", () => {
    expect(pkg.version).toMatch(SEMVER_RE);
  });

  test("license is AGPL-3.0", () => {
    expect(pkg.license).toBe("AGPL-3.0");
  });

  test("every entry in the files manifest exists on disk", () => {
    expect(pkg.files.length).toBeGreaterThan(0);
    for (const entry of pkg.files) {
      const path = join(pkgDir, entry);
      if (entry.endsWith("/")) {
        expect(
          existsSync(path) && statSync(path).isDirectory(),
          `files entry "${entry}" must be a directory`,
        ).toBe(true);
      } else {
        expect(isFile(path), `files entry "${entry}" must exist`).toBe(true);
      }
    }
  });

  test("README.md and LICENSE exist at the package root", () => {
    expect(isFile(join(pkgDir, "README.md"))).toBe(true);
    expect(isFile(join(pkgDir, "LICENSE"))).toBe(true);
  });

  test("cli.js dispatch table maps all five commands to existing scripts", () => {
    const table = parseCliDispatchTable();
    expect(Object.keys(table).sort()).toEqual([...ALL_COMMANDS].sort());
    for (const [command, script] of Object.entries(table)) {
      const scriptPath = join(pkgDir, "scripts", script);
      expect(
        isFile(scriptPath),
        `command "${command}" → scripts/${script} must exist`,
      ).toBe(true);
      expect(script.endsWith(".sh"), `${script} must be a .sh script`).toBe(true);
    }
  });
});
