// Markdown emission helpers. Deliberately small — the value in this generator is
// in what it reads, not in how it formats.

export interface Frontmatter {
  title: string;
  [key: string]: unknown;
}

export function frontmatter(fm: Frontmatter): string {
  const lines = Object.entries(fm).map(([k, v]) => `${k}: ${JSON.stringify(v)}`);
  return ["---", ...lines, "---", ""].join("\n");
}

/**
 * The banner every generated page carries. This is the load-bearing convention of
 * the whole tier: a reader who wants to change something must be sent to the file
 * that produces it, or they will edit the page and lose the edit on next deploy.
 */
export function provenance(sources: string[]): string {
  const list = sources.map((s) => `\`${s}\``).join(", ");
  return [
    "::: info GENERATED PAGE",
    `Assembled from ${list}. Edits here are overwritten on the next deploy — change the source instead.`,
    ":::",
    "",
  ].join("\n");
}

export function heading(level: number, text: string): string {
  return `${"#".repeat(level)} ${text}\n`;
}

/** Escape the characters that would break out of a table cell. */
export function cell(text: string | null | undefined): string {
  if (text === null || text === undefined || text === "") return "—";
  return String(text).replace(/\|/g, "\\|").replace(/\n/g, " ");
}

export function code(text: string | null | undefined): string {
  if (text === null || text === undefined || text === "") return "—";
  const s = String(text);
  // Widen the delimiter rather than mangling the content, so a value containing a
  // backtick still renders as exactly itself.
  const fenceLen = Math.max(1, ...[...s.matchAll(/`+/g)].map((m) => m[0].length + 1));
  const delim = "`".repeat(fenceLen);
  const pad = s.startsWith("`") || s.endsWith("`") ? " " : "";
  return `${delim}${pad}${s}${pad}${delim}`;
}

export function table(headers: string[], rows: (string | null)[][]): string {
  if (rows.length === 0) return "";
  const head = `| ${headers.join(" | ")} |`;
  const rule = `| ${headers.map(() => "---").join(" | ")} |`;
  const body = rows.map((r) => `| ${r.map((c) => c ?? "—").join(" | ")} |`);
  return [head, rule, ...body, ""].join("\n");
}

export function fence(lang: string, body: string): string {
  return ["```" + lang, body, "```", ""].join("\n");
}

export function section(title: string, body: string, level = 2): string {
  if (!body.trim()) return "";
  return `${heading(level, title)}\n${body.trimEnd()}\n\n`;
}

/**
 * Prepare text lifted from a source-file comment for insertion into Markdown.
 *
 * Comment prose is plain text that happens to look like markup often enough to
 * matter. `<KEY>-<NUM>` in a compose comment is a placeholder to its author and an
 * unclosed HTML tag to the Vue compiler, which fails the build — so angle brackets
 * are escaped.
 *
 * Backtick spans are left alone, because they are the one part of a comment that IS
 * markup by intent: authors write `db/init-db.sh` meaning code, and `&lt;` inside a
 * code span would render as those five literal characters instead of `<`.
 */
export function prose(text: string): string {
  return text
    .split(/(`+[^`]*`+)/)
    .map((part, i) => (i % 2 === 1 ? part : part.replace(/</g, "&lt;").replace(/>/g, "&gt;")))
    .join("");
}

/**
 * Comment prose lifted out of a source file, rendered as a quote so it reads as
 * quoted material rather than as something the wiki asserts on its own authority.
 */
export function quote(text: string): string {
  if (!text.trim()) return "";
  return (
    prose(text)
      .split("\n")
      .map((line) => `> ${line}`.trimEnd())
      .join("\n") + "\n"
  );
}

/**
 * Rewrite repo-relative links in an ingested document to absolute GitHub URLs.
 *
 * A README's `![logo](client/src/assets/logo.png)` means "that file, in that repo".
 * Reproduced here unchanged it means "that file, in the wiki" — which does not
 * exist, and Vite fails the build trying to bundle it. So this is a correctness fix
 * rather than a workaround: the link is resolved against the repo it was written
 * in, which is what it always meant.
 *
 * Images resolve against raw.githubusercontent (the file itself); everything else
 * against the blob view (the file in its repo, readable). Absolute URLs, in-page
 * anchors and `mailto:` are left alone.
 */
export function absolutizeLinks(markdown: string, owner: string, repo: string, branch = "main"): string {
  const blob = `https://github.com/${owner}/${repo}/blob/${branch}/`;
  const raw = `https://raw.githubusercontent.com/${owner}/${repo}/${branch}/`;

  const resolve = (target: string, isImage: boolean): string => {
    const t = target.trim();
    if (t === "" || /^(https?:|\/\/|#|mailto:|data:|tel:)/i.test(t)) return target;
    return (isImage ? raw : blob) + t.replace(/^\.\//, "").replace(/^\//, "");
  };

  return mapOutsideFences(markdown, (line) =>
    line
      // ![alt](target) and [text](target); the leading `!` decides which base.
      .replace(/(!?)\[([^\]]*)\]\(([^)\s]+)(\s+"[^"]*")?\)/g, (_m, bang, text, target, title) => {
        return `${bang}[${text}](${resolve(target, bang === "!")}${title ?? ""})`;
      })
      // Raw HTML, which READMEs use freely for centring, sizing and light/dark
      // artwork. Matched by attribute rather than by tag: a `<picture>` block
      // carries the asset on `<source srcset>`, and missing it fails the build just
      // as surely as missing `<img src>` would.
      .replace(/\b(src|poster)=("|')([^"']+)\2/gi, (_m, attr, q, target) => `${attr}=${q}${resolve(target, true)}${q}`)
      .replace(/\bhref=("|')([^"']+)\1/gi, (_m, q, target) => `href=${q}${resolve(target, false)}${q}`)
      .replace(/\bsrcset=("|')([^"']+)\1/gi, (_m, q, value) => {
        // `url 2x, url 640w` — a descriptor may follow each candidate.
        const rewritten = String(value)
          .split(",")
          .map((candidate) => {
            const [url, ...rest] = candidate.trim().split(/\s+/);
            return [resolve(url ?? "", true), ...rest].join(" ");
          })
          .join(", ");
        return `srcset=${q}${rewritten}${q}`;
      }),
  );
}

/** Apply a line transform everywhere except inside fenced code blocks. */
function mapOutsideFences(markdown: string, fn: (line: string) => string): string {
  let inFence = false;
  return markdown
    .split("\n")
    .map((line) => {
      if (/^\s*(```|~~~)/.test(line)) {
        inFence = !inFence;
        return line;
      }
      return inFence ? line : fn(line);
    })
    .join("\n");
}

/** Anything safe to use as a filename and a URL segment. */
export function slug(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/**
 * Demote every ATX heading in an ingested document by `by` levels, so a file whose
 * own `# Title` is an h1 does not collide with the page title VitePress renders
 * from frontmatter. Fenced code is skipped — `#` inside a shell block is a
 * comment, not a heading.
 */
export function demoteHeadings(markdown: string, by: number): string {
  return mapOutsideFences(markdown, (line) => {
    const m = /^(#{1,6})(\s+)/.exec(line);
    if (!m) return line;
    const level = Math.min(6, (m[1]?.length ?? 1) + by);
    return `${"#".repeat(level)}${m[2]}${line.slice(m[0].length)}`;
  });
}
