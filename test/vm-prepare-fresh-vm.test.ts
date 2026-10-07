import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

// vm-prepare sshd-hardening ordering pin: a bare hardening GATE on a fresh
// VM dies before any mutation unless vm-prepare first ENSURES the hardening
// drop-in + the sshd_config Include line + an sshd restart. The order is
// the contract — gate must never precede the ensure.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const vmPrepare = readFileSync(
  join(repoRoot, "scripts", "vm-prepare.sh"),
  "utf8",
);

describe("vm-prepare sshd hardening (ensure before gate)", () => {
  test("ships the hardening drop-in", () => {
    expect(vmPrepare).toContain("99-kampodine-hardening.conf");
  });

  test("ensures the Include line, restarts sshd, THEN gates — in that order", () => {
    const lines = vmPrepare.split("\n");
    const at = (needle: string) =>
      lines.findIndex((l) => l.includes(needle) && !l.trim().startsWith("#"));
    const ensure = at("sshd_config.d/*.conf");
    const install = at("99-kampodine-hardening.conf");
    const restart = lines.findIndex(
      (l) => /rc-service sshd restart/.test(l) && !l.trim().startsWith("#"),
    );
    const gate = at('gate: sshd hardening effective');
    expect(ensure).toBeGreaterThanOrEqual(0);
    expect(install).toBeGreaterThan(ensure);
    expect(restart).toBeGreaterThan(install);
    expect(gate).toBeGreaterThan(restart);
  });
});

// The fresh golden image ships NO curl (vm-prepare runs BEFORE any ansible
// converge that would install it): every remote probe vm-prepare makes must
// ride busybox wget, never curl.
describe("vm-prepare fresh-image constraints", () => {
  test("remote probes never depend on curl (busybox wget only)", () => {
    // any `vm '…curl…'` line is a fresh-VM breaker; the local side (mac)
    // may still use curl — only remote command strings are checked
    const remoteCurl: string[] = [];
    vmPrepare.split("\n").forEach((raw, i) => {
      const line = raw.trim();
      if (line.startsWith("#")) return;
      if (/^\s*vm(_sh)?\b/.test(raw) && /curl/.test(line)) {
        remoteCurl.push(`${i + 1}: ${line}`);
      }
    });
    expect(remoteCurl, "vm/vm_sh remote commands using curl").toEqual([]);
    // and the registry tunnel probe explicitly uses busybox wget
    expect(vmPrepare).toMatch(/busybox wget[^\n]*127\.0\.0\.1:5000/);
  });
});
