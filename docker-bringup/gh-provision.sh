#!/system/bin/sh
# Authenticate gh inside claude-term. $1 = the PAT, base64-encoded.
#
# WHY base64 as an ARGUMENT rather than a pipe or scp:
#   - PowerShell 5.1 re-encodes anything through a native-command pipe, which
#     silently corrupts a raw token ("HTTP 401: Bad credentials") and even
#     base64 ("invalid input"). Both look like a bad token; both are transport.
#   - scp cannot be used at all here: dropbear ships no /usr/libexec/sftp-server
#     and modern scp speaks SFTP by default, so it dies with "Connection closed".
# base64 is safe ASCII and survives every quoting layer intact.
#
# The decoded token is written only inside the container and removed
# immediately; it comes to rest solely in ~/.config/gh/hosts.yml in the
# claude-home volume, mode 600. Nothing is written to the host filesystem.
set -e
B64="$1"
[ -n "$B64" ] || { echo "FATAL: no base64 token argument"; exit 1; }
D="/data/docker/bin/docker -H unix:///data/docker/docker.sock"

echo "$B64" | $D exec -i -u claude claude-term sh -c '
  set -e
  tr -d "\r\n " | base64 -d > /tmp/.ghtok
  gh auth login --with-token < /tmp/.ghtok
  rm -f /tmp/.ghtok
  gh auth setup-git
  git config --global user.name  "Quadstronaut"
  git config --global user.email "khgreenprime@gmail.com"
  git config --global core.autocrlf false
  git config --global init.defaultBranch master
  chmod 600 ~/.config/gh/hosts.yml 2>/dev/null || true
  echo "--- verify ---"
  echo "login      : $(gh api user -q .login)"
  echo "repos seen : $(gh repo list --limit 200 --json name -q length)"
  echo "hosts.yml  : $(ls -l ~/.config/gh/hosts.yml | cut -d" " -f1)"
  echo "git helper : $(git config --global --get credential.https://github.com.helper)"
'
