# vox-loop

Self-hosted [Dendrite](https://github.com/matrix-org/dendrite) Matrix homeserver. The application code lives in its [own repo](https://github.com/Einlanzerous/vox-loop) — this directory is a reference for how it connects to the construct-server stack.

## Architecture

Traffic flows through Caddy as a reverse proxy on port `${VOX_LOOP_PORT}` (default 4000):

```
Client -> Caddy (:4000)
             ├── /.well-known/matrix/*   -> static JSON responses
             ├── /_matrix/client/unstable/org.matrix.msc3575/sync -> sliding-sync (:8008)
             └── /_matrix/*              -> vox-loop (Dendrite :8008)
```

## Services

| Service | Image | Purpose |
|---------|-------|---------|
| vox-loop | `ghcr.io/einlanzerous/vox-loop` | Dendrite Matrix homeserver |
| sliding-sync | `ghcr.io/matrix-org/sliding-sync` | Sliding sync proxy for Element X |
| caddy | `caddy:2-alpine` | Reverse proxy and `.well-known` serving |

## Databases

| Database | User | Used by |
|----------|------|---------|
| `vox_loop` | `vox_loop_user` | Dendrite |
| `syncv3` | `syncv3_user` | Sliding sync proxy |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `VOX_LOOP_PORT` | Host port for Caddy entry point (default: 4000) |
| `VOX_LOOP_DB_PASSWORD` | Password for `vox_loop_user` |
| `SYNCV3_DB_PASSWORD` | Password for `syncv3_user` |
| `SYNCV3_SECRET` | Shared secret for the sliding sync proxy |

## Connecting

Point your Matrix client at `http://imperial-construct:4000`. Traffic over Tailscale is already encrypted at the network layer.
