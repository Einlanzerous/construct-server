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
| A (canary) | satlink | this change |
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
| `/etc/systemd/system/docker.service.d/50-log-rate.conf` | `LogRateLimitIntervalSec` / `LogRateLimitBurst` | `30s` / `50000` |

The rate limit is one bucket: with this driver the sender of every container line is dockerd, so
all journald-logged containers share `docker.service`'s allowance (the host default is 10000
messages per 30 s in total). The drop-in raises it for that unit only. Dropped lines show up as a
`Suppressed N messages from docker.service` notice; `make journald-check` counts them.

`ForwardToSyslog` is **not** set here. Ubuntu forwards journal lines to rsyslog, so container
lines will also land in `/var/log/syslog`. Whether to add `ForwardToSyslog=no` is an open
question (PR description); decide it after measuring syslog growth during the canary.

The files live in `ansible/roles/server/files/journald/` and contain no secrets.

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
   sudo install -d /etc/systemd/journald.conf.d /etc/systemd/system/docker.service.d
   sudo install -m 0644 ansible/roles/server/files/journald/50-construct-containers.conf /etc/systemd/journald.conf.d/
   sudo install -m 0644 ansible/roles/server/files/journald/50-log-rate.conf /etc/systemd/system/docker.service.d/
   sudo systemctl daemon-reload            # re-reads units; does NOT restart dockerd
   sudo systemctl restart systemd-journald # does not touch Docker or containers
   journalctl --disk-usage                  # unchanged: nothing vacuumed
   systemctl show docker.service -p LogRateLimitBurst   # expect 50000: only proves PID 1 loaded it
   cat /run/systemd/units/log-rate-limit-burst:docker.service   # what journald reads; expect 50000
   ```
   The script's `dropin` phase asserts exactly this (the installed files byte-identical to the repo,
   disk usage not reduced, the oldest journal entry date unchanged, both burst values 50000). A
   missing or wrong burst value is recorded as a **wave-C blocker, not a canary blocker**: it is
   written when PID 1 starts docker.service, and nothing here restarts dockerd, so it can stay
   missing until the next docker restart.

   If the `/run/systemd/units/` file is missing or wrong, journald is not enforcing the raised
   limit: decide the fallback (the global `RateLimitBurst` in the journald drop-in) BEFORE wave C
   (switchyard). Satlink alone will not approach 10000 lines per 30 s, so the `Suppressed` count
   cannot prove the limit during the canary; it is the check for wave C and later.
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
