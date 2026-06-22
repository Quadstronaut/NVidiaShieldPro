const term = new window.Terminal({ cursorBlink: true, fontSize: 14 });
const fit = new window.FitAddon.FitAddon();
term.loadAddon(fit);
term.open(document.getElementById('term'));
fit.fit();

let ws = null;
const $ = (id) => document.getElementById(id);

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
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      const ESC = '\x1b';
      const payload = `${ESC}[200~${c.body}${ESC}[201~` + (c.submit ? '\r' : '');
      ws.send(JSON.stringify({ type: 'data', data: payload }));
      term.focus();
    });
    $('chips').appendChild(b);
  }
}

function connect(name) {
  if (ws) ws.close();
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws?session=${encodeURIComponent(name)}`);
  ws.onmessage = (ev) => { const m = JSON.parse(ev.data); if (m.type === 'data') term.write(m.data); };
  ws.onopen = () => { fit.fit(); ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows })); };
}

term.onData((d) => { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'data', data: d })); });
window.addEventListener('resize', () => {
  fit.fit();
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'resize', cols: term.cols, rows: term.rows }));
});

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
