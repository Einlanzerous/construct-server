#!/usr/bin/env bash
# plimsoll-llm-seed.sh — copy one model into plimsoll-llm's own volume, by digest,
# with no network (PLIM-14, ruling 2).
#
# plimsoll-llm has no route out, so it can never pull. The shared `ollama` service,
# which has egress, pulls; this copies that model's manifest and blobs into the
# dedicated `plimsoll_llm_models` volume and proves the copy is the model the
# deploy pins:
#
#   1. It runs in a throwaway container with `--network none`.
#   2. The shared models volume is mounted READ-ONLY, so a bug here cannot damage
#      what other callers use.
#   3. The manifest's own sha256 must equal PLIMSOLL_LLM_MODEL_DIGEST before anything
#      is copied, and the copied manifest is hashed again after.
#   4. Every blob the manifest names is copied to a temp name, hashed, and renamed
#      into place only if its sha256 matches its name. A blob already present is
#      re-hashed rather than trusted, so a half-written copy from an interrupted run
#      is replaced, not served.
#
# plimsoll-llm mounts the result read-only with OLLAMA_NOPRUNE=1, and Plimsoll's
# readiness check refuses any other digest, so this is the only way a model reaches
# the sandbox. The pin is trust-on-first-use: check it once by hand against the
# registry's published manifest digest when it changes.
#
# Costs about 20 GB of disk and a few minutes of I/O. Run it after the first deploy
# that creates the volume, and again whenever the digest pin changes. It does not
# touch either running Ollama; recreate plimsoll-llm afterwards
# (`make recreate svc=plimsoll-llm`) so it lists the new model.
#
# Usage:
#   scripts/plimsoll-llm-seed.sh                          # model and digest from the deploy root
#   PLIMSOLL_LLM_MODEL=gemma4:31b PLIMSOLL_LLM_MODEL_DIGEST=<sha256> scripts/plimsoll-llm-seed.sh
#
# Exit codes:
#   0  seeded and verified
#   1  a digest did not match, or a file is missing
#   2  usage / missing dependency / volume not found

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/docker-compose.yml}"
# alpine 3.23, by digest: busybox sha256sum, cp and grep are all this needs.
PROBE_IMAGE="${PROBE_IMAGE:-alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40}"

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found in PATH" >&2; exit 2; }

# The model and digest are read from the compose file when not given, so the seed
# and the readiness check cannot disagree about what is pinned.
from_compose() {
	sed -n "s/^[[:space:]]*- $1=\(.*\)$/\1/p" "$COMPOSE_FILE" | head -n1
}
MODEL="${PLIMSOLL_LLM_MODEL:-$(from_compose PLIMSOLL_LLM_MODEL)}"
DIGEST="${PLIMSOLL_LLM_MODEL_DIGEST:-$(from_compose PLIMSOLL_LLM_MODEL_DIGEST)}"
DIGEST="${DIGEST#sha256:}"

[[ -n "$MODEL" ]] || { echo "ERROR: PLIMSOLL_LLM_MODEL is empty" >&2; exit 2; }
[[ "$DIGEST" =~ ^[0-9a-f]{64}$ ]] || { echo "ERROR: PLIMSOLL_LLM_MODEL_DIGEST is not a full sha256" >&2; exit 2; }
[[ "$MODEL" =~ ^[a-z0-9._-]+(:[a-zA-Z0-9._-]+)?$ ]] || { echo "ERROR: PLIMSOLL_LLM_MODEL $MODEL is not a library model name" >&2; exit 2; }

NAME="${MODEL%%:*}"
TAG="latest"
[[ "$MODEL" == *:* ]] && TAG="${MODEL#*:}"
MANIFEST="manifests/registry.ollama.ai/library/$NAME/$TAG"

# Compose prefixes volume names with the project, so find each by its compose label
# rather than guessing the prefix. Both must already exist: a `docker run -v` on a
# missing name would quietly create an unlabelled volume compose then refuses.
volume() {
	local found
	found="$(docker volume ls -q --filter "label=com.docker.compose.volume=$1")"
	if [[ -z "$found" || "$(wc -l <<<"$found")" -ne 1 ]]; then
		echo "ERROR: expected exactly one compose volume labelled $1, found: ${found:-none}" >&2
		echo "       Deploy first, so compose creates it." >&2
		exit 2
	fi
	printf '%s' "$found"
}
# SEED_SRC / SEED_DST override the volumes with any `-v` source, which is how
# scripts/test/test-plimsoll-llm-seed.sh runs this against small fake models.
SRC_VOL="${SEED_SRC:-$(volume ollama_data)}"
DST_VOL="${SEED_DST:-$(volume plimsoll_llm_models)}"

echo "Seeding $MODEL ($DIGEST) from $SRC_VOL into $DST_VOL, with no network."

# The shell below runs in the container. Values arrive as env, never interpolated
# into the script text.
docker run --rm --network none \
	-e MANIFEST="$MANIFEST" -e DIGEST="$DIGEST" \
	-v "$SRC_VOL:/src:ro" \
	-v "$DST_VOL:/dst" \
	"$PROBE_IMAGE" sh -eu -c '
		src=/src/models; dst=/dst
		sum() { sha256sum "$1" | cut -d" " -f1; }
		[ -f "$src/$MANIFEST" ] || { echo "FAIL: $MANIFEST is not in the shared volume; pull it on the shared instance first"; exit 1; }
		got=$(sum "$src/$MANIFEST")
		[ "$got" = "$DIGEST" ] || { echo "FAIL: the shared manifest digest is $got, not the pinned digest"; exit 1; }
		blobs=$(grep -o "\"digest\":\"sha256:[0-9a-f]\{64\}\"" "$src/$MANIFEST" | sed "s/.*sha256:\([0-9a-f]*\)\"/\1/" | sort -u)
		[ -n "$blobs" ] || { echo "FAIL: the manifest names no blobs"; exit 1; }
		mkdir -p "$dst/blobs" "$dst/$(dirname "$MANIFEST")"
		n=0
		for b in $blobs; do
			n=$((n + 1))
			name="sha256-$b"
			if [ -f "$dst/blobs/$name" ] && [ "$(sum "$dst/blobs/$name")" = "$b" ]; then
				echo "ok    $name (already present, re-verified)"
				continue
			fi
			[ -f "$src/blobs/$name" ] || { echo "FAIL: blob $name is missing from the shared volume"; exit 1; }
			cp "$src/blobs/$name" "$dst/blobs/$name.partial"
			got=$(sum "$dst/blobs/$name.partial")
			if [ "$got" != "$b" ]; then
				rm -f "$dst/blobs/$name.partial"
				echo "FAIL: copied blob $name hashes to $got"; exit 1
			fi
			mv "$dst/blobs/$name.partial" "$dst/blobs/$name"
			echo "copy  $name (verified)"
		done
		cp "$src/$MANIFEST" "$dst/$MANIFEST.partial"
		got=$(sum "$dst/$MANIFEST.partial")
		[ "$got" = "$DIGEST" ] || { rm -f "$dst/$MANIFEST.partial"; echo "FAIL: the copied manifest hashes to $got"; exit 1; }
		mv "$dst/$MANIFEST.partial" "$dst/$MANIFEST"
		echo "OK: manifest and $n blob(s) verified against the pinned digest."
	'
