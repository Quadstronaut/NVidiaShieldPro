# claude-env — the Shield's Claude Code steering

Portable steering for the headless Claude Code running inside the **claude-term**
container. One-way mirror of the PC's `~/.claude`, sanitized for the Shield.

## Contents

| Item | Source | Notes |
|---|---|---|
| `CLAUDE.md` | PC `~/.claude/CLAUDE.md` | Local-LLM offload + Windows-shell rules stripped (the Shield has no ollama). |
| `skills/` | PC `~/.claude/skills` | Symlinks dereferenced to real content. |
| `agents/` | PC `~/.claude/agents` | Cheap-routing + council subagents. |

Deliberately **absent**: `settings.json` and `.claude.json`. The container's own
copies are edited in place by the launcher (hooks + MCP servers removed); the
OAuth token and Windows-local paths in `.claude.json` never leave the PC.

## Sync flow

```
PC ~/.claude  --(tools/export-claude-env.ps1)-->  claude-env/  --(git push)-->
GitHub  --(boot/redeploy git-sync)-->  /data/NVidiaShieldPro/claude-env  -->
docker-bringup/claude-steer.sh  -->  claude-term:/home/claude/.claude
```

- **Regenerate** after changing global skills/agents/CLAUDE.md on the PC:
  `pwsh tools/export-claude-env.ps1`, then commit + push.
- **Apply** on the Shield: `docker-bringup/claude-steer.sh` (wired into
  `deploy/redeploy.sh`, so a push reaches the device on the next boot/redeploy).
  It is non-destructive — only `/home/claude/.claude` steering changes; the
  container, its auth, and its uptime are untouched. Each `claude -p` turn reads
  the steering fresh, so no restart is needed.
