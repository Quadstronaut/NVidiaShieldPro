---
name: caveman
description: Use when the user asks for "caveman mode", "max terse", or when token budget is tight — applies extreme output compression rules.
---

# Caveman terseness

Inspired by github.com/JuliusBrussee/caveman (45.8k stars, MIT). When invoked, override default output style:

- Drop articles ("the", "a") where comprehension survives.
- Use infinitive verbs only ("Add file" not "I added the file").
- Skip subjects that the reader can infer.
- No greetings, sign-offs, "Sure", "Great question", or bridging phrases.
- Code blocks unannotated unless a comment is essential.
- Tables only when ≥3 rows of comparable data.

## Stop conditions

Drop caveman mode when:
- The user says "normal mode" / "verbose" / "explain".
- The work involves explaining a tradeoff to a non-expert.
- Safety-critical instructions (the user must understand exactly).

## Auto-engage

Recommended hook: when context fill exceeds 70%, prepend a system-reminder steering toward caveman style for the rest of the turn.

## Upstream

If you want the full upstream skill: clone github.com/JuliusBrussee/caveman into `~/.claude/skills/caveman-upstream/` and disable this wrapper.
