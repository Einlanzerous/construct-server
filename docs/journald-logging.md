# Container logs in journald (SATL-25)

Why: the daemon's default `json-file` driver keeps a container's stdout inside the container's
own directory and deletes it with the container. A recreate (every deploy that changes a
service's spec) therefore erased exactly the lines an incident reader wanted, for example
satlink's boot-race lines. With the `journald` driver the lines go to the host journal, keyed
by container NAME, so they outlive the container.

The shared compose anchor is `x-journald-logging` (top of `docker-compose.yml`); a service adopts
it with `logging: *journald-logging`. It sets `tag: "{{.Name}}"` (the container name, not the
12-character ID) and `labels: com.docker.compose.service`.

## Who is on journald

Staged waves, one PR each (ruling 1). Each merge runs the whole-stack deploy path and recreates
every adopter in it, so the wave size is the number of simultaneous restarts.

| Wave | Services | State |
|---|---|---|
| A (canary) | satlink | merged, canary passed |
| B | purser, cf-access-guard | later PR |
| C | switchyard (24 h rate-limit check) | later PR |
| D | traefik (short edge outage) | later PR |
| E | postgres | **DEFERRED** (ruling 3), see the cascade note |

**Never** plimsoll or plimsoll-llm: `scripts/check-plimsoll-llm-canary.sh` requires them to log
through `json-file` (PLIM-14). Do not generalise the anchor to them. Also untouched: genzo,
trestle-genzo, sextant (their own capped json-file), crowdsec, datadog, dozzle, watchtower.

## Caps

| Where | Setting | Value |
|---|---|---|
| `/etc/systemd/journald.conf.d/50-construct-containers.conf` | `SystemMaxUse` | `6G` (Ubuntu default is 4G; about 2.7G used at planning) |
| same file | `MaxRetentionSec` | **not set** (ruling 2): a 14-day retention would delete about 66 days of existing host journal on the next vacuum |
| same file | `RateLimitIntervalSec` / `RateLimitBurst` | `30s` / `50000` (**host-wide**, see below) |

### The rate limit is host-wide, and why

The rate limit is one bucket: with this driver the sender of every container line is dockerd, so
all journald-logged containers share `docker.service`'s allowance (the default is 10000 messages
per 30 s in total). Dropped lines show up as a `Suppressed N messages from docker.service` notice;
`make journald-check` counts them.

The first canary shipped a `docker.service`-scoped drop-in (`LogRateLimitBurst=50000`). It read
50000 in PID 1 but did nothing: journald reads per-unit limits from
`/run/systemd/units/log-rate-limit-burst:docker.service`, which PID 1 writes only when
`docker.service` starts, and dockerd is deliberately never restarted (live-restore is off, so it
would restart every container). The plan's fallback is therefore in force: the limit lives in the
GLOBAL journald drop-in, which journald reads itself and needs only a journald restart.

`RateLimitIntervalSec=30s` and `RateLimitBurst=50000` (journald.conf(5), systemd 255) apply to
**every service's** journal bucket on this host, not just Docker's. That is acceptable: the limit
is per sender, so it only matters to a sender that would exceed it, 50000 per 30 s (about 1666 per
second) is a ceiling no service here approaches, and a higher ceiling means fewer silently dropped
lines for everyone, at the cost of a runaway service being able to write more before it is cut
off (the `SystemMaxUse=6G` cap still bounds the disk). journald also multiplies the burst by a
factor derived from free journal disk space (a log2 scale, journald.conf(5)), so the real ceiling
is somewhat higher. A per-unit `LogRateLimitBurst=` in a unit file overrides the global value
(systemd.exec(5)), which is why the stale docker.service drop-in could only ever repeat it.

Decision on the docker.service drop-in: **removed** from the repo. It is inert until dockerd
restarts, and keeping it would leave two sources of truth for one number (and a per-unit value
silently overriding the global one if someone later changes only the global). The ansible role
removes the stale file from the host (`state: absent` plus a `daemon-reload`, which does not
restart dockerd) and the rollout script's `dropin` phase does the same.

journald has **no runtime readback** of its rate limit (the `/run/systemd/units/` files are only
the per-unit overrides, and `systemctl show` reports PID 1's view, not journald's). So the
`dropin` phase asserts the strongest thing that exists: `systemd-analyze cat-config
systemd/journald.conf` shows `RateLimitBurst=50000` and `RateLimitIntervalSec=30s` as the
effective values, and `systemd-journald` (re)started at or after the installed file's mtime
(`systemctl show --timestamp=unix systemd-journald -p ActiveEnterTimestamp`). The behavioural
proof is still the `Suppressed` count, which wave C (switchyard) checks over 24 h.

