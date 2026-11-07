#!/usr/bin/env bash
# test-plimsoll-llm-seed.sh — prove the seed refuses what it should (PLIM-14, criterion 4).
#
# Runs the real scripts/plimsoll-llm-seed.sh against small FAKE models in temp
# directories (no real weights, no estate volume): a good seed must verify, and a
# wrong manifest digest, a corrupted blob and a missing blob must each fail before
# anything unverified lands in the destination. Needs docker and the pinned alpine.
#
# Usage: scripts/test/test-plimsoll-llm-seed.sh   (or `make plimsoll-llm-seed-test`)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SEED="$SCRIPT_DIR/../plimsoll-llm-seed.sh"
WORK="$(mktemp -d)"
cleanup() {
	# Files written by the container are root-owned; remove them from a container too.
	docker run --rm -v "$WORK:/w" alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40 \
		sh -c 'rm -rf /w/*' >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

fails=0
make_src() { # $1 = dir; prints the manifest digest
	local d="$1" b1 b2
	mkdir -p "$d/models/blobs" "$d/models/manifests/registry.ollama.ai/library/fake"
	printf 'SYNTHETIC weights one\n' >"$d/b1"
	printf 'SYNTHETIC config\n' >"$d/b2"
	b1="$(sha256sum "$d/b1" | cut -d' ' -f1)"
	b2="$(sha256sum "$d/b2" | cut -d' ' -f1)"
	mv "$d/b1" "$d/models/blobs/sha256-$b1"
	mv "$d/b2" "$d/models/blobs/sha256-$b2"
	printf '{"schemaVersion":2,"config":{"digest":"sha256:%s"},"layers":[{"digest":"sha256:%s"}]}' "$b2" "$b1" \
		>"$d/models/manifests/registry.ollama.ai/library/fake/1b"
	sha256sum "$d/models/manifests/registry.ollama.ai/library/fake/1b" | cut -d' ' -f1
}

run_seed() { # $1 = case dir, $2 = digest; returns the seed's exit code
	SEED_SRC="$1/src" SEED_DST="$1/dst" PLIMSOLL_LLM_MODEL=fake:1b PLIMSOLL_LLM_MODEL_DIGEST="$2" \
		"$SEED" >"$1/out" 2>&1
}

expect() { # $1 = name, $2 = want exit, $3 = got exit
	if [[ "$2" == "$3" ]]; then echo "ok    $1"; else echo "FAIL: $1 exited $3, want $2"; sed 's/^/      /' "$4"; fails=1; fi
}

# good
c="$WORK/good"; mkdir -p "$c/dst"; d="$(make_src "$c/src")"
rc=0; run_seed "$c" "$d" || rc=$?
expect "a good seed verifies" 0 "$rc" "$c/out"
[[ -f "$c/dst/manifests/registry.ollama.ai/library/fake/1b" ]] || { echo "FAIL: good seed wrote no manifest"; fails=1; }
rc=0; run_seed "$c" "$d" || rc=$?
expect "a second run re-verifies and succeeds" 0 "$rc" "$c/out"

# wrong digest
c="$WORK/digest"; mkdir -p "$c/dst"; make_src "$c/src" >/dev/null
rc=0; run_seed "$c" "$(printf '0%.0s' {1..64})" || rc=$?
expect "a manifest that is not the pinned digest is refused" 1 "$rc" "$c/out"
[[ -z "$(ls -A "$c/dst")" ]] || { echo "FAIL: a refused seed wrote to the destination"; fails=1; }

# corrupted blob
c="$WORK/corrupt"; mkdir -p "$c/dst"; d="$(make_src "$c/src")"
for f in "$c"/src/models/blobs/*; do printf 'tampered' >>"$f"; break; done
rc=0; run_seed "$c" "$d" || rc=$?
expect "a blob whose bytes do not match its name is refused" 1 "$rc" "$c/out"
[[ ! -e "$c/dst/manifests/registry.ollama.ai/library/fake/1b" ]] || { echo "FAIL: a manifest landed beside a bad blob"; fails=1; }

# missing blob
c="$WORK/missing"; mkdir -p "$c/dst"; d="$(make_src "$c/src")"
for f in "$c"/src/models/blobs/*; do rm -f "$f"; break; done
rc=0; run_seed "$c" "$d" || rc=$?
expect "a missing blob is refused" 1 "$rc" "$c/out"

# not a digest
c="$WORK/usage"; mkdir -p "$c/dst"; make_src "$c/src" >/dev/null
rc=0; run_seed "$c" "not-a-digest" || rc=$?
expect "a malformed digest is a usage error" 2 "$rc" "$c/out"

[[ $fails -eq 0 ]] && echo "OK: the seed refuses every bad input." || exit 1
