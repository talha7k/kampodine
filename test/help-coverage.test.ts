import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, describe, expect, test } from "vitest";

// First-class help contract: EVERY command (and every bluegreen/env/dns
// sub-step) answers --help and -h with exit 0 and a usage block that carries
// all three sections: `Usage:`, the full command path, and `Examples:`.
// Hermetic: the CLI runs with a PATH whose curl/ssh/scp/oci are stubs that
// exit 99 — a script that reaches a side-effect tool while handling --help
// fails loudly instead of touching the network.
const pkgDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = join(pkgDir, "cli.js");

const stubDir = mkdtempSync(join(tmpdir(), "kampodine-help-stubs."));
for (const tool of ["curl", "ssh", "scp", "oci"]) {
  writeFileSync(
    join(stubDir, tool),
    `#!/bin/sh\necho "hermetic stub executed: ${tool} $*" >&2\nexit 99\n`,
  );
  // exec via PATH needs the exec bit
  chmodSync(join(stubDir, tool), 0o755);
}

afterAll(() => {
  rmSync(stubDir, { recursive: true, force: true });
});

// Every help entry point. `signature` is the command path that MUST appear
// in the help output. Top-level heads must stay in sync with cli.js's
// dispatch table (enforced by the sync test below).
const HELP_MATRIX: Array<{ path: string[]; signature: string }> = [
  { path: ["deploy"], signature: "kampodine deploy" },
  { path: ["bluegreen"], signature: "kampodine bluegreen" },
  { path: ["bluegreen", "status"], signature: "kampodine bluegreen status" },
  { path: ["bluegreen", "init"], signature: "kampodine bluegreen init" },
  {
    path: ["bluegreen", "provision"],
    signature: "kampodine bluegreen provision",
  },
  { path: ["bluegreen", "flip"], signature: "kampodine bluegreen flip" },
  {
    path: ["bluegreen", "rollback"],
    signature: "kampodine bluegreen rollback",
  },
  { path: ["vm-prepare"], signature: "kampodine vm-prepare" },
  { path: ["image-import"], signature: "kampodine image-import" },
  { path: ["migrate"], signature: "kampodine migrate" },
  { path: ["status"], signature: "kampodine status" },
  { path: ["env"], signature: "kampodine env" },
  { path: ["env", "list"], signature: "kampodine env list" },
  { path: ["env", "push"], signature: "kampodine env push" },
  { path: ["env", "pull"], signature: "kampodine env pull" },
  {
    path: ["env", "fingerprint"],
    signature: "kampodine env fingerprint",
  },
  { path: ["dns"], signature: "kampodine dns" },
  { path: ["dns", "records"], signature: "kampodine dns records" },
  { path: ["dns", "add"], signature: "kampodine dns add" },
  { path: ["dns", "rm"], signature: "kampodine dns rm" },
];

interface CliResult {
  status: number | null;
  stdout: string;
  stderr: string;
}

function runCli(args: string[]): CliResult {
  const result = spawnSync(process.execPath, [cliPath, ...args], {
    cwd: pkgDir,
    encoding: "utf8",
    timeout: 20_000,
    env: { ...process.env, PATH: `${stubDir}:/usr/bin:/bin` },
  });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

describe("kampodine --help coverage (every subcommand)", () => {
  test.each(HELP_MATRIX.map((entry) => [entry.path.join(" "), entry]))(
    "%s --help exits 0 with Usage + signature + Examples",
    (_label, entry) => {
      const result = runCli([...entry.path, "--help"]);
      expect(
        result.status,
        `--help must exit 0 for: ${entry.path.join(" ")}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
      ).toBe(0);
      expect(result.stdout).toContain("Usage:");
      expect(result.stdout).toContain(entry.signature);
      expect(result.stdout).toContain("Examples:");
      expect(result.stdout.length).toBeGreaterThan(40);
    },
  );

  test.each(HELP_MATRIX.map((entry) => [entry.path.join(" "), entry]))(
    "%s -h behaves identically to --help",
    (_label, entry) => {
      const result = runCli([...entry.path, "-h"]);
      expect(result.status).toBe(0);
      expect(result.stdout).toContain("Usage:");
      expect(result.stdout).toContain(entry.signature);
      expect(result.stdout).toContain("Examples:");
    },
  );

  // Enumeration honesty: if a command is added to cli.js's dispatch table
  // without a HELP_MATRIX entry, this fails — help coverage can't silently
  // rot when the command index grows.
  test("HELP_MATRIX covers every command in the cli.js dispatch table", () => {
    const source = Object.keys(
      JSON.parse(
        JSON.stringify(parseDispatchTableFromCliSource()),
      ) as Record<string, string>,
    );
    const heads = new Set(HELP_MATRIX.map((entry) => entry.path[0]));
    for (const command of source) {
      expect(
        heads.has(command),
        `command "${command}" exists in cli.js but has no HELP_MATRIX entry (and no sub-steps enumerated)`,
      ).toBe(true);
    }
  });
});

/** Parse the `const commands = { … }` keys out of cli.js source. */
function parseDispatchTableFromCliSource(): Record<string, string> {
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
