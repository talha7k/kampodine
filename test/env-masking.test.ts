import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeEach, describe, expect, test } from "vitest";

// env subcommand contract — SECRETS NEVER PRINT:
// `env list`, `env push`, and the `env pull` summaries may only surface
// FINGERPRINTS (KEY + value length + first 2 chars). Raw values move exactly
// twice: push uploads the local file, pull streams the remote file to
// stdout/--out. Hermetic: ssh/scp are PATH shims backed by fixtures, no
// network, no real VM.
const pkgDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const cliPath = join(pkgDir, "cli.js");

const REMOTE_ENV_FIXTURE = [
  "# comment line — must be skipped",
  "DATABASE_URL=postgres://user:sup3rs3cret-p4ssw0rd-value@db.internal:5432/appdb",
  "API_TOKEN=sk-live-abc123XYZ confidentialvalue456",
  "SHORT=ab",
  "EMPTY=",
  'QUOTED="wrapped-s3cret-value-789"',
  "",
].join("\n");

// Tokens that must NEVER leak into command stdout/stderr.
const SECRET_TOKENS = [
  "sup3rs3cret-p4ssw0rd-value",
  "confidentialvalue456",
  "s3cret-value-789",
  "sk-live",
  "postgres://user:",
];

let workDir: string;
let stubDir: string;
let pushSink: string;
let sshLog: string;

beforeEach(() => {
  workDir = mkdtempSync(join(tmpdir(), "kampodine-env-work."));
  stubDir = mkdtempSync(join(tmpdir(), "kampodine-env-stubs."));
  pushSink = join(workDir, "upload-sink");
  sshLog = join(workDir, "ssh-calls.log");
  const fixture = join(workDir, "remote-env-fixture");
  writeFileSync(fixture, REMOTE_ENV_FIXTURE);

  // ssh shim: the remote command arrives as the LAST argv.
  //  - `cat /etc/kampodine/env`  -> emit the fixture (list/pull)
  //  - `umask 077; cat > …`    -> consume stdin into the sink (push upload)
  //  - anything else           -> log the command, consume stdin
  writeFileSync(
    join(stubDir, "ssh"),
    `#!/bin/bash
cmd="\${*: -1}"
printf '%s\\n' "$cmd" >> "${sshLog}"
case "$cmd" in
  "cat /etc/kampodine/env") cat "${join(workDir, "remote-env-fixture")}"; exit 0 ;;
  *"cat > "*) cat > "${pushSink}"; exit 0 ;;
  *) cat >/dev/null; exit 0 ;;
esac
`,
  );
  // scp shim: never used by env.sh (push pipes over ssh stdin) — if a script
  // regresses to scp, the call lands here and the log exposes it.
  writeFileSync(
    join(stubDir, "scp"),
    `#!/bin/bash
printf 'scp %s\\n' "$*" >> "${sshLog}"
exit 0
`,
  );
  for (const tool of ["ssh", "scp"]) {
    chmodSync(join(stubDir, tool), 0o755);
  }
});

afterAll(() => {
  rmSync(workDir, { recursive: true, force: true });
  rmSync(stubDir, { recursive: true, force: true });
});

interface CliResult {
  status: number | null;
  stdout: string;
  stderr: string;
}

