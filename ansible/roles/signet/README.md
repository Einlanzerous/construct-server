# Role: `signet`

Wires the **Signet** host daemon — the construct-server credential vault +
outbound-sync REST API (repo: [signet](https://github.com/Einlanzerous/signet),
project `SGNT`) — as a systemd system unit. Consumed by Switchyard's Signet
connector (SWY-165) over `host.docker.internal:4010`.

## What it does
- Deploys `/etc/systemd/system/signet.service` running `signet serve` as
  `magos`, bound to `127.0.0.1:4010`.
- Deploys `/etc/signet/signet.env` (`0600`) holding `SIGNET_API_TOKEN`.
- Enables + starts the unit **only** when the binary is installed and a token
  is set; otherwise the unit is installed but left stopped (safe on a fresh
  host that hasn't completed Signet bring-up).

- Installs a scoped `NOPASSWD` sudoers rule (`/etc/sudoers.d/signet-restart`)
  letting `magos` restart *this unit only*, which is what lets the unprivileged
  auto-deploy bounce the daemon.
- Installs a released binary when `signet_version` is set (see below).

## What it does *not* do
This role does not initialize the vault (master key + SQLite DB) — that is a
one-time bring-up step (SGNT-1), with the vault under `~magos/.config/signet` +
`~magos/.local/share/signet`.

Nor does it manage the binary unless you ask it to: with `signet_version` unset
(the default) the binary at `~magos/.local/bin/signet` is left exactly as found.

## Binary updates (SERV-62)
Set `signet_version` to a release tag to install that build:

```bash
ansible-playbook ansible/ops/update-signet.yml -e signet_version=v1.2.0
```

The asset and its `.sha256` are downloaded with `gh`, the checksum is verified
*before* anything moves into place, and the install is a rename rather than a
write — the old binary is mapped by the running daemon, so truncating it in
place would corrupt a live process. Already on the target version? Nothing
happens.

Use `ansible/ops/update-signet.yml`, **not** `site.yml --tags signet`: the
`server` play loads `secrets.sops.yml` and hard-fails without the age key, which
is deliberately absent from the server. The ops playbook needs no secrets and
runs unprivileged, restarting through the scoped sudo rule.

This is what `.github/workflows/deploy-signet.yml` runs, gated behind a required
reviewer in the `signet-prod` GitHub Environment.

## Required variable
`signet_api_token` — the bearer the daemon requires and the Switchyard
connector presents. Define it in the SOPS secrets (`ansible/secrets.sops.yml`),
**not** in `defaults/`. The identical value must also be set as
`SIGNET_API_TOKEN` in the stack `.env` (see `.env.example`) so the switchyard
container authenticates against the daemon.

When `signet_api_token` is empty the env file is **left untouched** rather than
rewritten blank. Without that guard, any run on a host lacking the sops key —
which is every automated deploy — would overwrite a working token with an empty
one and take the daemon down. Binary updates never touch secrets.

## Run
```bash
ansible-playbook -i inventory.ini site.yml --tags signet --ask-become-pass
```
