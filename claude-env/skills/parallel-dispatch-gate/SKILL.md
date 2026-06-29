---
name: parallel-dispatch-gate
description: Use when about to spawn a subagent or fan out parallel work — decides whether dispatch is worth the cost and routes to the cheapest competent model.
---

# Parallel Dispatch Gate

Before spawning a subagent or fanning out parallel work, run this gate. It catches reflexive dispatches that waste tokens and ensures the right model is selected.

## The gate

A subagent dispatch is worth it **only if all three** hold:

1. **Volume**: estimated >10 tool calls OR >50k tokens of reads.
2. **Isolation**: the work has clear file-domain boundaries (no overlap with main thread or other subagents).
3. **Statelessness**: no shared mutable state with main thread or sibling subagents.

If any one fails → do the work inline. The cost of subagent spin-up + context transfer + premium model invocation exceeds the savings.

## Model routing once dispatch is justified

| Task type | Subagent | Model |
|---|---|---|
| File search, glob, grep, read | `explore-cheap` | haiku |
| Web research, doc lookup | `research-cheap` | haiku |
| Long-text compression | `summarize-cheap` | haiku |
| Classification, triage | `classify-cheap` | haiku |
| Code writing, refactor | `general-purpose` | sonnet |
| Architectural reasoning | `general-purpose` | sonnet |
| Complex multi-step planning | `Plan` | sonnet |
| User explicitly says "use opus" | (any) | opus |

## Anti-patterns

- Spawning a subagent to read one file. Use `Read` directly.
- Spawning a subagent to run one Bash command. Use `Bash` directly.
- Spawning N parallel subagents that each modify files in the same directory. They will race or conflict. Sequence them or merge into one.
- Defaulting any subagent to sonnet/opus when haiku would do. The 100%-subagent-heavy /usage report is the lived consequence.

## When to override the gate

Two cases:

1. **User explicitly requests parallelism** — even for small tasks, honor it.
2. **The task is genuinely embarrassingly parallel** (e.g., "review these 8 unrelated files in parallel") even at lower per-task volume.

Otherwise, trust the gate.
