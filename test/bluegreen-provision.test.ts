import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, test } from "vitest";

// Hermetic behavioral tests for `bluegreen provision blue` + the ACME-first
// `flip` / `rollback` flow:
//
//  - CUSTOM-IMAGE path: a UEFI_64 kampodine-alpine* custom image
//    launches natively, no injection. The stub models two OCI CLI behaviors —
//    `compute image list` first-page-only --query filtering without --all,
//    and the post-query response shape.
//  - PLATFORM-IMAGE + INJECTION path (provision-via-migrate):
//    OCI A1 rejects imported custom images (firmware pinned BIOS at
//    import), but the template instance itself RUNS Alpine on an instance
//    whose image metadata is the Ubuntu PLATFORM image (it was built by
//    platform-image launch + disk injection). So with no UEFI
//    custom image available, provision must: query the template's image-id
//    from its LIVE instance record (never hardcode), launch from it, then
//    stream the golden qcow2 onto the new instance's boot disk over ssh
//    (qemu-img convert -> gzip | ssh 'gunzip | sudo dd', reboot, verify
//    Alpine). BIOS-pinned imports must be SKIPPED, never launched.
//  - ACME-FIRST FLIP: the flip is
//    health gate -> anchor.conf written on the TARGET over ssh (the guest
//    kampodine-anchor watcher picks the address up) -> OCI assign -> ACME for
//    the reserved-IP sslip hostname on the TARGET's kamal-proxy (HTTP-01
//    needs the reserved ip already routed to the target — hence AFTER the
//    assign) -> https through the reserved ip with a VALID cert + served-sha
//    check -> only then FLIPPED. Auto-rollback on any post-assign failure:
//    reassign to the other color's EXISTING anchor (lookup-only — never
//    create target-side artifacts) or unassign to dormant, plus
//    anchor.conf removal + address del on the failed target. `rollback` =
//    dormant: holder cleanup + OCI unassign.

const GREEN_INSTANCE = "ocid1.instance.oc1.test.green";
const PLATFORM_IMAGE = "ocid1.image.oc1.test.platform-ubuntu";
const VNIC = "ocid1.vnic.oc1.test.vnic1";
const GREEN_VNIC = "ocid1.vnic.oc1.test.vnic-green";
const SUBNET = "ocid1.subnet.oc1.test.subnet1";
const LAUNCHED = "ocid1.instance.oc1.test.blue-new";
const BLUE_IP = "203.0.113.10";

interface StubOpts {
  // newest kampodine-alpine* custom image id — null = none exists in the compartment
  customImage: string | null;
  // launch-options firmware the stub reports for that custom image
  customFirmware: string;
  // public keys `ssh-add -L` prints — null = the stub binary is absent
  agentKeys?: string | null;
}

interface Stub {
  bin: string;
  launchLog: string;
  sshLog: string;
  qemuLog: string;
  keygenLog: string;
  curlLog: string;
}

