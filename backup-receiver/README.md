# Backup receiver

Turns any Linux host with Docker into a backup destination for the construct
server (SERV-43 / SERV-167). Used by the desktop's WSL2 side today; the same
bundle is what Arin's server and any future NAS will run.

**This directory is self-contained on purpose.** Copy it to the destination and
run it — it depends on nothing else in `construct-server`, so handing a receiver
to somebody does not mean handing them access to the estate's infrastructure
repo.

```
scp -r backup-receiver/ user@destination:~/
ssh user@destination
cd backup-receiver && cp .env.example .env && $EDITOR .env && ./install.sh
```

## What it stands up

Two containers sharing one network namespace:

| | |
|---|---|
| `tailscale` | Joins this host to the tailnet as its own node. |
| `rest-server` | restic's HTTP receiver, running **inside** tailscale's namespace. |

`network_mode: service:tailscale` is the design, not an implementation detail.
rest-server publishes no ports, so it is **not reachable on the host's LAN and
not on the host's localhost** — the tailnet address is the only one a person or
a script would think to use. (It also answers on the compose project's bridge
network — that's how this script's own `verify` reaches it without this host
being on the tailnet — but every request there still needs `REST_USER`/
`REST_PASSWORD`, so it is not a way around the credential.)

On the desktop that solves a second problem at the same time. WSL2 sits behind a
NAT'd virtual NIC, so anything bound on the WSL2 side is invisible from the
network — which is why the box could reach `imperial-prime` in 5 ms and still
find nothing but SMB listening. Joining the tailnet from *inside* the namespace
sidesteps that, instead of fighting it with `netsh portproxy` rules that break
every time WSL2's IP is reassigned.

## Before you start

- **Docker**, with `docker compose` v2.
- **`/dev/net/tun`.** `install.sh` checks for it. On WSL2, `wsl --update` from
  Windows PowerShell is the fix if it is missing.
- **A Tailscale auth key** — https://login.tailscale.com/admin/settings/keys.
  Use a **reusable** key, not an ephemeral one: an ephemeral node is dropped
  from the tailnet when it goes offline, and this node is meant to be durable.
  It is needed only for the first run; after that the identity lives in a volume.

### On the desktop specifically (WSL2 + Docker Desktop)

1. **Docker Desktop → Settings → Resources → WSL Integration** — enable it for
   the distro you are installing into, or `docker` will not be on your PATH.
2. **Docker Desktop → Settings → General → "Start Docker Desktop when you sign
   in."** Turn this **on**. The containers carry `restart: unless-stopped`,
   which only means anything once Docker itself is running — without it the
   receiver silently stays down after a reboot, and backups stop with nothing
   announcing it. This is the most likely way this install quietly stops working.
3. Note the distinction if you are *not* using Docker Desktop: a Docker installed
   inside the distro needs the distro itself running, which WSL does not do at
   boot on its own. That needs `systemd=true` in `/etc/wsl.conf` plus a Windows
   scheduled task to launch it.

## Install

```bash
cp .env.example .env
$EDITOR .env          # TS_HOSTNAME, TS_AUTHKEY, REST_USER, REST_PASSWORD
./install.sh
```

`install.sh` preflights, writes the credential, brings the pair up, waits for a
tailnet address, and then **verifies**. Re-run the checks any time:

```bash
./install.sh verify    # re-check the properties below
./install.sh status    # what is running, and the tailnet address
```

## What verification actually proves

A receiver that is merely *running* proves nothing. Four assertions, all made
against the live server rather than read off the compose file:

| Check | Asserts |
|---|---|
| unauthenticated request → 401 | the repository is not open to the tailnet |
| wrong password → 401 | credentials are really being checked |
| authenticated create → 200 | the credential in `.env` actually works |
| `DELETE /<repo>/config` → 403 | **append-only is genuinely in force** |

Both failure modes have been demonstrated, not assumed — with authentication
disabled the second row reports `THE REPOSITORY IS OPEN`, and with
`--append-only` removed the fourth reports that a delete was accepted, each
exiting non-zero.

> **Do not "simplify" the append-only probe to `DELETE /<repo>/`.** Deleting a
> whole repository is not a supported operation, so it answers **405 whether or
> not append-only is on**. A check written that way passes identically against a
> server that has lost the flag, and would certify a repository that anything
> holding the password could erase. Measured, with a control:
>
> | probe | flag on | flag off |
> |---|---|---|
> | `DELETE /<repo>/` | 405 | 405 ← proves nothing |
> | `DELETE /<repo>/config` | 403 | 200 ← discriminates |

## Then, on the construct server

```bash
tailscale ping <TS_HOSTNAME>

restic -r rest:http://<user>:<password>@<TS_HOSTNAME>:8000/construct/ \
  init --copy-chunker-params --from-repo <local hub repo>
```

**`--copy-chunker-params` is not optional.** Without it `restic copy` re-chunks
everything and cross-repo deduplication collapses — and it cannot be corrected
later without recreating the repository from scratch.

## Operating notes

**Append-only means you cannot prune from the box.** That is the entire point —
a compromise on the construct server cannot destroy its history — but it has a
running cost: this repository grows and nothing here reclaims space. Reclaiming
it is a deliberate maintenance pass *on this host*, with the flag off:

```bash
# stop, drop --append-only from OPTIONS in docker-compose.yml, up -d
restic -r <repo> forget --prune --keep-daily 14 --keep-weekly 8
# put --append-only BACK, up -d, then: ./install.sh verify
```

The last step is not optional. `verify` is what tells you the flag went back on.

**The two containers are coupled.** rest-server lives in tailscale's namespace,
so if tailscale is recreated, rest-server must be restarted too — and if
tailscale crash-loops, rest-server cannot start at all (`cannot join network
namespace of container ... is restarting`). If rest-server will not come up,
read `docker logs backup-tailscale` first; the cause is usually there.

**The repository volume is `external: true` deliberately.** Compose will not
manage it, which means `docker compose down -v` cannot delete your backups.
`install.sh` creates it if it is missing.

**Rotating the receiver password:** change `REST_PASSWORD` in `.env`, re-run
`./install.sh`, then update the repository URL on the construct server. The
credential is read at **startup**, not per request, so a change does not take
effect until the container restarts — `install.sh` handles that.

**This password is not the restic repository password.** It authenticates the
construct server *to* this host. The repository's own encryption key never
leaves the construct server, which is what keeps the contents unreadable to
whoever runs this machine.

## Adding another destination

Copy this directory to the new host, give it a different `TS_HOSTNAME`, and run
`./install.sh`. Then on the construct server, `restic init --copy-chunker-params`
a repository on it and add it as another `restic copy` target. Nothing about the
transport changes — which is the property that makes "desktop, then Arin, then a
NAS" a list rather than three designs.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `docker is not on PATH` | Docker Desktop WSL integration is off for this distro. |
| `/dev/net/tun is missing` | `sudo modprobe tun`, or `wsl --update` from Windows. |
| tailscale never gets an address | Key missing, expired, or already used. Put a fresh one in `.env` and re-run. |
| `cannot join network namespace` | tailscale is crash-looping — check its logs, not rest-server's. |
| verify: repository is open | `DISABLE_AUTHENTICATION` is set, or the htpasswd file is empty. |
| verify: append-only not in force | `--append-only` is missing from `OPTIONS` — likely left off after a prune. |
| Everything fine, but backups stopped after a reboot | Docker Desktop is not set to start at sign-in. |
