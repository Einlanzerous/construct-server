# Estate results

Where the estate's machine-readable sweep results live, what each one means and how stale
one may be before a reader stops trusting it (SERV-356). Satlink's Practices board is the
reader; it must not re-derive any rule, so each result is the sweep's own output.

## Layout

Two workflows publish to one data branch, each its own file:

- **`architecture-maps.json`**: the estate architecture-map sweep. It names private repos,
  so it lives in the private repo `Einlanzerous/drogue` and only there. The workflow is
  `tools/architecture-maps/drogue/architecture-maps.yml` in this repo: a template, the source
  of truth for drogue's copy (a workflow under `tools/` is not read by GitHub, and the
  programs' tests run here because drogue cannot run them).
- **`base-images.json`**: the base-image sweep's public view, published by this repo's
  `base-images.yml` to this repo's own `estate-results` branch (`docs/base-images.md`).
  It moves to drogue when SERV-359 lands.

In drogue, `main` holds workflows and docs and no data. The data branch `estate-results` is one
orphan commit, force-pushed on every publish, with the files at the root: no history, since a
file is a current reading and not a ledger. A data branch rather than `main` because a daily
data commit would churn `main`, need a ruleset bypass for `GITHUB_TOKEN`, and mix data with
code. Read a file with
`GET repos/<owner>/<repo>/contents/architecture-maps.json?ref=estate-results`.

## The file

```
{ schema: 1, scope: "estate", generatedAt,
  summary: { repos, noMap, inSync, stale, broken, skipped, unreadable },
  repos: [ { repo, state, references, errors, driftedFiles } ] }
```

`scope: "estate"` means unfiltered: private repos are in it, in full. Nothing is redacted,
which is why the destination is locked (below). `repo` is the name without the owner.
`references`, `errors` and `driftedFiles` are integers or `null`; a figure the check did not
measure is `null`, never 0. A consumer ignores fields it does not know; removing or
renaming one bumps `schema`, and the publisher and every consumer refuse a `schema` they do
not know.

### States

The rule is `scripts/architecture-map-check.sh`'s and is defined nowhere else; the sweep only
runs it over a fresh clone of each repo and reads back its one result line.

| state | meaning |
|---|---|
| `no_map` | the repo has no `docs/architecture.archify.json` (read, and absent) |
| `in_sync` | a map exists, is valid, and none of the files it cites changed since its pin |
| `stale` | valid, but cited files changed since the pin (`driftedFiles` says how many) |
| `broken` | the map would not render: a path absent at the pin, a malformed source, unparseable JSON, too many sources (`errors` says how many) |
| `skipped` | the check could not run: the pinned commit could not be fetched, or `jq` was missing |
| `unreadable` | the sweep could not get an answer (below) |

### Unreadable is never missing

`no_map` is claimed only when the check ran in a clone and found no map. A clone that failed,
a clone that timed out, a check that was killed or timed out (so wrote no result), and a
result line that is not exactly the shape the script writes are all `unreadable`, with the
three figures `null`. A pin the clone does not hold is fetched with the same read-only
credential, because a depth-1 clone almost never holds it: without the credential every
private repo would read `skipped`, and a missing `ESTATE_READ_TOKEN` is reported as such and
leaves private repos `unreadable` or `skipped`, never `no_map`. A repo that is absent from
`repos[]` is not clean; the sweep writes a row for every repo in the estate list or no
document at all.

### How stale a document may be

The workflow runs **daily at 06:30 UTC**, on a push to `main` in drogue and on dispatch. A
document up to a day old is normal. **Treat a `generatedAt` older than 3 days as
unreadable**, and a 404 on the file (no branch, no file) as unreadable too, not as an empty
estate. A red `publish` job means the file is stale; a red `sweep` job means at least one repo
was unreadable (the document is still published, because a broken map is data).

## The run

`sweep` clones every first-party repo (the list is `estateRepos` of the pinned checkout's
`docker-compose.yml`, the same derivation `docs/base-images.md` uses) with `ESTATE_READ_TOKEN`,
a read-only fine-grained token held in Signet and synced to drogue as a repo secret. It
reaches git only as an environment `extraheader`, never in argv, a URL, a log or the document.
The check's own output is captured and dropped, so a hostile map cannot put a workflow command
in the log: the log holds one `repo state` line per repo. Exit 0 means every repo was read,
1 that a document was written and some repo is `unreadable`, 2 that there is no document.
`publish` runs on `!cancelled()` and the sweep's `published` output, not on `success()`, so a
red sweep still publishes. Both jobs run only on `refs/heads/main`, and the template has no
`pull_request` event, because a pull request's copy of a workflow runs with the repo's secrets.

construct-server is checked out at **one full SHA**, so the code holding the read token is the
reviewed code. It moves only by a drogue pull request that bumps the SHA, and a new service
reaches the sweep through that bump (the estate list is read from the pinned checkout). The
template carries the SHA it was last written against; the copy in drogue is the one that runs.

## The destination lock, carry-over and lookups

The document is private data, so it is never produced or pushed anywhere that is not confirmed
private. The sweep refuses (exit 2, before any clone) and the publisher refuses (exit 2,
nothing pushed) unless `GET repos/$GITHUB_REPOSITORY`, made with the workflow's own
`GITHUB_TOKEN`, answers exactly `private: true` (`src/destination.ts`: `false`, a 404, a 5xx,
odd output or an unset `GITHUB_REPOSITORY` all refuse; it is not `repoVisibility`, which reads
a 404 as private). If drogue ever became public the next run would fail closed; what was
already pushed would be public, and the remedy is to re-privatise and delete the branch.

Every publish carries the other allow-listed file on the branch over unchanged, byte for byte,
so two workflows share the branch without erasing each other, and skips a file when the branch
holds a newer `generatedAt` of the same name. A lookup happens only when the branch tip already
holds a private-only file: `private` carries it, `public` drops it with a notice, and a lookup
that cannot answer refuses the whole publish (exit 1, nothing pushed, the branch unchanged), so
a transient 5xx loses one run and no data. A branch with no private-only file, construct-server's
own, never makes a lookup. The mechanics and the per-name policy are in `docs/base-images.md`
"Where it is published, and how fresh it is".

## What SERV-350's redaction still covers

Nothing in these runs: their logs are in a private repo, and the programs have no redaction
mode. SERV-350's redaction (`docs/base-images.md`) stays for construct-server's own public CI,
that is `base-images.yml`, until SERV-359 moves that sweep to drogue. This repo's public tree
names the private repo and the secret and holds no private repo list and no private data: its
test fixtures use synthetic names.

## Operator steps

The repo, its secret and Satlink's read access are the operator's, each verified on its own
before the first publish: `gh api repos/Einlanzerous/drogue --jq .private` prints `true`;
`gh secret list --repo Einlanzerous/drogue` shows `ESTATE_READ_TOKEN` (delivered by
`signet sync`, never `gh secret set`, which the next sync reverts); and the same `.private`
read made with Satlink's own token prints `true`. After the first publish, confirm no ruleset
covers the data branch: `gh api repos/Einlanzerous/drogue/rules/branches/estate-results` is
`[]`, `gh api repos/Einlanzerous/drogue/rulesets` has none covering it, and
`gh api repos/Einlanzerous/drogue/branches/estate-results/protection` is a 404.