function stubBin(tmp: string, opts: StubOpts): Stub {
  const bin = join(tmp, "bin");
  mkdirSync(bin, { recursive: true });
  const launchLog = join(tmp, "launch-args.log");
  const sshLog = join(tmp, "ssh-args.log");
  const qemuLog = join(tmp, "qemu-args.log");
  const customLine = opts.customImage
    ? `echo "${opts.customImage}" ;;`
    : "exit 0 ;;";
  const ociScript = `#!/usr/bin/env bash
LAUNCH_LOG="${launchLog}"
STATE="$(dirname "${launchLog}")"
args="$*"
# an empty shell argument (the documented unassign: --private-ip-id "") leaves
# a double space in $* — collapse so flag-sequence patterns stay readable
while [[ "$args" == *"  "* ]]; do args="\${args//  / }"; done
case "$args" in
  *"iam compartment list"*)
    if [[ "$args" != *"--all"* ]]; then echo "[]"; exit 0; fi
    echo "ocid1.compartment.oc1.test.comp" ;;
  *"compute instance list"*)
    # honor the --display-name filter: green is RUNNING (the pair template),
    # blue appears RUNNING only AFTER the stub recorded the launch (stateful,
    # like real OCI). Post-query shape ("<id> <ad>" — the script's --query
    # selects id + availability-domain only).
    if [[ "$args" == *"--display-name kampodine-green"* ]]; then
      echo "${GREEN_INSTANCE} LnzZ:ME-RIYADH-1-AD-1"
    elif [[ "$args" == *"--display-name kampodine-blue"* && -s "$LAUNCH_LOG" ]]; then
      echo "${LAUNCHED} LnzZ:ME-RIYADH-1-AD-1"
    fi ;;
  *"compute instance get"*)
    # dual use: template image-id lookup vs lifecycle polling. The CLI's
    # instance get has NO --wait-for-state option (regression: the script
    # used it and died instantly) — the stub rejects it like the real CLI,
    # and lifecycle polls return PROVISIONING once, then RUNNING (proves the
    # script actually polls).
    if [[ "$args" == *"--wait-for-state"* ]]; then
      echo "Usage: oci compute instance get [OPTIONS]" >&2
      echo "Error: No such option '--wait-for-state'." >&2
      exit 2
    fi
    if [[ "$args" == *'"image-id"'* ]]; then
      echo "${PLATFORM_IMAGE}"
    else
      poll_file=$(dirname "${launchLog}")/poll-count
      n=$(cat "$poll_file" 2>/dev/null || echo 0)
      echo $((n + 1)) > "$poll_file"
      if [[ "$n" -eq 0 ]]; then echo "PROVISIONING"; else echo "RUNNING"; fi
    fi ;;
  *"compute image get"*)
    echo "${opts.customFirmware}" ;;
  *"compute vnic-attachment list"*)
    # the live CLI REQUIRES the compartment flag here (Missing option
    # --compartment-id) — reject a bare call like the real binary
    if [[ "$args" != *" -c "* && "$args" != *"--compartment-id"* ]]; then
      echo "Error: Missing option(s) --compartment-id." >&2
      exit 2
    fi
    # one subcommand, two lookups — the --query field decides: vnic-id vs
    # subnet-id; the instance decides which VNIC (blue vs green have distinct
    # VNICs — flip auto-rollback must see green as anchor-less).
    if [[ "$args" == *'"subnet-id"'* ]]; then echo "${SUBNET}";
    elif [[ "$args" == *"--instance-id ${GREEN_INSTANCE}"* ]]; then echo "${GREEN_VNIC}";
    else echo "${VNIC}"; fi ;;
  *"network vnic get"*)
    echo "${BLUE_IP}" ;;
  *"network private-ip get"*)
    # the anchor's private ADDRESS inside the VNIC subnet (the flip derives
    # ANCHOR_ADDR from it + the subnet cidr for the guest anchor.conf)
    echo "10.0.0.14" ;;
  *"network subnet get"*)
    echo "10.0.0.0/24" ;;
  *"network private-ip list"*)
    # the live CLI (3.94.1) takes NO compartment flag here — it filters by
    # --vnic-id / --subnet-id only; reject -c like the real binary (the flip
    # path depends on it)
    if [[ "$args" == *" -c "* || "$args" == *"-c "* ]]; then
      echo "Error: No such option '-c'." >&2
      exit 2
    fi
    # reserved-anchor lookup filters for the SECONDARY private ip
    # (is-primary == false); the stub answers with the anchor ONLY for the
    # vnic that actually owns it (stateful, like real OCI — the flip's
    # lookup-only callers must see green as anchor-less).
    if [[ "$args" == *'"is-primary"'* ]]; then
      if [[ -f "$STATE/anchor-created" ]]; then
        av="$(cat "$STATE/anchor-vnic" 2>/dev/null || true)"
        [[ -n "$av" && "$args" == *"--vnic-id \${av} "* ]] && echo "ocid1.privateip.oc1.test.anchor"
      fi
      exit 0
    fi
    echo "ocid1.privateip.oc1.test.priv1" ;;
  *"network private-ip create"*)
    : > "$STATE/anchor-created"
    grep -o 'ocid1\\.vnic\\.oc1\\.[^ ]*' <<< "$args" | head -1 > "$STATE/anchor-vnic"
    printf '%s\\n' "$args" > "$STATE/anchor.log"
    echo "ocid1.privateip.oc1.test.anchor" ;;
  *"network public-ip update"*)
    # empty --private-ip-id == UNASSIGN (documented CLI semantics); an ocid
    # assigns. Holder state lives in a file so public-ip list reads it back.
    if [[ "$args" == *"--private-ip-id --"* ]]; then
      printf '%s\\n' "$args" > "$STATE/unassign.log"
      : > "$STATE/reserved-holder"
      echo "AVAILABLE"
    else
      printf '%s\\n' "$args" > "$STATE/flip.log"
      printf 'ocid1.privateip.oc1.test.anchor' > "$STATE/reserved-holder"
      echo "ASSIGNED"
    fi ;;
  *"network public-ip list"*)
    h="$(cat "$STATE/reserved-holder" 2>/dev/null || true)"
    echo "ocid1.publicip.oc1.test.reserved 84.0.0.7 \${h:--}" ;;
  *"compute image list"*)
    # OCI applies --query per page: without --all the first page holds only
    # platform images -> the kampodine-alpine filter matches nothing.
    if [[ "$args" != *"--all"* ]]; then exit 0; fi
    ${customLine}
  *"compute instance launch"*)
    printf '%s\\n' "$args" > "$LAUNCH_LOG"
    echo "${LAUNCHED}" ;;
  *) echo "stub-oci: unexpected call: $args" >&2; exit 1 ;;
esac
`;
  const sshScript = `#!/usr/bin/env bash
SSH_LOG="${sshLog}"
STATE="$(dirname "${sshLog}")"
printf '%s\\n' "$*" >> "$SSH_LOG"
if [[ "$*" == *"alpine-release"* ]]; then echo "3.22.6"; fi
# flip protocol state, keyed on the exact command shape (write has printf+the
# ANCHOR_ADDR key; the rollback conf read greps; cleanup removes):
if [[ "$*" == *"printf"*"ANCHOR_ADDR="*"anchor.conf"* ]]; then : > "$STATE/anchor-conf"; fi
if [[ "$*" == *"grep"*"ANCHOR_ADDR"* ]]; then echo 'ANCHOR_ADDR="10.0.0.14/24"'; fi
if [[ "$*" == *"rm -f"*"anchor.conf"* ]]; then rm -f "$STATE/anchor-conf"; fi
# the guest watcher's addr probe only answers once the conf exists, so the
# script cannot reach the OCI assign without writing the conf FIRST
# (stub-enforced ordering).
if [[ "$*" == *"ip -4 addr show"* ]]; then
  [[ -f "$STATE/anchor-conf" ]] || exit 1
fi
if [[ "$*" == *"ip addr del"* ]]; then : > "$STATE/addr-deleted"; fi
if [[ "$*" == *"kamal-proxy deploy"* ]]; then : > "$STATE/acme-started"; fi
exit 0
`;
  const qemuScript = `#!/usr/bin/env bash
QEMU_LOG="${qemuLog}"
printf '%s\\n' "$*" >> "$QEMU_LOG"
if [[ "$1" == "convert" ]]; then : > "$4"; fi
`;
  const keygenLog = join(tmp, "keygen-args.log");
  const keygenScript = `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "${keygenLog}"
printf '[keygen] %s\\n' "$*" >> "${sshLog}"
`;
  const curlLog = join(tmp, "curl-args.log");
  const curlScript = `#!/usr/bin/env bash
CURL_LOG="${curlLog}"
STATE="$(dirname "${curlLog}")"
printf '%s\\n' "$*" >> "$CURL_LOG"
# the ACME wait loop must POLL: /up answers success only after the target's
# kamal-proxy registration happened (acme-started) AND two failed attempts
# elapsed — a flip that "checks once" or skips the gate cannot reach FLIPPED.
if [[ "$*" == *"/api/auth/ok"* ]]; then
  echo '{"ok":true,"build":"deadbee","git":"deadbeeabcdef"}'
  exit 0
fi
if [[ "$*" == *"/up"* ]]; then
  [[ -f "$STATE/acme-never" ]] && exit 1
  [[ -f "$STATE/acme-started" ]] || exit 1
  n="$(cat "$STATE/curl-count" 2>/dev/null || echo 0)"
  echo $((n + 1)) > "$STATE/curl-count"
  [[ "$n" -ge 2 ]] || exit 1
  echo "ok"
  exit 0
fi
exit 0
`;
  const entries: Array<[string, string]> = [
    ["oci", ociScript],
    ["ssh", sshScript],
    ["qemu-img", qemuScript],
    ["ssh-keygen", keygenScript],
    ["curl", curlScript],
  ];
  if (opts.agentKeys !== null) {
    entries.push([
      "ssh-add",
      `#!/usr/bin/env bash\nprintf '%s\\n' ${JSON.stringify(opts.agentKeys ?? "")}\n`,
    ]);
  }
  for (const [name, body] of entries) {
    const path = join(bin, name);
    writeFileSync(path, body);
    chmodSync(path, 0o755);
  }
  return { bin, launchLog, sshLog, qemuLog, keygenLog, curlLog };
}

