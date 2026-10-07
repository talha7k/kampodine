#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pkgDir = dirname(fileURLToPath(import.meta.url));
const { version } = JSON.parse(readFileSync(join(pkgDir, "package.json"), "utf8"));

const commands = {
  deploy: "deploy.sh",
  status: "status.sh",
  bluegreen: "bluegreen.sh",
  "vm-prepare": "vm-prepare.sh",
  "image-import": "image-import.sh",
  migrate: "migrate.sh",
};

const usage = `kampodine — kamal-alternative CLI for Alpine + Podman deploys, built on kamal-proxy

Usage: kampodine <command> [args...]

Commands:
  deploy         stream deploy (podman save | ssh podman load) with sha-verified health gate; --rollback [sha] = instant image-tag rollback
  bluegreen      reserved-IP blue/green pair: status (pair + reserved IP + health) | init | provision | flip | rollback
  vm-prepare     first-run bootstrap of a bare Alpine host (OpenRC + podman stack)
  image-import   golden qcow2 -> OCI custom image
  migrate        tenant db migrations over SSH

All further args pass through to the underlying script.
`;

const [cmd, ...args] = process.argv.slice(2);

if (!cmd || cmd === "--help" || cmd === "-h") {
  process.stdout.write(usage);
  process.exit(0);
}
if (cmd === "--version") {
  process.stdout.write(`${version}\n`);
  process.exit(0);
}

const script = commands[cmd];
if (!script) {
  process.stderr.write(`kampodine: unknown command: ${cmd}\n\n${usage}`);
  process.exit(2);
}

const result = spawnSync("bash", [join(pkgDir, "scripts", script), ...args], {
  stdio: "inherit",
  env: process.env,
});
if (result.error) {
  process.stderr.write(`kampodine: ${result.error.message}\n`);
  process.exit(1);
}
process.exit(result.status ?? 1);
