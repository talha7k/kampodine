import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

// CLI dispatch contract: spawn `node cli.js …` from the package dir and pin
// stdout/stderr/exit-code behavior. Fully hermetic — the passthrough probe
// uses `deploy --help`, which deploy.sh answers from its own usage handler
// (grep of the script header) before any real work, so no network/ssh/OCI.
const pkgDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = join(pkgDir, "cli.js");
const pkg = JSON.parse(readFileSync(join(pkgDir, "package.json"), "utf8")) as {
  version: string;
};

const ALL_COMMANDS = [
  "deploy",
  "bluegreen",
  "vm-prepare",
  "image-import",
  "migrate",
] as const;

interface CliResult {
  status: number | null;
  stdout: string;
  stderr: string;
}

function runCli(args: string[]): CliResult {
  const result = spawnSync(process.execPath, [cliPath, ...args], {
    cwd: pkgDir,
    encoding: "utf8",
  });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function expectUsageListsAllCommands(stdout: string): void {
  for (const command of ALL_COMMANDS) {
    expect(stdout, `usage must list the "${command}" command`).toContain(
      command,
    );
  }
}

describe("kampodine cli dispatch", () => {
  test.each(["--help", "-h"])("%s exits 0 with usage listing all five commands", (flag) => {
    const result = runCli([flag]);
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("Usage:");
    expectUsageListsAllCommands(result.stdout);
  });

  test("no args exits 0 with usage listing all five commands", () => {
    const result = runCli([]);
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("Usage:");
    expectUsageListsAllCommands(result.stdout);
  });

  test("--version prints the package.json version and exits 0", () => {
    const result = runCli(["--version"]);
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(pkg.version);
  });

  test("unknown command exits 2 with usage on stderr", () => {
    const result = runCli(["definitely-not-a-command"]);
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("unknown command: definitely-not-a-command");
    expect(result.stderr).toContain("Usage:");
    expectUsageListsAllCommands(result.stderr);
  });

  test("known command passes args through to the underlying script (deploy --help)", () => {
    const result = runCli(["deploy", "--help"]);
    expect(result.status).toBe(0);
    // These exact lines exist only in deploy.sh's own usage handler (its
    // header grep) — cli.js's top-level usage does not contain them, so this
    // proves the arg passthrough reached the script.
    expect(result.stdout).toContain("kampodine deploy --version <sha7>");
    expect(result.stdout).toContain("kampodine deploy --rollback [<sha7>]");
  });
});
