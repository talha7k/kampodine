import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, describe, expect, test } from "vitest";

// Guest ANCHOR service shipping contract (blue-green reserved-ip flip,
// guest half): the golden image has NO cloud agent, so a secondary private
// ip assigned by the flip call is never configured inside the guest —
// packets to the reserved public ip die until something runs `ip addr add`.
// The fix ships as a busybox watcher that polls the anchor conf (written by
// `kampodine bluegreen flip` over ssh at flip time) and adds the anchor
// address when present.
//
// Pinned here (static — the real behavioral proof is a live flip run):
//  1. vm-prepare renders BOTH files (watcher + OpenRC unit), enables the
//     unit in the default runlevel, starts it, and gates on it.
//  2. The watcher is busybox-safe (POSIX sh, no bashisms) and ADD-ONLY: it
//     must never run `ip addr del` / `ip addr flush` — rollback cleanup is
//     the flip tool's explicit ssh job, never the watcher's.

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const vmPrepare = readFileSync(
  join(repoRoot, "scripts", "vm-prepare.sh"),
  "utf8",
);

// The watcher ships as a quoted heredoc inside vm-prepare.sh; extract it to
// a temp file so the shell-level gates (bash -n, shellcheck) run on the
// exact bytes that land on the VM.
const watcherMarker = "<<'ANCHOR_WATCHER'";
const start = vmPrepare.indexOf(watcherMarker);
const end = vmPrepare.indexOf("\nANCHOR_WATCHER", start);
expect(start, "ANCHOR_WATCHER heredoc missing").toBeGreaterThanOrEqual(0);
expect(end, "ANCHOR_WATCHER heredoc unterminated").toBeGreaterThan(start);
const watcherScript = vmPrepare.slice(
  start + watcherMarker.length + 1,
  end + 1,
);

const tmp = mkdtempSync(join(tmpdir(), "kampodine-anchor-test."));
const watcherPath = join(tmp, "anchor-watcher.sh");
writeFileSync(watcherPath, watcherScript, { mode: 0o755 });
afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

describe("anchor watcher guest service (blue-green flip guest half)", () => {
  test("watcher is busybox-safe POSIX sh (bash -n + shellcheck + no bashisms)", () => {
    const bash = spawnSync("bash", ["-n", watcherPath], { encoding: "utf8" });
    expect(bash.status, bash.stderr).toBe(0);
    const shellcheck = spawnSync(
      "shellcheck",
      ["-s", "sh", "-S", "warning", watcherPath],
      { encoding: "utf8" },
    );
    expect(
      shellcheck.status,
      `${shellcheck.stdout ?? ""}${shellcheck.stderr ?? ""}`,
    ).toBe(0);
    expect(watcherScript).not.toMatch(/\[\[/); // no bash double-bracket tests
    expect(watcherScript).not.toMatch(/function\s+\w+/); // no function keyword
    expect(watcherScript).not.toMatch(/local\s/); // busybox sh supports it, but POSIX
    // shebang targets the guest's sh, not bash
    expect(watcherScript.startsWith("#!/bin/sh")).toBe(true);
  });

  test("watcher is ADD-ONLY: never removes addresses", () => {
    expect(watcherScript).not.toMatch(/ip\s+(-4\s+)?addr(\ess)?\s+del/);
    expect(watcherScript).not.toMatch(/ip\s+(-4\s+)?addr(ress)?\s+flush/);
    expect(watcherScript).toContain("ip addr add");
  });

  test("watcher polls the anchor conf and anchors the reserved ip", () => {
    expect(watcherScript).toContain("ANCHOR_ADDR");
    expect(watcherScript).toContain("/etc/kampodine/anchor.conf");
  });

  test("vm-prepare ships both files with KEEP IN SYNC pointers to the ansible role", () => {
    expect(vmPrepare).toContain("kampodine-anchor.sh");
    expect(vmPrepare).toContain("/etc/init.d/kampodine-anchor");
    // rendered-content convention: vm-prepare bootstraps, ansible owns after
    expect(vmPrepare).toMatch(
      /KEEP IN SYNC with ansible\/roles\/container-service\/(templates\/kampodine-anchor\.initd\.j2|files\/kampodine-anchor\.sh)/,
    );
    // the watcher lands in /usr/local/sbin — a path the GOLDEN IMAGE does
    // not have (fresh Alpine ships no /usr/local hierarchy; the alpine-base
    // role creates it later, but vm-prepare runs BEFORE any ansible) — the
    // install must mkdir -p first
    const watcherIdx = vmPrepare.indexOf("kampodine-anchor.sh\" \"$HOST:/usr/local/sbin");
    expect(watcherIdx).toBeGreaterThanOrEqual(0);
    const sectionStart = vmPrepare.indexOf("kampodine-anchor watcher service", 0);
    expect(sectionStart).toBeGreaterThan(0);
    const section = vmPrepare.slice(sectionStart, watcherIdx);
    expect(section).toContain("mkdir -p /usr/local/sbin");
    // shipped in the default runlevel, started now (inert without anchor.conf)
    expect(vmPrepare).toMatch(/rc-update add kampodine-anchor default/);
    expect(vmPrepare).toMatch(/rc-service kampodine-anchor start/);
    // fail-closed post gate
    expect(vmPrepare).toMatch(/kampodine-anchor status/);
  });

  // NOTE: the flip-tooling half of the protocol (writing
  // /etc/kampodine/anchor.conf at flip time) is pinned behaviorally in
  // bluegreen-provision.test.ts — this file pins the guest side only.
});
