import { pinBehaviour } from "../sources/versions.ts";
import { repoUrl } from "../sources/repos.ts";
import { code, frontmatter, provenance, section, table } from "../lib/md.ts";
import type { Estate } from "../model.ts";
import type { Page } from "./page.ts";
import { servicePath } from "./services.ts";

export function emitVersions(estate: Estate): Page {
  const firstParty = estate.prod.services.filter((s) => s.image?.firstParty);

  // A pin nobody reads and an image nobody pins are both worth surfacing: the first
  // is dead weight after a service is removed, the second silently floats to
  // `:latest` and undoes SERV-88. deploy.yml fails on the second; nothing catches
  // the first, so this page is where it shows up.
  const usedVars = new Set(firstParty.map((s) => s.image?.tagVar).filter(Boolean));
  const orphanPins = estate.pins.filter((p) => !usedVars.has(p.variable));
  const unpinned = firstParty.filter((s) => !s.image?.tagVar || !estate.pins.some((p) => p.variable === s.image?.tagVar));

  return {
    path: "versions",
    body: [
      frontmatter({ title: "Deployed versions" }),
      provenance(["versions.env", estate.prod.label]),
      [
        "What version of what is actually live. These are tracked in git deliberately (SERV-96):",
        "an image tag is not a credential, and keeping the pins in a file makes a version change",
        "a reviewable diff and gives rollback its index for free — `git log -p versions.env`.\n\n",
        "**Change a version by editing `versions.env` and merging it.** Not with `gh secret set`,",
        "and not by editing a deployed or checkout `.env` — the deployed file is regenerated from",
        "this one on every deploy, so a host edit is lost without warning.\n\n",
      ].join("\n"),

      section(
        "Pins",
        table(
          ["Variable", "Value", "Style", "Source repo", "Images"],
          estate.pins.map((pin) => {
            const images = firstParty.filter((s) => s.image?.tagVar === pin.variable);
            return [
              code(pin.variable),
              code(pin.value),
              pin.style,
              `[${pin.repo}](${repoUrl(pin.repo)})`,
              images.length > 0
                ? images.map((s) => `[${s.name}](/${servicePath(s.name)})`).join(", ")
                : "— *no service uses this*",
            ];
          }),
        ),
      ),

      section(
        "What each style means on the next pull",
        table(
          ["Style", "Behaviour"],
          [...new Set(estate.pins.map((p) => p.style))].map((style) => [style, pinBehaviour(style)]),
        ),
      ),

      section(
        "First-party images and the variable that pins them",
        table(
          ["Image", "Service", "Tag expression", "Resolves to"],
          firstParty.map((s) => [
            code(s.image?.repo),
            `[${s.name}](/${servicePath(s.name)})`,
            code(s.image?.tag),
            code(estate.pins.find((p) => p.variable === s.image?.tagVar)?.value) ?? "—",
          ]),
        ),
      ),

      unpinned.length === 0
        ? ""
        : section(
            "Unpinned first-party images",
            [
              "::: danger THESE WOULD FLOAT TO `:latest`",
              "Each of these resolves through the `:-latest` fallback, which makes the deployed",
              "version nondeterministic (SERV-88). `deploy.yml` asserts on",
              "`docker compose config --images` and will fail the deploy on them.",
              ":::\n",
              unpinned.map((s) => `- [${s.name}](/${servicePath(s.name)}) — ${code(s.image?.raw)}`).join("\n"),
              "\n",
            ].join("\n"),
          ),

      orphanPins.length === 0
        ? ""
        : section(
            "Pins no service reads",
            [
              "Set in `versions.env` but matched by no first-party image in compose. Usually the",
              "residue of a removed service; harmless, but it is not pinning anything.\n",
              orphanPins.map((p) => `- ${code(p.variable)} = ${code(p.value)}`).join("\n"),
              "\n",
            ].join("\n"),
          ),

      section(
        "Auditing what is actually running",
        [
          "A `sha-<short>` tag and a release tag can be **different images built from the same",
          "commit** — the publish workflow runs once on the push to `main` and again on the release",
          "tag, seconds apart, so the two digests differ. Compare the revision label, not the digest,",
          "or you will invent version drift that is not there (SERV-88):\n",
          "```bash",
          "docker inspect --format '{{ index .Config.Labels \"org.opencontainers.image.revision\" }}' <container>",
          "```\n",
        ].join("\n"),
      ),
    ].join(""),
  };
}
