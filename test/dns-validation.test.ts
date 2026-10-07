import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, beforeEach, describe, expect, test } from "vitest";

// dns subcommand gates:
//  1. argument validation (name/type/value/ttl) fires BEFORE any provider
//     call — bad args die locally with exit 1, no oci invocation
//  2. types are pinned to A | AAAA | CNAME
//  3. AUTH RULE: no credential material anywhere — auth is the oci config
//     file / instance principal only; the script must never reference key
//     material tokens, and every oci call carries --profile
//  4. `dns records` formatting works against a fixture oci response (jq),
//     hermetically
const pkgDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const dnsPath = join(pkgDir, "scripts", "dns.sh");

let stubDir: string;
let ociLog: string;

beforeAll(() => {
  stubDir = mkdtempSync(join(tmpdir(), "kampodine-dns-stubs."));
  ociLog = join(stubDir, "oci-calls.log");

  // failing oci stub: proves validation happens before the provider
  writeFileSync(
    join(stubDir, "oci"),
    `#!/bin/sh\nprintf '%s\\n' "$*" >> "${ociLog}"\necho "hermetic oci stub" >&2\nexit 99\n`,
  );
  chmodSync(join(stubDir, "oci"), 0o755);
  // real jq symlink for the records-formatting test
  symlinkSync("/opt/homebrew/bin/jq", join(stubDir, "jq"));
});

beforeEach(() => {
  // fresh provider-call log per test — a validation test must observe ZERO
  // oci invocations for ITS run, not an empty log left by a previous test
  writeFileSync(ociLog, "");
});

afterAll(() => {
  rmSync(stubDir, { recursive: true, force: true });
});

interface Result {
  status: number | null;
  stdout: string;
  stderr: string;
}