The file lives in `ansible/roles/server/files/journald/` and contains no secrets.

### Open questions, decided: ForwardToSyslog stays as is

`ForwardToSyslog=no` is **not** set, by the owner's ruling. It is global: rsyslog on this host is
fed by journald forwarding, so `no` would stop `/var/log/syslog`, `auth.log` and `kern.log`
updating at all, and nothing in the estate reads them except humans. Container lines therefore
also land in `/var/log/syslog` (it already carries the satlink lines). Revisit only if
`/var/log/syslog` growth hurts, and then with an rsyslog drop rule for container lines only, not
by turning forwarding off.

## Owner-only steps, in this ORDER

sudo needs a password, so none of this is run by an agent. Do not run the whole `site.yml`: its
"Start Docker Stack" task would apply the compose change.

**Use the rollout script first.** `scripts/journald-logging-rollout.sh` is these steps as phases
(modelled on `traefik-access-log-rollout.sh`): each phase runs alone, a dry run is the default and
`--apply` really does it, every run writes a PASS / FAIL / PAUSE record under
`~/.cache/journald-logging-rollout/` (counts only, never a log line) and `--print-evidence` prints
the counts-only comment for SATL-25 / SATL-71. The manual commands below are the equivalent.
`dropin` calls `sudo -v` up front (you type the password) and uses sudo only for the install,
`daemon-reload` and the journald restart. It never restarts dockerd or a container.

```sh
scripts/journald-logging-rollout.sh preflight                 # read-only, no sudo: baselines + drift
scripts/journald-logging-rollout.sh dropin --apply            # step 1 below
scripts/journald-logging-rollout.sh merge-gate --apply        # step 2: pauses while YOU merge, then checks the deploy
scripts/journald-logging-rollout.sh canary --apply            # step 3: the canary block, with force-recreate
scripts/journald-logging-rollout.sh verify                    # read-only; Dozzle stays a PAUSE until you confirm
scripts/journald-logging-rollout.sh --print-evidence          # step 4: paste the counts on SATL-25
# or all in order (pauses before each phase): scripts/journald-logging-rollout.sh all --apply
```

Run a phase without `--apply` to read its plan first. `make journald-logging-rollout-test` proves
the script against fake binaries.

1. **Host drop-ins first, BEFORE the compose change is merged.** The cap and rate limit must exist
   when volume starts. No container is touched.
   ```sh
   journalctl --disk-usage                                  # record the baseline (about 2.7G)
   # either: ansible, from the repo checkout
   ansible-playbook ansible/site.yml --tags journald --limit server --ask-become-pass
   # or by hand, the equivalent:
   sudo install -d /etc/systemd/journald.conf.d
   sudo install -m 0644 ansible/roles/server/files/journald/50-construct-containers.conf /etc/systemd/journald.conf.d/
   # only if the first canary left the legacy docker.service drop-in (the script removes it too):
   sudo rm -f /etc/systemd/system/docker.service.d/50-log-rate.conf && sudo systemctl daemon-reload  # does NOT restart dockerd
   sudo systemctl restart systemd-journald # does not touch Docker or containers; this is what applies the rate limit
   journalctl --disk-usage                  # unchanged: nothing vacuumed
   systemd-analyze cat-config systemd/journald.conf | grep -E '^(RateLimit|SystemMaxUse)'   # expect 50000, 30s, 6G
   systemctl show --timestamp=unix systemd-journald -p ActiveEnterTimestamp --value         # at or after the file's mtime
   stat -c %Y /etc/systemd/journald.conf.d/50-construct-containers.conf
   ```
   The script's `dropin` phase asserts exactly this (the installed file byte-identical to the repo,
   disk usage not reduced, the oldest journal entry date unchanged, the effective global limit, and
   journald restarted after the file). It is idempotent: re-running `dropin --apply` after this
   change is how the host picks up the global limit. See "The rate limit is host-wide" above for why
   this is the check (journald has no runtime readback of its limits).
2. **Check the deploy scope, then merge** the wave PR. Merging a `docker-compose.yml` change takes
   deploy.yml's whole-stack path (SERV-109 narrows only pure `versions.env` changes): it pulls
   every pin and runs an unscoped `up -d`, so first-party pins that published since the last
   deploy move too, and satlink is recreated by it.
   ```sh
   make deploy-scope base=origin/main head=<the branch>
   ```
