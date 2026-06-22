const term = new window.Terminal({ cursorBlink: true, fontSize: 14 });
const fit = new window.FitAddon.FitAddon();
term.loadAddon(fit);
term.open(document.getElementById('term'));

let ws = null;
const $ = (id) => document.getElementById(id);

// Keep xterm sized to its container and the remote PTY in step. The terminal
// used to render at xterm's default 80x24 (≈a quarter of the screen) because the
// one-shot fit ran before #term had its real layout, and tmux then inherited it.
// Re-fit on a frame, on any container resize, and on every reconnect.
function syncFit() {
  try { fit.fit(); } catch { /* container not laid out yet */ }
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
  }
}
requestAnimationFrame(syncFit);
new ResizeObserver(syncFit).observe(document.getElementById('term'));

// Transient UI feedback so taps never feel dead (the chips used to no-op silently).
function flash(el, cls) {
  el.classList.add(cls);
  setTimeout(() => el.classList.remove(cls), 600);
}
let toastTimer = null;
function toast(msg, isErr) {
  const t = $('toast');
  t.textContent = msg;
  t.classList.toggle('err', !!isErr);
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 2200);
}

async function api(path, opts) {
  const r = await fetch(path, opts);
  if (r.status === 401) { location.href = '/login'; throw new Error('unauth'); }
  return r;
}

async function refreshSessions() {
  const list = await (await api('/api/sessions')).json();
  $('sessions').innerHTML = list.map((s) => `<option value="${s.name}">${s.name} (${s.cwd || '?'})</option>`).join('');
}

async function refreshDirs() {
  const dirs = await (await api('/api/dirs')).json();
  $('newdir').innerHTML = dirs.map((d) => `<option value="${d}">${d}</option>`).join('');
}

async function loadChips() {
  const chips = await (await api('/api/snippets')).json();
  $('chips').innerHTML = '';
  for (const c of chips) {
    const b = document.createElement('button');
    b.textContent = c.label;
    b.className = 'chip';
    b.addEventListener('click', () => {
      if (!ws || ws.readyState !== WebSocket.OPEN) {
        flash(b, 'chip-err');
        toast('No session connected — create or pick one first', true);
        return;
      }
      const ESC = '\x1b';
      const payload = `${ESC}[200~${c.body}${ESC}[201~` + (c.submit ? '\r' : '');
      ws.send(JSON.stringify({ type: 'data', data: payload }));
      term.focus();
      flash(b, 'chip-ok');
      toast(c.submit ? `Sent + submitted: ${c.label}` : `Inserted: ${c.label}`, false);
    });
    $('chips').appendChild(b);
  }
}

function connect(name) {
  if (ws) ws.close();
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws?session=${encodeURIComponent(name)}`);
  ws.onmessage = (ev) => { const m = JSON.parse(ev.data); if (m.type === 'data') term.write(m.data); };
  ws.onopen = () => { requestAnimationFrame(syncFit); };
}

term.onData((d) => { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'data', data: d })); });
window.addEventListener('resize', syncFit);

$('sessions').addEventListener('change', (e) => connect(e.target.value));
$('refresh').addEventListener('click', refreshSessions);
$('create').addEventListener('click', async () => {
  const name = $('newname').value, cwd = $('newdir').value;
  const r = await api('/api/sessions', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name, cwd }) });
  if (r.ok) { await refreshSessions(); $('sessions').value = name; connect(name); }
  else alert((await r.json()).error || 'create failed');
});
$('kill').addEventListener('click', async () => {
  const name = $('sessions').value; if (!name) return;
  await api(`/api/sessions/${encodeURIComponent(name)}`, { method: 'DELETE' });
  await refreshSessions();
});
$('logout').addEventListener('click', async () => { await fetch('/logout', { method: 'POST' }); location.href = '/login'; });

(async () => {
  await Promise.all([refreshSessions(), refreshDirs(), loadChips()]);
  if ($('sessions').value) connect($('sessions').value);
})();
