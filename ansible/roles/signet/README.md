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

## What it does *not* do
This role does not build/install the `signet` binary or initialize the vault
(master key + SQLite DB). Those are the one-time bring-up steps (SGNT-1); the
binary is expected at `~magos/.local/bin/signet` with the vault under
`~magos/.config/signet` + `~magos/.local/share/signet`.

## Required variable
`signet_api_token` — the bearer the daemon requires and the Switchyard
connector presents. Define it in the SOPS secrets (`ansible/secrets.sops.yml`),
**not** in `defaults/`. The identical value must also be set as
`SIGNET_API_TOKEN` in the stack `.env` (see `.env.example`) so the switchyard
container authenticates against the daemon.

## Run
```bash
ansible-playbook -i inventory.ini site.yml --tags signet --ask-become-pass
```