3. **Canary test** (next section), once the deploy is green. The deploy itself already recreates
   satlink onto journald (its json-file lines are gone, as for any recreate), so the test block
   takes BEFORE from that journald container and then does one more explicit `make force-recreate`
   to prove the lines survive it.
4. **Record counts** on SATL-25 and the PR: driver, the line counts, disk usage before and after,
   the `Suppressed` count, Dozzle yes/no. Counts only; never paste a log line.

## Canary test (satlink)

`scripts/journald-logging-rollout.sh canary --apply` runs this block and asserts every line of
it; the commands are the equivalent by hand. Use `force-recreate`, not `recreate`: `make recreate`
is `up -d --no-deps` and does nothing on an unchanged compose spec (it exited 0 and left the old
container running in the traefik window), so the script also fails unless the container id and
`StartedAt` really changed.

```sh
docker inspect --format '{{.HostConfig.LogConfig.Type}}' satlink          # journald
BEFORE=$(journalctl CONTAINER_NAME=satlink --no-pager -q | wc -l)
OLD_ID=$(docker inspect --format '{{.Id}}' satlink | cut -c1-12)
make force-recreate svc=satlink
AFTER=$(journalctl CONTAINER_NAME=satlink --no-pager -q | wc -l)
OLDN=$(journalctl CONTAINER_ID=$OLD_ID --no-pager -q | wc -l)
echo before=$BEFORE after=$AFTER old_container_lines=$OLDN   # AFTER >= BEFORE, OLDN > 0
docker logs satlink 2>&1 | wc -l                              # new container only, much smaller
docker logs --tail 5 satlink >/dev/null && echo docker-logs-ok
make journald-check                                           # drivers, counts, disk usage
./scripts/check-plimsoll-llm-canary.sh <the canary of a live eval>   # still json-file in both
```

Then open Dozzle on the satlink container: live tail, scroll-back and timestamps render.
The `docker logs` reader is keyed by container ID, so after a recreate it shows only the new
container; the earlier lines are reached through `journalctl CONTAINER_NAME=satlink`.

## Query recipes

The owner is in `adm`, which can read the journal; no `sudo` and no group change needed.

```sh
journalctl CONTAINER_NAME=satlink --since -1h          # by container name; survives a recreate
journalctl -t satlink -f                               # by tag (same value), live
journalctl COM_DOCKER_COMPOSE_SERVICE=satlink          # by compose service
journalctl CONTAINER_ID=<12-char id>                   # one specific past container
journalctl CONTAINER_NAME=satlink -o json-pretty -n 1  # see the fields
journalctl CONTAINER_NAME=satlink --since "2026-11-14 10:00" --until "2026-11-14 10:10"
journalctl CONTAINER_NAME=satlink -p err               # priority err and worse (stderr is err)
journalctl --disk-usage
make journald-check                                    # counts only, no lines
```

Container logs can hold health data and Switchyard is shown to others: never paste lines into
tickets, PRs or chat; record counts.

## Rollback

`scripts/journald-logging-rollout.sh rollback --apply` walks these steps, each confirmed
(`--revert-pr N` checks your revert merged; `--remove-dropins` is the only way it touches the host
drop-ins). The manual path, per service, no data cost:

1. Replace `logging: *journald-logging` with the previous block (or revert the PR) and merge.
2. `make force-recreate svc=<name>`: the container returns to `json-file`, and `docker logs` works from
   that point.
3. Lines already in the journal are untouched and stay queryable with
   `journalctl CONTAINER_NAME=<name>` until the size cap ages them out.

The journald side: remove the two drop-in files, `sudo systemctl daemon-reload && sudo systemctl
restart systemd-journald`. Neither touches a container. (satlink's old `10m x 3` json-file cap is
what a revert restores.)

## Postgres cascade note (wave E, deferred)

postgres is not in these waves (ruling 3). If it is adopted later: recreating it makes switchyard
and interlock-worker (Node pools that do not re-resolve the address) need `make force-recreate
svc=switchyard` and `svc=interlock-worker` right afterwards, and the deploy's post-deploy health
gate stays red until then. Treat it as planned maintenance (about 1 s of database outage) with
those commands ready.

## What is unaffected

- Traefik's access log is a file on the `traefik_access_logs` volume (`accessLog.filePath`), read
  by crowdsec and satlink's rollup; the driver change moves only error/startup stdout.
- Satlink's Docker-state exporter reads `docker inspect` fields, not logs; it may read
  `unavailable` for up to its 90 s staleness window around a recreate.
- `check-compose-drift.sh` compares mounts only and will not see a driver change; verify with
  `docker inspect` or `make journald-check`.