const scriptPath = join(dirname(fileURLToPath(import.meta.url)), "..", "scripts", "bluegreen.sh");

describe("bluegreen provision (hermetic, stubbed oci/ssh/qemu-img)", () => {
  let tmp: string;
  let qcow2: string;
  let keyfile: string;

  beforeEach(() => {
    tmp = mkdtempSync(join(tmpdir(), "kampodine-bluegreen-"));
    // the golden disk artifact + ops key the injection path requires
    qcow2 = join(tmp, "kampodine-alpine.qcow2");
    writeFileSync(qcow2, "qcow2-bytes");
    keyfile = join(tmp, "id_ed25519.pub");
    writeFileSync(keyfile, "ssh-ed25519 AAAA test@ops");
  });
  afterEach(() => {
    rmSync(tmp, { recursive: true, force: true });
  });

  function runProvision(stub: Stub, env: Record<string, string> = {}) {
    return spawnSync("bash", [scriptPath, "provision", "blue"], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${stub.bin}:${process.env.PATH}`,
        OCI_COMPARTMENT: "test-compartment",
        ALPINE_QCOW2: qcow2,
        OPS_SSH_PUBKEY: keyfile,
        INJECT_PROBE_SLEEP: "0",
        ...env,
      },
    });
  }

  test("CUSTOM path: a UEFI_64 kampodine-alpine* image launches natively — no injection machinery runs", () => {
    const stub = stubBin(tmp, { customImage: "ocid1.image.oc1.test.custom-uefi", customFirmware: "UEFI_64" });
    const result = runProvision(stub);
    const out = `${result.stdout}${result.stderr}`;
    expect(out).not.toMatch(/unbound variable/);
    expect(result.status, out).toBe(0);
    const launch = readFileSync(stub.launchLog, "utf8");
    expect(launch).toContain("--image-id ocid1.image.oc1.test.custom-uefi");
    expect(launch).toContain("--availability-domain LnzZ:ME-RIYADH-1-AD-1");
    expect(launch).toContain(`--subnet-id ${SUBNET}`);
    expect(launch).toContain("--display-name kampodine-blue");
    // native golden image: no disk streaming, no qemu-img, no ssh
    expect(existsSync(stub.sshLog)).toBe(false);
    expect(existsSync(stub.qemuLog)).toBe(false);
  });

  test("INJECTION path: no UEFI custom image -> launches from the TEMPLATE's live image-id and streams the golden qcow2", () => {
    const stub = stubBin(tmp, { customImage: null, customFirmware: "UEFI_64" });
    const result = runProvision(stub);
    const out = `${result.stdout}${result.stderr}`;
    expect(out).not.toMatch(/unbound variable/);
    expect(result.status, out).toBe(0);
    // launch: the template instance's OWN image (green runs Alpine on it),
    // NOT a hardcode, with the ops key injected for the first (Ubuntu) boot
    const launch = readFileSync(stub.launchLog, "utf8");
    expect(launch).toContain(`--image-id ${PLATFORM_IMAGE}`);
    expect(launch).toContain(`--ssh-authorized-keys-file ${keyfile}`);
    expect(launch).toContain("--display-name kampodine-blue");
    // injection machinery: local qcow2->raw conversion, then the disk stream
    const qemu = readFileSync(stub.qemuLog, "utf8");
    expect(qemu).toContain("convert");
    expect(qemu).toContain("-O raw");
    expect(qemu).toContain(qcow2);
    const ssh = readFileSync(stub.sshLog, "utf8");
    expect(ssh).toMatch(/dd of=/); // the disk write
    expect(ssh).toMatch(/PKNAME/); // boot disk detected on the remote, not hardcoded
    expect(ssh).toMatch(/reboot/); // reboot into the injected disk
    expect(ssh).toMatch(/alpine-release/); // post-reboot Alpine verify
    // every injection ssh call uses a DEDICATED known-hosts file (the
    // reboot changes the host key under the same IP; the user's
    // known_hosts must never see it) — keygen timeline entries are exempt
    for (const line of ssh.split("\n").filter((l) => l && !l.startsWith("[keygen]"))) {
      expect(line).toContain("UserKnownHostsFile");
    }
    // and the IP is scrubbed from that file between reboot and the Alpine
    // probes (accept-new refuses a CHANGED key — without the scrub the
    // Alpine verify loop can never succeed). The keygen stub logs
    // into the same timeline as ssh, so the order is pinned end-to-end:
    //   dd write  <  reboot  <  ssh-keygen -R <ip>  <  alpine-release probe
    const timeline = ssh.split("\n").filter(Boolean);
    const at = (needle: string) => timeline.findIndex((l) => l.includes(needle));
    expect(at("dd of=")).toBeGreaterThanOrEqual(0);
    expect(at("reboot")).toBeGreaterThan(at("dd of="));
    expect(at(`[keygen] -R ${BLUE_IP}`)).toBeGreaterThan(at("reboot"));
    expect(at("alpine-release")).toBeGreaterThan(at(`[keygen] -R ${BLUE_IP}`));
    // the reboot ssh MUST carry session-keepalive options: reboot -f kills
    // the platform sshd without closing the TCP session, and a bare
    // ConnectTimeout only bounds connection ESTABLISHMENT — without
    // keepalives a wedged reboot session hangs the whole provisioner
    expect(timeline.find((l) => l.includes("reboot"))).toContain(
      "ClientAliveInterval",
    );
    expect(out).toContain(`INJECTED kampodine-blue`);
    expect(out).toContain(BLUE_IP);
  });

  test("BIOS-pinned import is SKIPPED: the A1 firmware gate must not be re-hit, provision falls through to injection", () => {
    const stub = stubBin(tmp, { customImage: "ocid1.image.oc1.test.imported-bios", customFirmware: "BIOS" });
    const result = runProvision(stub);
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).toBe(0);
    const launch = readFileSync(stub.launchLog, "utf8");
    expect(launch).not.toContain("imported-bios");
    expect(launch).toContain(`--image-id ${PLATFORM_IMAGE}`);
    const ssh = readFileSync(stub.sshLog, "utf8");
    expect(ssh).toMatch(/dd of=/); // injection took over
  });

  test("missing golden qcow2 dies BEFORE launching anything (pre-launch gate)", () => {
    const stub = stubBin(tmp, { customImage: null, customFirmware: "UEFI_64" });
    rmSync(qcow2);
    const result = runProvision(stub);
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).not.toBe(0);
    expect(out).toMatch(/golden qcow2 not found/);
    expect(existsSync(stub.launchLog)).toBe(false); // never launched
  });

  test("missing ops ssh public key dies BEFORE launching anything (pre-launch gate)", () => {
    const stub = stubBin(tmp, { customImage: null, customFirmware: "UEFI_64" });
    rmSync(keyfile);
    const result = runProvision(stub);
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).not.toBe(0);
    expect(out).toMatch(/ops ssh public key not found/);
    expect(existsSync(stub.launchLog)).toBe(false); // never launched
  });

  test("no OPS_SSH_PUBKEY: the AGENT key (ssh-add -L) drives the launch — the ~/.ssh default is not trusted", () => {
    const stub = stubBin(tmp, {
      customImage: null,
      customFirmware: "UEFI_64",
      agentKeys: "ssh-ed25519 AAAAC3 test-agent-key ops",
    });
    // unset OPS_SSH_PUBKEY, and the stale default pub file is ABSENT — the
    // run must still succeed via the agent (a stale
    // ~/.ssh/id_ed25519.pub once launched an unreachable instance)
    rmSync(keyfile);
    const result = runProvision(stub, { OPS_SSH_PUBKEY: "" });
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).toBe(0);
    expect(out).toContain("INJECTED kampodine-blue");
    const launch = readFileSync(stub.launchLog, "utf8");
    expect(launch).toMatch(/--ssh-authorized-keys-file \S+/);
  });

  test("no OPS_SSH_PUBKEY and an empty agent dies BEFORE launching anything (pre-launch gate)", () => {
    const stub = stubBin(tmp, { customImage: null, customFirmware: "UEFI_64", agentKeys: "" });
    rmSync(keyfile);
    const result = runProvision(stub, { OPS_SSH_PUBKEY: "" });
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).not.toBe(0);
    expect(out).toMatch(/no ssh key available/);
    expect(existsSync(stub.launchLog)).toBe(false); // never launched
  });

  function runFlip(
    stub: Stub,
    args: string[],
    env: Record<string, string> = {},
  ) {
    return spawnSync("bash", [scriptPath, "flip", ...args], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${stub.bin}:${process.env.PATH}`,
        OCI_COMPARTMENT: "test-compartment",
        FLIP_POLL_SLEEP: "0",
        ...env,
      },
    });
  }

  // flip the stub into the "pair is up" state: blue RUNNING (no launch
  // recorded — pre-launched), reserved ip dormant.
  function preLaunch(stub: Stub) {
    writeFileSync(stub.launchLog, "pre-launched\n");
  }

  test("FLIP --to blue: ACME-first sequence — anchor conf + guest address BEFORE the OCI assign, kamal-proxy registration + https cert gate AFTER, served-sha verify", () => {
    const stub = stubBin(tmp, { customImage: null, customFirmware: "UEFI_64" });
    preLaunch(stub);
    const result = runFlip(stub, ["--to", "blue"]);
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).toBe(0);
    // the private-ip lookup must not pass -c — the stub rejects it like the
    // live 3.94.1 CLI, so reaching exit 0 proves the call shape is right
    expect(out).toContain("FLIPPED");
    // ACME mechanism: kamal-proxy deploy on the TARGET over ssh for the
    // reserved-ip sslip hostname (HTTP-01 needs the reserved ip routed to
    // the target first — hence registration AFTER the assign)
    expect(out).toContain("84-0-0-7.sslip.io");
    // the reserved ip anchors on a SECONDARY private ip (one public ip per
    // private ip: the primary holds the launch-time ephemeral — assigning
    // the reserved to the primary is a 409). The
    // flip must CREATE the anchor on blue's vnic, then point the reserved
    // at the ANCHOR, never at the primary.
    const anchor = readFileSync(join(stub.launchLog, "..", "anchor.log"), "utf8");
    expect(anchor).toContain(`--vnic-id ${VNIC}`);
    expect(anchor).toContain("kampodine-reserved-anchor");
    const flip = readFileSync(join(stub.launchLog, "..", "flip.log"), "utf8");
    expect(flip).toContain("--public-ip-id ocid1.publicip.oc1.test.reserved");
    expect(flip).toContain("--private-ip-id ocid1.privateip.oc1.test.anchor");
    expect(flip).not.toContain("ocid1.privateip.oc1.test.priv1"); // never the primary
    expect(flip).toContain("--wait-for-state ASSIGNED");
    // STUB-ENFORCED ORDERING: the stub's guest addr probe answers only once
    // anchor.conf was written over ssh, and the OCI assign only happens
    // after that probe passes — reaching flip.log proves conf-write <
    // addr-configured < assign. The ssh timeline pins the rest:
    //   conf write < addr probe < kamal-proxy deploy (ACME registration)
    const ssh = readFileSync(stub.sshLog, "utf8");
    const timeline = ssh.split("\n").filter(Boolean);
    const at = (needle: string) => timeline.findIndex((l) => l.includes(needle));
    expect(at("anchor.conf")).toBeGreaterThanOrEqual(0);
    expect(at("ip -4 addr show")).toBeGreaterThan(at("anchor.conf"));
    expect(at("kamal-proxy deploy")).toBeGreaterThan(at("ip -4 addr show"));
    // the conf write carries the anchor ADDRESS + subnet prefix resolved
    // from OCI (10.0.0.14/24 from private-ip get + subnet cidr) — never a
    // hardcode
    expect(timeline[at("anchor.conf")]).toContain("10.0.0.14/24");
    // https gate: curl with --resolve pins traffic to the RESERVED ip, /up
    // for the 200 + /api/auth/ok for the served-sha verify
    const curl = readFileSync(stub.curlLog, "utf8");
    expect(curl).toMatch(/--resolve 84-0-0-7\.sslip\.io:443:84\.0\.0\.7/);
    expect(curl).toMatch(/https:\/\/84-0-0-7\.sslip\.io\/up/);
    expect(out).toMatch(/deadbee/); // served sha verified through the flip
    // the per-instance health gate runs busybox wget ON the remote (the
    // golden image ships no curl — a curl-based gate calls healthy machines
    // "unhealthy"); the LOCAL https check stays curl
    const healthProbe = timeline.find((l) => l.includes("kampodine-api status"));
    expect(healthProbe).toBeTruthy();
    expect(healthProbe).toContain("busybox wget");
    expect(healthProbe).not.toContain("curl");
  });

  test("FLIP waits for ACME (real polling — several /up attempts before the cert answers)", () => {
    const stub = stubBin(tmp, { customImage: null, customFirmware: "UEFI_64" });
    preLaunch(stub);
    const result = runFlip(stub, ["--to", "blue"]);
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).toBe(0);
    const attempts = readFileSync(stub.curlLog, "utf8")
      .split("\n")
      .filter((l) => l.includes("/up")).length;
    expect(attempts).toBeGreaterThanOrEqual(3); // first two fail in the stub
  });

  test("ACME unobtainable: auto-rollback UNASSIGNS to dormant (never creates an anchor on the other color), cleans conf + address on the target, exits 1", () => {
    const stub = stubBin(tmp, { customImage: null, customFirmware: "UEFI_64" });
    preLaunch(stub);
    // green is NOT running in this stub state (only blue + the
    // dormant reserved ip) — and even when it is, auto-rollback must be
    // lookup-ONLY against the other color's anchor
    writeFileSync(join(stub.launchLog, "..", "acme-never"), "never");
    const result = runFlip(stub, ["--to", "blue"]);
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).toBe(1);
    // unassigned back to DORMANT (empty --private-ip-id), waited to AVAILABLE
    const unassign = readFileSync(
      join(stub.launchLog, "..", "unassign.log"),
      "utf8",
    );
    expect(unassign).toContain("--private-ip-id --");
    expect(unassign).toContain("--wait-for-state AVAILABLE");
    // NO anchor created for the other color: exactly one create total (blue's)
    const anchor = readFileSync(join(stub.launchLog, "..", "anchor.log"), "utf8");
    expect(anchor.match(/private-ip create/g) ?? []).toHaveLength(1);
    // target cleaned: anchor.conf removed + address deleted over ssh
    const ssh = readFileSync(stub.sshLog, "utf8");
    expect(ssh).toMatch(/rm -f \/etc\/kampodine\/anchor\.conf/);
    expect(ssh).toMatch(/ip addr del .?10\.0\.0\.14\/24.?/);
    expect(existsSync(join(stub.launchLog, "..", "anchor-conf"))).toBe(false);
  });

  test("ROLLBACK: holder cleanup (conf removal + address del) then OCI unassign to dormant — no anchor create", () => {
    const stub = stubBin(tmp, { customImage: null, customFirmware: "UEFI_64" });
    preLaunch(stub);
    // holder state: blue owns the reserved ip via its anchor (blue's vnic!),
    // conf written on the guest
    writeFileSync(join(stub.launchLog, "..", "anchor-created"), "1");
    writeFileSync(join(stub.launchLog, "..", "anchor-vnic"), VNIC);
    writeFileSync(join(stub.launchLog, "..", "reserved-holder"), "ocid1.privateip.oc1.test.anchor");
    writeFileSync(join(stub.launchLog, "..", "anchor-conf"), "1");
    const result = spawnSync("bash", [scriptPath, "rollback"], {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${stub.bin}:${process.env.PATH}`,
        OCI_COMPARTMENT: "test-compartment",
        FLIP_POLL_SLEEP: "0",
      },
    });
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).toBe(0);
    expect(out).toContain("UNASSIGNED");
    const unassign = readFileSync(
      join(stub.launchLog, "..", "unassign.log"),
      "utf8",
    );
    expect(unassign).toContain("--private-ip-id --");
    expect(unassign).toContain("--wait-for-state AVAILABLE");
    const ssh = readFileSync(stub.sshLog, "utf8");
    expect(ssh).toMatch(/rm -f \/etc\/kampodine\/anchor\.conf/);
    expect(ssh).toMatch(/ip addr del .?10\.0\.0\.14\/24.?/);
    // rollback never CREATES anything
    expect(existsSync(join(stub.launchLog, "..", "anchor.log"))).toBe(false);
  });

  test("ROLLBACK on a dormant reserved ip is a no-op (already unassigned, exit 0)", () => {
    const stub = stubBin(tmp, { customImage: null, customFirmware: "UEFI_64" });
    const result = spawnSync("bash", [scriptPath, "rollback"], {
      encoding: "utf8",
      env: { ...process.env, OCI_COMPARTMENT: "test-compartment", PATH: `${stub.bin}:${process.env.PATH}` },
    });
    const out = `${result.stdout}${result.stderr}`;
    expect(result.status, out).toBe(0);
    expect(out).toMatch(/dormant|UNASSIGNED/i);
    expect(existsSync(join(stub.launchLog, "..", "unassign.log"))).toBe(false);
  });
});
