#!/system/bin/sh
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"
echo "=== ask the SHIELD's Claude something only its MEMORY knows ==="
$D exec -u claude -w /data/claude/GIT/LOCAL-mod/NVIDIAShield claude-term \
  claude -p "Answer from memory in ONE short line: on kernel 4.9 the Shield cannot use Docker bridge networking. What networking mode must containers use instead, and why is bridge broken?"
echo
echo "=== and one from a DIFFERENT memory file ==="
$D exec -u claude -w /data/claude/GIT/LOCAL-mod/NVIDIAShield claude-term \
  claude -p "Answer in ONE short line from memory: which SSH username is used for the Starhold fleet, and which account is locked?"