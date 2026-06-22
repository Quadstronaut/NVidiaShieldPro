import nodePty from '@homebridge/node-pty-prebuilt-multiarch';

// D2/D3: a thin bridge. tmux owns persistence; node-pty runs `tmux attach`.
// `spawn` is injectable so the protocol is unit-testable without a real PTY.
export function attachSession(ws, sessionName, { spawn = nodePty.spawn } = {}) {
  const p = spawn('tmux', ['attach', '-t', sessionName], {
    name: 'xterm-color',
    cols: 80,
    rows: 24,
    cwd: process.env.HOME,
    env: process.env,
  });

  p.onData((data) => {
    try { ws.send(JSON.stringify({ type: 'data', data })); } catch { /* ws gone */ }
  });
  p.onExit(() => {
    try { ws.close(); } catch { /* already closed */ }
  });

  ws.on('message', (raw) => {
    let m;
    try { m = JSON.parse(raw.toString()); } catch { return; }
    if (m.type === 'data') p.write(m.data);
    // FIX 5: clamp resize dims to [1, 500] to prevent malformed PTY state
    else if (m.type === 'resize') p.resize(Math.max(1, Math.min(500, m.cols | 0)), Math.max(1, Math.min(500, m.rows | 0)));
  });
  // I6: detaching the PTY leaves the tmux session running for reattach.
  ws.on('close', () => p.kill());

  return p;
}
