import { spawnSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

// Script contract gates: every shipped script must parse (bash -n), pass
// shellcheck at warning severity, and carry the executable bit. Hermetic —
// both tools are static analyzers; nothing is executed.
const pkgDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const scriptsDir = join(pkgDir, "scripts");

const scripts = readdirSync(scriptsDir)
  .filter((name) => name.endsWith(".sh"))
  .sort();

const EXPECTED_SCRIPTS = [
  "bluegreen.sh",
  "deploy.sh",
  "image-import.sh",
  "migrate.sh",
  "vm-prepare.sh",
  "status.sh",
] as const;

describe("kampodine script gates", () => {
  test("scripts/ contains the five shipped scripts (guard against an empty/partial glob)", () => {
    expect(scripts).toEqual([...EXPECTED_SCRIPTS].sort());
  });

  test("every script passes bash -n", () => {
    const failures: string[] = [];
    for (const name of scripts) {
      const result = spawnSync("bash", ["-n", join(scriptsDir, name)], {
        encoding: "utf8",
      });
      if (result.status !== 0) {
        failures.push(
          `${name}: bash -n exited ${result.status}\n${result.stderr ?? ""}`,
        );
      }
    }
    expect(failures, "bash -n failures").toEqual([]);
  });

  test("every script passes shellcheck -S warning", () => {
    const failures: string[] = [];
    for (const name of scripts) {
      // NOTE: deliberately no -q flag — this shellcheck install (0.11) has
      // none; exit code 0 means no findings at warning severity or above.
      const result = spawnSync(
        "shellcheck",
        ["-S", "warning", join(scriptsDir, name)],
        { encoding: "utf8" },
      );
      if (result.status !== 0) {
        failures.push(
          `${name}: shellcheck exited ${result.status}\n${result.stdout ?? ""}${result.stderr ?? ""}`,
        );
      }
    }
    expect(failures, "shellcheck -S warning failures").toEqual([]);
  });

  test("every script is executable (mode & 0o111)", () => {
    const failures: string[] = [];
    for (const name of scripts) {
      const mode = statSync(join(scriptsDir, name)).mode;
      if ((mode & 0o111) !== 0o111) {
        failures.push(`${name}: mode ${(mode & 0o777).toString(8)} is not executable`);
      }
    }
    expect(failures, "non-executable scripts").toEqual([]);
  });

  // The DEFAULT profile in ~/.oci/config is NOT the esellar tenancy profile —
  // every oci invocation must pin --profile (regression: image-import.sh ran
  // bare `oci` and died with "compartment 'esellar' not found" even though
  // `oci --profile esellar-api iam compartment list` worked). Static gate on
  // the first line of each invocation (the script convention places
  // --profile there). Message text inside plain double quotes doesn't count;
  // `VAR="$(oci …)"` DOES — code inside a command substitution is code even
  // when wrapped in quotes.
  test("every oci CLI invocation carries --profile", () => {
    const failures: string[] = [];
    for (const name of scripts) {
      const lines = readFileSync(join(scriptsDir, name), "utf8").split("\n");
      lines.forEach((raw, i) => {
        const line = raw.trim();
        if (line.startsWith("#")) return;
        // One positional pass: track double-quote + $(…) state; an
        // `oci <service>` token counts as an invocation when it sits in code
        // context — outside quotes, or inside a command substitution (code
        // even when the substitution is wrapped in double quotes).
        let inQuote = false;
        let subdepth = 0;
        for (let j = 0; j < line.length; j++) {
          if (line.startsWith("$(", j)) { subdepth++; j++; continue; }
          const ch = line[j];
          if (ch === ")" && subdepth > 0) { subdepth--; continue; }
          if (ch === '"' && subdepth === 0) { inQuote = !inQuote; continue; }
          if ((!inQuote || subdepth > 0) && line.startsWith("oci ", j)) {
            if (/^(?:iam|os|compute|network)\s/.test(line.slice(j + 4))) {
              if (!line.includes("--profile")) {
                failures.push(`${name}:${i + 1}: oci call without --profile: ${line}`);
              }
              return; // first invocation on the line decides
            }
          }
        }
      });
    }
    expect(failures, "oci invocations missing --profile").toEqual([]);
  });

  // The OCI CLI applies --query PER PAGE: `compute image list` without --all
  // filters only the first page (default sort puts platform images there), so
  // a freshly imported custom image is invisible and bluegreen provision dies
  // with "no esellar-alpine* custom image". Regression pin: image lookups
  // must page over everything (--all) before filtering.
  test("oci compute image list carries --all", () => {
    const failures: string[] = [];
    for (const name of scripts) {
      const lines = readFileSync(join(scriptsDir, name), "utf8").split("\n");
      lines.forEach((raw, i) => {
        const line = raw.trim();
        if (line.startsWith("#")) return;
        if (/oci\s+compute\s+image\s+list\s/.test(line) && !line.includes("--all")) {
          failures.push(`${name}:${i + 1}: compute image list without --all: ${line}`);
        }
      });
    }
    expect(failures, "compute image list missing --all").toEqual([]);
  });
});

// inject gate: the Alpine verify must MATCH a 3.x release string — a
// non-empty check would accept the un-rebooted donor guest's banner — and
// a failed reboot must not be swallowed.
test("bluegreen inject: release-string match + surfaced reboot failure", () => {
  const src = readFileSync("scripts/bluegreen.sh", "utf8");
  expect(src).toMatch(/\[\[ "\$rel" =~ \^3\\\.\[0-9\]\+\\\.\[0-9\]\+ \]\]/);
  expect(src).toContain("reboot -f FAILED");
  expect(src).not.toMatch(/sudo reboot -f' >\/dev\/null 2>&1 \|\| true/);
});
