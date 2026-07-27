#!/system/bin/sh
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
$D exec -u claude claude-term sh -c '
  echo "=== layout ==="
  for c in BUSINESS-pursuits GAMING-practice LOCAL-mod RESEARCH-tools Ultra.cc; do
    printf "  %-18s %s repos\n" "$c" "$(ls -d /data/claude/GIT/$c/*/ 2>/dev/null | wc -l)"
  done
  echo "  book-writing (outside GIT tree): $([ -d /data/claude/book-writing/.git ] && echo present || echo MISSING)"
  echo
  echo "=== spot-check: real clones with working remotes ==="
  for r in LOCAL-mod/NVIDIAShield BUSINESS-pursuits/Starhold GAMING-practice/ED-AFK Ultra.cc/QFlix; do
    d=/data/claude/GIT/$r
    printf "  %-30s %s | %s | %s\n" "$r" "$(git -C $d rev-parse --short HEAD)" "$(git -C $d rev-parse --abbrev-ref HEAD)" "$(git -C $d remote get-url origin | sed s#https://github.com/##)"
  done
  echo
  echo "=== can it actually reach GitHub with credentials? ==="
  git -C /data/claude/GIT/LOCAL-mod/NVIDIAShield ls-remote --heads origin >/dev/null 2>&1 && echo "  private ls-remote: OK" || echo "  private ls-remote: FAILED"
  echo "  gh whoami: $(gh api user -q .login)"
'