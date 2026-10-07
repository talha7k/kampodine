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
  "status",
  "image-import",
  "migrate",
  "env",
  "dns",
] as const;

// The top-level index groups commands like vercel's — a missing heading or a
// command outside its group is a help regression.
const INDEX_GROUPS = ["DEPLOY", "INFRA", "DNS", "ENV"] as const;

const COMMAND_GROUP: Record<(typeof ALL_COMMANDS)[number], string> = {
  deploy: "DEPLOY",
  bluegreen: "DEPLOY",
  migrate: "DEPLOY",
  "vm-prepare": "INFRA",
  status: "INFRA",
  "image-import": "INFRA",
  env: "ENV",
  dns: "DNS",
};

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
  test.each(["--help", "-h"])("%s exits 0 with usage listing all eight commands", (flag) => {
    const result = runCli([flag]);
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("Usage:");
    expectUsageListsAllCommands(result.stdout);
  });

  test("no args exits 0 with the grouped command index listing all eight commands", () => {
    const result = runCli([]);
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("Usage:");
    expectUsageListsAllCommands(result.stdout);
  });

  test("the command index is grouped (DEPLOY / INFRA / DNS / ENV) with every command under its group", () => {
    const result = runCli(["--help"]);
    expect(result.status).toBe(0);
    for (const group of INDEX_GROUPS) {
      expect(
        result.stdout,
        `missing ${group} group heading in the top-level index`,
      ).toMatch(new RegExp(`\\n${group}\\n`));
    }
    // each command's index line must sit AFTER its group heading and BEFORE
    // the next heading — the group mapping stays honest
    for (const command of ALL_COMMANDS) {
      const group = COMMAND_GROUP[command];
      const groupAt = result.stdout.indexOf(`\n${group}\n`);
      const nextHeads = INDEX_GROUPS.map((g) => result.stdout.indexOf(`\n${g}\n`))
        .filter((at) => at > groupAt);
      const sectionEnd = nextHeads.length > 0 ? Math.min(...nextHeads) : result.stdout.length;
      const section = result.stdout.slice(groupAt, sectionEnd);
      expect(section, `"${command}" must be listed under ${group}`).toContain(command);
    }
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

  test("env and dns dispatch to their scripts (passthrough proof)", () => {
    // `env fingerprint` with stdin round-trips through env.sh — a pure local
    // path that proves dispatch reached scripts/env.sh without any ssh/OCI.
    const result = spawnSync(process.execPath, [cliPath, "env", "fingerprint"], {
      cwd: pkgDir,
      encoding: "utf8",
      timeout: 20_000,
      input: "PROBE_KEY=probe-value-abcdef\n",
    });
    expect(result.status).toBe(0);
    expect(result.stdout).toContain("PROBE_KEY");
    expect(result.stdout).not.toContain("probe-value-abcdef");
  });
});