function runEnv(args: string[]): CliResult {
  const result = spawnSync(process.execPath, [cliPath, "env", ...args], {
    cwd: pkgDir,
    encoding: "utf8",
    timeout: 20_000,
    env: {
      ...process.env,
      PATH: `${stubDir}:/usr/bin:/bin`,
      KAMPODINE_HOST: "root@203.0.113.9", // TEST-NET-3, never routed
    },
  });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

function expectNoSecretValues(text: string, where: string): void {
  for (const token of SECRET_TOKENS) {
    expect(
      text.includes(token),
      `${where} leaked a secret value fragment: ${token}`,
    ).toBe(false);
  }
}

describe("kampodine env — fingerprint masking", () => {
  test("env list prints KEY + fingerprint (len + 2-char prefix), never values", () => {
    const result = runEnv(["list"]);
    expect(
      result.status,
      `env list failed\nstderr: ${result.stderr}`,
    ).toBe(0);
    expect(result.stdout).toContain("DATABASE_URL");
    expect(result.stdout).toContain("API_TOKEN");
    expect(result.stdout).toContain("SHORT");
    expect(result.stdout).toContain("QUOTED");
    // fingerprints: length + first two chars + ellipsis (length computed
    // from the fixture itself, never hand-counted)
    const dbUrlValue = "postgres://user:sup3rs3cret-p4ssw0rd-value@db.internal:5432/appdb";
    expect(result.stdout).toContain(`len=${dbUrlValue.length}`);
    expect(result.stdout).toContain("po…");
    expect(result.stdout).toContain("sk…");
    expect(result.stdout).toContain("ab…");
    expect(result.stdout).toContain("wr…"); // quotes stripped before fingerprinting
    expect(result.stdout).toContain("(empty)");
    expectNoSecretValues(result.stdout, "env list stdout");
    expectNoSecretValues(result.stderr, "env list stderr");
  });

  test("env push fingerprints the file, uploads it verbatim via 0600 temp + atomic mv, never prints values", () => {
    const localEnv = join(workDir, "local.env");
    writeFileSync(
      localEnv,
      "PUSH_SECRET=ultravalued0ntprintme-9876\nOTHER_KEY=plainvalue-visible-fingerprint-only\n",
    );
    const result = runEnv(["push", "--file", localEnv]);
    expect(
      result.status,
      `env push failed\nstderr: ${result.stderr}`,
    ).toBe(0);
    expect(result.stdout).toContain("PUSH_SECRET");
    expect(result.stdout).toContain("OTHER_KEY");
    expect(result.stdout).toContain("len=");
    expect(result.stdout).toContain("ul…"); // 2-char prefix of PUSH_SECRET
    expectNoSecretValues(result.stdout, "env push stdout");
    // restart hint present
    expect(result.stdout).toContain("restart");
    // the upload used ssh stdin into a umask-077 temp, then chmod 600 + mv
    expect(existsSync(pushSink), "upload never reached the remote").toBe(true);
    expect(readFileSync(pushSink, "utf8")).toBe(
      "PUSH_SECRET=ultravalued0ntprintme-9876\nOTHER_KEY=plainvalue-visible-fingerprint-only\n",
    );
    const calls = readFileSync(sshLog, "utf8");
    expect(calls).toContain("umask 077");
    expect(calls).toContain("chmod 600");
    expect(calls).toContain("mv -f");
    expectNoSecretValues(calls, "ssh command log");
  });

  test("env push refuses a file with no KEY=VALUE lines", () => {
    const junk = join(workDir, "junk.env");
    writeFileSync(junk, "not an env file\njust prose\n");
    const result = runEnv(["push", "--file", junk]);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("KEY=VALUE");
  });

  test("env push requires --file", () => {
    const result = runEnv(["push"]);
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("--file");
  });

  test("env pull --out writes 0600 with the raw payload; summary on stdout is masked", () => {
    const out = join(workDir, "pulled.env");
    const result = runEnv(["pull", "--out", out]);
    expect(result.status, `stderr: ${result.stderr}`).toBe(0);
    // raw payload lands ONLY in the file
    expect(readFileSync(out, "utf8")).toBe(REMOTE_ENV_FIXTURE);
    const mode = statSync(out).mode & 0o777;
    expect(mode, `--out file must be 0600, got ${mode.toString(8)}`).toBe(
      0o600,
    );
    // summary is masked
    expect(result.stdout).toContain("len=");
    expect(result.stdout).toContain("DATABASE_URL");
    expectNoSecretValues(result.stdout, "env pull --out stdout");
    expectNoSecretValues(result.stderr, "env pull --out stderr");
  });

  test("env pull (stdout mode) streams the raw payload; the fingerprint summary goes to stderr, masked", () => {
    const result = runEnv(["pull"]);
    expect(result.status).toBe(0);
    // stdout payload contract: the raw env file (pipe target)
    expect(result.stdout).toBe(REMOTE_ENV_FIXTURE);
    // summary on stderr is masked
    expect(result.stderr).toContain("len=");
    expectNoSecretValues(result.stderr, "env pull stderr summary");
  });

  test("env fingerprint (local preview) masks stdin and --file input", () => {
    const localEnv = join(workDir, "preview.env");
    writeFileSync(localEnv, "LOCAL_ONLY=t0ps3cret-do-not-echo-4242\n");
    const viaFile = spawnSync(
      process.execPath,
      [cliPath, "env", "fingerprint", "--file", localEnv],
      { cwd: pkgDir, encoding: "utf8", timeout: 20_000 },
    );
    expect(viaFile.status).toBe(0);
    expect(viaFile.stdout).toContain("LOCAL_ONLY");
    expect(viaFile.stdout).toContain("t0…");
    expect(viaFile.stdout).not.toContain("t0ps3cret-do-not-echo-4242");

    const viaStdin = spawnSync(
      process.execPath,
      [cliPath, "env", "fingerprint"],
      {
        cwd: pkgDir,
        encoding: "utf8",
        timeout: 20_000,
        input: "STDIN_KEY=anothers3cretvalue-1111\n",
      },
    );
    expect(viaStdin.status).toBe(0);
    expect(viaStdin.stdout).toContain("STDIN_KEY");
    expect(viaStdin.stdout).toContain("an…");
    expect(viaStdin.stdout).not.toContain("anothers3cretvalue-1111");
  });

  test("env without a host target fails with resolution guidance", () => {
    const result = spawnSync(process.execPath, [cliPath, "env", "list"], {
      cwd: pkgDir,
      encoding: "utf8",
      timeout: 20_000,
      env: {
        ...process.env,
        PATH: `${stubDir}:/usr/bin:/bin`,
        KAMPODINE_HOST: "",
        KAMPODINE_SSH_KEY: "",
      },
    });
    expect(result.status).toBe(1);
    const combined = `${result.stderr}${result.stdout}`;
    expect(combined).toContain("--host");
    expect(combined).toContain("KAMPODINE_HOST");
  });
});
