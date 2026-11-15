# backup-receiver

`backup-receiver/` — a **self-contained** bundle that turns any Linux host with
Docker into a backup destination (SERV-167): a tailscale sidecar plus
`restic/rest-server`, with rest-server in the sidecar's network namespace so it
publishes no ports — not reachable on the host's LAN or its localhost. It is
copied to other people's machines — the desktop's WSL2 side, later Arin's box —
so it must never grow a dependency on anything else in this repo. `install.sh`
**proves** the two properties that matter rather than trusting the compose
file: that the repo demands credentials, and that append-only is in force.
Note why the obvious append-only probe is wrong — `DELETE /<repo>/` answers
405 with the flag on *or* off, so a check written that way certifies a
repository anything could erase; `DELETE /<repo>/config` is 403 vs 200 and
is the one that discriminates.
