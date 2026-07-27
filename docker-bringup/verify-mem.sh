#!/system/bin/sh
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
$D exec -u claude claude-term sh -c '
  echo "=== steering landed ==="
  echo "  CLAUDE.md : $(wc -c < /home/claude/.claude/CLAUDE.md) bytes"
  echo "  skills    : $(ls /home/claude/.claude/skills | tr "\n" " ")"
  echo "  agents    : $(ls /home/claude/.claude/agents | wc -l) files"
  echo "  memory    : $(find /home/claude/.claude/projects -path "*/memory/*" -type f | wc -l) files"
  echo
  echo "=== the key that must fire for this repo ==="
  ls /home/claude/.claude/projects/-data-claude-GIT-LOCAL-mod-NVIDIAShield/memory/ 2>&1
'