function runDns(args: string[], pathOverride?: string): Result {
  const result = spawnSync("bash", [dnsPath, ...args], {
    cwd: pkgDir,
    encoding: "utf8",
    timeout: 20_000,
    env: { ...process.env, PATH: pathOverride ?? `${stubDir}:/usr/bin:/bin` },
  });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

describe("kampodine dns — argument validation (local, pre-provider)", () => {
  test.each([
    {
      name: "rejects a non-DNS name (space)",
      args: ["add", "--name", "bad name", "--type", "A", "--value", "1.2.3.4"],
      expectIn: "invalid --name",
    },
    {
      name: "rejects a name with a slash",
      args: ["add", "--name", "a/b", "--type", "A", "--value", "1.2.3.4"],
      expectIn: "invalid --name",
    },
    {
      name: "rejects a name with shell metacharacters",
      args: ["add", "--name", "`id`", "--type", "A", "--value", "1.2.3.4"],
      expectIn: "invalid --name",
    },
    {
      name: "rejects an unsupported record type",
      args: ["add", "--name", "app", "--type", "TXT", "--value", "hello"],
      expectIn: "A, AAAA, CNAME",
    },
    {
      name: "rejects a lowercase record type",
      args: ["add", "--name", "app", "--type", "a", "--value", "1.2.3.4"],
      expectIn: "A, AAAA, CNAME",
    },
    {
      name: "rejects a non-IP A value",
      args: ["add", "--name", "app", "--type", "A", "--value", "not-an-ip"],
      expectIn: "invalid --value",
    },
    {
      name: "rejects an A value with an octet > 255",
      args: ["add", "--name", "app", "--type", "A", "--value", "256.1.1.1"],
      expectIn: "invalid --value",
    },
    {
      name: "rejects an IPv4 value for AAAA",
      args: ["add", "--name", "app", "--type", "AAAA", "--value", "1.2.3.4"],
      expectIn: "invalid --value",
    },
    {
      name: "rejects a hostname value for A",
      args: [
        "add",
        "--name",
        "app",
        "--type",
        "A",
        "--value",
        "app.example.com",
      ],
      expectIn: "invalid --value",
    },
    {
      name: "rejects an invalid CNAME target",
      args: [
        "add",
        "--name",
        "alias",
        "--type",
        "CNAME",
        "--value",
        "bad host!",
      ],
      expectIn: "invalid --value",
    },
    {
      name: "rejects a non-numeric ttl",
      args: [
        "add",
        "--name",
        "app",
        "--type",
        "A",
        "--value",
        "1.2.3.4",
        "--ttl",
        "abc",
      ],
      expectIn: "invalid --ttl",
    },
    {
      name: "rejects a ttl below the OCI floor",
      args: [
        "add",
        "--name",
        "app",
        "--type",
        "A",
        "--value",
        "1.2.3.4",
        "--ttl",
        "10",
      ],
      expectIn: "invalid --ttl",
    },
    {
      name: "rejects a ttl above the OCI ceiling",
      args: [
        "add",
        "--name",
        "app",
        "--type",
        "A",
        "--value",
        "1.2.3.4",
        "--ttl",
        "999999",
      ],
      expectIn: "invalid --ttl",
    },
    {
      name: "add requires --name",
      args: ["add", "--type", "A", "--value", "1.2.3.4"],
      expectIn: "--name",
    },
    {
      name: "add requires --type",
      args: ["add", "--name", "app", "--value", "1.2.3.4"],
      expectIn: "--type",
    },
    {
      name: "add requires --value",
      args: ["add", "--name", "app", "--type", "A"],
      expectIn: "--value",
    },
    {
      name: "rm requires --type",
      args: ["rm", "--name", "app", "--value", "1.2.3.4"],
      expectIn: "--type",
    },
    {
      name: "rm requires --value",
      args: ["rm", "--name", "app", "--type", "A"],
      expectIn: "--value",
    },
  ])("$name", ({ args, expectIn }) => {
    const result = runDns(args);
    expect(
      result.status,
      `expected exit 1 for: ${args.join(" ")}\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
    ).toBe(1);
    expect(result.stderr).toContain(expectIn);
    // validation must fire BEFORE any provider call
    if (existsSyncNoFalse(ociLog)) {
      expect(
        readFileSync(ociLog, "utf8"),
        "validation failed AFTER invoking oci",
      ).toBe("");
    }
  });

  test("bare dns prints usage and exits 2 (never silently does nothing)", () => {
    const result = runDns([]);
    expect(result.status).toBe(2);
    expect(result.stdout).toContain("Usage:");
    expect(result.stdout).toContain("kampodine dns records");
    expect(result.stdout).toContain("Examples:");
  });

  test("unknown dns subcommand exits 2 with usage", () => {
    const result = runDns(["frobnicate"]);
    expect(result.status).toBe(2);
    expect(result.stdout + result.stderr).toContain("Usage:");
  });

  test("valid args reach the provider check: missing oci CLI dies with install guidance", () => {
    const noOciDir = mkdtempSync(join(tmpdir(), "kampodine-dns-nooci."));
    try {
      // empty stub dir + /bin only: no oci anywhere in PATH (hermetic — do
      // not rely on the machine's /usr/bin lacking oci)
      const result = runDns(
        ["add", "--name", "app", "--type", "A", "--value", "1.2.3.4"],
        `${noOciDir}:/bin`,
      );
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("oci CLI not found");
    } finally {
      rmSync(noOciDir, { recursive: true, force: true });
    }
  });

  test("oci present but jq absent dies with jq guidance", () => {
    const noJqDir = mkdtempSync(join(tmpdir(), "kampodine-dns-nojq."));
    writeFileSync(join(noJqDir, "oci"), "#!/bin/sh\nexit 0\n");
    chmodSync(join(noJqDir, "oci"), 0o755);
    try {
      // /bin only — some machines ship a system jq in /usr/bin; everything
      // dns.sh runs before the jq check is bash builtins, so /bin suffices
      const result = runDns(["records", "--zone", "demo"], `${noJqDir}:/bin`);
      expect(result.status).toBe(1);
      expect(result.stderr).toContain("jq not found");
    } finally {
      rmSync(noJqDir, { recursive: true, force: true });
    }
  });
});

describe("kampodine dns — records formatting (fixture oci, hermetic)", () => {
  test("dns records --zone renders domain/type/ttl/value rows from the oci JSON", () => {
    const fixtureDir = mkdtempSync(join(tmpdir(), "kampodine-dns-fixture."));
    const fixtureOciLog = join(fixtureDir, "oci-calls.log"); // own log — shared stubDir log accumulates
    const recordsJson = JSON.stringify({
      data: {
        items: [
          {
            domain: "app.example.com.",
            rtype: "A",
            ttl: 300,
            rdata: "203.0.113.10",
          },
          {
            domain: "www.example.com.",
            rtype: "CNAME",
            ttl: 3600,
            rdata: "app.example.com.",
          },
        ],
      },
    });
    writeFileSync(
      join(fixtureDir, "oci"),
      `#!/bin/sh
printf '%s\\n' "$*" >> "${fixtureOciLog}"
case "$*" in
  *"iam compartment list"*) echo "ocid1.compartment.oc1..fixture-compartment" ;;
  *"record zone get"*)
    cat <<'JSON'
${recordsJson}
JSON
    ;;
  *) echo "unexpected oci call in fixture: $*" >&2; exit 99 ;;
esac
`,
    );
    chmodSync(join(fixtureDir, "oci"), 0o755);
    try {
      const result = runDns(["records", "--zone", "demo-zone"], `${fixtureDir}:/usr/bin:/bin`);
      expect(result.status, `stderr: ${result.stderr}`).toBe(0);
      expect(result.stdout).toContain("app.example.com.");
      expect(result.stdout).toContain("CNAME");
      expect(result.stdout).toContain("3600");
      expect(result.stdout).toContain("203.0.113.10");
      // every oci invocation carried --profile (auth profile pinning, same
      // rule as bluegreen/image-import)
      const calls = readFileSync(fixtureOciLog, "utf8").trim().split("\n");
      expect(calls.length).toBe(2); // compartment resolve + record list
      for (const call of calls) {
        expect(call, `oci call without --profile: ${call}`).toContain(
          "--profile",
        );
      }
    } finally {
      rmSync(fixtureDir, { recursive: true, force: true });
    }
  });
});

describe("kampodine dns — auth rule (static)", () => {
  test("dns.sh never references credential material tokens", () => {
    const src = readFileSync(dnsPath, "utf8");
    const forbidden =
      /--auth[-_]token|api[-_]key|private[-_]key|password|security[-_]token-file\s*=|OCI_API_KEY/i;
    expect(src).not.toMatch(forbidden);
  });

  test("dns.sh documents and supports the sanctioned auth modes", () => {
    const src = readFileSync(dnsPath, "utf8");
    expect(src).toContain("instance_principal");
    expect(src).toContain("--profile");
  });
});

function existsSyncNoFalse(path: string): boolean {
  try {
    readFileSync(path, "utf8");
    return true;
  } catch {
    return false;
  }
}
