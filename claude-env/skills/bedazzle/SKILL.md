---
name: bedazzle
description: Use when the user says "bedazzle" (e.g. "bedazzle the readme"), or asks to deck out / glow up / juice / max the visuals of a README or markdown doc — and ALSO apply by default whenever creating or substantially editing any README.md. The full GitHub-flavored visual treatment.
---

# Bedazzle — the full GitHub-flavored README treatment

Standing intent (user): READMEs should never be plain text. Lean **hard** into visuals — per the user, "you can never go too hard in this area." `bedazzle` is the shorthand to apply or re-apply this to any README / markdown doc; it is **ALSO the default** whenever you create or substantially edit a `README.md`, no keyword needed.

## The treatment — a FLOOR, not a ceiling

Apply everything that fits the repo, and reach for more as GitHub ships new renderable features:

- **Badges (shields.io)** — a header row of tech/version chips (logos via `?logo=`), **plus live repo badges**: `github/last-commit`, `github/repo-size`, `github/languages/top`, `github/license`, `github/stars`, `github/actions/workflow/status` (CI), latest release/tag. Add a **badge nav bar** (`style=for-the-badge` anchor links) jumping to sections.
- **Mermaid diagram(s)** — for any structure clearer drawn than told: architecture, data flow, deploy/CI pipeline, sequence, state, ER, `gitGraph`, `timeline`, mindmap. At least one.
- **GitHub alert callouts** — `> [!NOTE]` / `[!TIP]` / `[!IMPORTANT]` / `[!WARNING]` / `[!CAUTION]` for the load-bearing notes (they render as colored boxes).
- **Centered title block** — `<div align="center">` with the H1, a one-line pitch, the badge rows, and a logo/banner `<img>` if an asset exists.
- **Emoji section headers** + stable `<a id="..."></a>` anchors so nav links never break on emoji-in-heading quirks.
- **At-a-glance summary table** up top; long/granular tables tucked into collapsible `<details><summary>`.
- **Tables, task lists, footnotes, `<kbd>`, `<sub>`/`<sup>`, blockquotes, language-hinted code fences** wherever they add signal.
- Optional polish: a TOC, screenshots/GIFs (only if assets exist), `<picture>` for light/dark variants, tech-stack / contributor rows.

## Hard limits (the ONLY brakes)

- **GitHub strips arbitrary HTML/CSS/JS.** Stay within what actually renders (the tags/features above). No custom text colors beyond badges/alerts/Mermaid themes; no real clickable buttons — badge-links are the substitute.
- **Accuracy is absolute.** Every badge value, diagram, and claim must be true and verifiable — never decorative fiction. Prefer a *dynamic* badge (auto-pulled) over a hand-typed value that can drift.
- Keep it **navigable**: rich, not a wall of noise. Group, collapse, and anchor so the density stays scannable.
- **Verify before done:** Mermaid blocks are valid syntax and render; dynamic badges resolve (the repo must be public/accessible). If a diagram might not render, say so and offer to simplify.

## Discovered tricks (append over time)

_Add new GitHub-renderable features here as they ship, so the floor keeps rising:_
- **PRIVATE repos: NO dynamic `github/*` shields badges.** `github/last-commit`, `repo-size`, `languages/top|count`, `license`, `stars`, `actions/workflow/status` all hit the GitHub API unauthenticated from shields.io's servers → a private repo returns 404 → the badge renders **broken for everyone, including the owner**. On a private repo use ONLY static `shields.io/badge/...` chips (tech/version/status, and a static `License-<name>` only after reading the actual LICENSE). The "prefer dynamic" rule above applies to PUBLIC repos only.
- **Mermaid line breaks: use `<br/>`, never `\n`.** A literal `\n` inside a quoted node label is NOT a reliable line break on GitHub's Mermaid — it can render as the literal text `\n`. Always `<br/>`. (And when editing existing READMEs to fix this: edit with the Edit tool or a byte-level replace scoped to inside the ` ```mermaid ` fence — do NOT use `perl -i`/`sed -i`, which CRLF-convert the whole file under `autocrlf=true` and mangle the `\n` escaping.)
- **Folder name ≠ remote.** Before pushing a bedazzle, `git remote -v` first — a local folder named `Foo` may track a different (or private) repo than `owner/Foo`. And the public README lives on the repo's DEFAULT branch, so if the clone is checked out on a feature branch, switch to default, push, then switch back.
