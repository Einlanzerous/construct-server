import { addDays, daysBetween, parseDay } from "./dates.ts";
import { cyclePrecision, productFor, splitRef, tagCycle } from "./ref.ts";
import { blankFields, type Fields, type Run } from "./run.ts";
import type { PolicyStore, Release } from "./policy.ts";

export interface Clock {
  today: string;
  warnDays: number;
}

const SPACE = "[ \\t\\r\\n\\f\\v]";
const ARG_RE = new RegExp(`^${SPACE}*ARG${SPACE}+([A-Za-z_][A-Za-z0-9_]*)=(.*)$`, "s");
const FROM_RE = new RegExp(`^${SPACE}*from${SPACE}+(.*)$`, "is");
const ARG_COMMENT_RE = new RegExp(`${SPACE}#.*$`, "s");
const QUOTES_RE = /["']/g;

const supported = (rs: readonly Release[]): Release[] => rs.filter((r) => r.isEol === false);

// A reference with an unresolvable ${VAR} stops at the first name no ARG declares.
function substitute(ref: string, args: ReadonlyMap<string, string>): { ref: string; unresolved: string } {
  let out = ref;
  for (let guard = 0; out.includes("$"); guard++) {
    const m = /\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/.exec(out);
    if (!m) break;
    const name = m[1] ?? "";
    const value = args.get(name);
    // A default that names itself would never settle; calling it unresolved is the safe side.
    if (value === undefined || guard > 64) return { ref: out, unresolved: name };
    out = out.replaceAll("${" + name + "}", () => value).replaceAll("$" + name, () => value);
  }
  return { ref: out, unresolved: "" };
}

// "Dockerfile" throughout means any of `Dockerfile*`, `*.Dockerfile` or `Containerfile*`
// — interlock builds from docker/web.Dockerfile, which a bare `Dockerfile*` glob misses,
// and the 2026-09-05 survey missed it for exactly that reason.
//
// Check one Dockerfile's contents under a display name.
export async function checkDockerfile(
  run: Run,
  policies: PolicyStore,
  clock: Clock,
  wherePrefix: string,
  content: string,
): Promise<void> {
  const args = new Map<string, string>();
  const stages = new Set<string>();
  const lines = content.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();

  for (const [i, text] of lines.entries()) {
    const lineno = i + 1;
    // `ARG NAME=value` at any point before the FROM that uses it. Only the default is
    // knowable statically, which is also the value a bare `docker build` uses.
    const arg = ARG_RE.exec(text);
    if (arg) {
      const v = (arg[2] ?? "").replace(ARG_COMMENT_RE, "").replace(QUOTES_RE, "");
      args.set(arg[1] ?? "", v);
      continue;
    }
    const from = FROM_RE.exec(text);
    if (!from) continue;

    let ref = "";
    let alias = "";
    let prev = "";
    for (const tok of (from[1] ?? "").split(/[ \t\n]+/).filter((t) => t !== "")) {
      if (prev === "AS" || prev === "as") alias = tok;
      if (!tok.startsWith("--") && ref === "") ref = tok;
      prev = tok;
    }
    if (alias !== "") stages.add(alias);
    const where = `${wherePrefix}:${lineno}`;
    const f: Fields = blankFields(lineno);

    // Substitute ${VAR} / $VAR from declared ARG defaults.
    if (ref.includes("$")) {
      const s = substitute(ref, args);
      ref = s.ref;
      if (s.unresolved !== "") {
        f.ref = ref;
        run.report("UNRESOLVED", where, f, ref, `$${s.unresolved} has no ARG default earlier in the file`);
        continue;
      }
    }

    // A FROM with only flags names no image. Skipping it would turn "could not read this line"
    // into "nothing to report"; it is a finding, like any other line the guard cannot judge.
    if (ref === "") {
      run.report("UNRESOLVED", where, f, ref, "FROM names no image");
      continue;
    }
    if (ref === "scratch") continue;
    if (stages.has(ref)) continue; // FROM <earlier stage>

    const { repo, tag, digest } = splitRef(ref);
    const { product, forced } = productFor(repo);
    f.ref = ref;
    f.image = repo;
    f.tag = tag || null;
    f.digest = digest || null;
    if (product === "") {
      run.report("UNMAPPED", where, f, ref, `no endoflife.date product mapped for '${repo}' — add it to PRODUCT_MAP`);
      continue;
    }

    const policy = await policies.get(product);
    const newest = supported(policy.releases)[0]?.name ?? "";
    f.product = product;
    f.newestSupported = newest || null;
    let cycle: string;
    if (forced !== "") {
      cycle = forced;
    } else {
      const tc = tagCycle(policy, tag);
      if (tc.kind === "floating") {
        if (digest !== "") {
          run.report("UNKNOWN", where, f, ref, `digest-pinned, but the tag names no ${product} cycle so its support status cannot be checked`);
        } else {
          run.report(
            "FLOATING",
            where,
            f,
            ref,
            `tag names no ${product} cycle (needs ${cyclePrecision(policy)}-component version, e.g. ${supported(policy.releases)[0]?.name ?? "null"})`,
          );
        }
        continue;
      }
      if (tc.kind === "unknown") {
        run.report("UNKNOWN", where, f, ref, `'${tag}' is not a ${product} cycle endoflife.date lists`);
        continue;
      }
      cycle = tc.cycle;
    }

    f.cycle = cycle;
    const release = policy.releases.find((r) => r.name === cycle);
    const isEol = release?.isEol === true;
    const eolFrom = release?.eolFrom || "";

    // isEol is endoflife.date's own verdict, but it is computed against ITS clock; the
    // date comparison below is what makes BASE_IMAGE_TODAY meaningful and what catches
    // a cycle whose eolFrom has passed since the JSON was cached.
    // Go and nginx publish no EOL date: a cycle is supported until the second-next one
    // ships, and endoflife.date carries eolFrom: null for every supported cycle of both.
    // A date-only warning would therefore never fire for two of the estate's commonest
    // base products and the guard would go straight from OK to EOL. So with no date, the
    // OLDEST supported cycle gets an ESTIMATED retirement: the newest cycle's release date
    // plus one release cadence, and warns inside the window. The cadence is the gap
    // between the oldest supported cycle and the one it replaced — NOT the gap to the
    // newest, because nginx ships its stable and mainline weeks apart (1.30 in April,
    // 1.31 in May) and that gap would put 1.30's retirement in the past. An estimate,
    // labelled as one; it is what makes "see it coming" true for Go.
    let estEol = "";
    if (eolFrom === "") {
      const oldestSupported = supported(policy.releases).at(-1)?.name ?? "null";
      if (cycle === oldestSupported && cycle !== newest) {
        const newestRel = policy.releases.find((r) => r.name === newest)?.releaseDate || "";
        const oldestRel = release?.releaseDate || "";
        const idx = policy.releases.findIndex((r) => r.name === cycle);
        const prevRel = idx !== -1 && idx + 1 < policy.releases.length ? policy.releases[idx + 1]?.releaseDate || "" : "";
        if (newestRel && oldestRel && prevRel) {
          const cadence = daysBetween(parseDay(oldestRel, "releaseDate"), parseDay(prevRel, "releaseDate"));
          estEol = addDays(parseDay(newestRel, "releaseDate"), cadence);
        }
      }
    }

    // The document's date is the published one, else the estimate, labelled as one.
    f.eolDate = eolFrom || estEol || null;
    f.eolDateEstimated = eolFrom === "" && estEol !== "";

    const today = parseDay(clock.today, "BASE_IMAGE_TODAY");
    const until = (d: string): number => daysBetween(parseDay(d, "eolFrom"), today);
    if (isEol || (eolFrom !== "" && until(eolFrom) < 0)) {
      run.report("EOL", where, f, ref, `${product} ${cycle} reached end-of-life ${eolFrom || "(unknown date)"}; newest supported is ${newest || "none"}`);
    } else if (eolFrom !== "" && until(eolFrom) <= clock.warnDays) {
      run.report("SOON", where, f, ref, `${product} ${cycle} reaches end-of-life ${eolFrom} (${until(eolFrom)} days); newest supported is ${newest}`);
    } else if (estEol !== "" && until(estEol) <= clock.warnDays) {
      run.report(
        "SOON",
        where,
        f,
        ref,
        `${product} ${cycle} is the oldest supported cycle and publishes no EOL date; the next release retires it, estimated ~${estEol} from the release cadence; newest supported is ${newest}`,
      );
    } else {
      run.report("OK", where, f, ref, `${product} ${cycle} supported${eolFrom ? ` until ${eolFrom}` : ""}`);
    }
  }
}
