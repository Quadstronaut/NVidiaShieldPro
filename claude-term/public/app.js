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

// ---- Prompts overlay -------------------------------------------------------
// Chips float over the terminal so the TTY keeps full height — it only ever
// loses the header row, never a chips row. Opening anchors the panel just below
// the header (whose height varies when it wraps on narrow phones).
function promptsOpen() { return !$('prompts-panel').hasAttribute('hidden'); }
function openPrompts() {
  const panel = $('prompts-panel');
  panel.style.top = document.querySelector('header').getBoundingClientRect().bottom + 'px';
  panel.removeAttribute('hidden');
  $('prompts').setAttribute('aria-expanded', 'true');
}
function closePrompts() {
  $('prompts-panel').setAttribute('hidden', '');
  $('prompts').setAttribute('aria-expanded', 'false');
}
function togglePrompts() { promptsOpen() ? closePrompts() : openPrompts(); }

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
      closePrompts(); // give the TTY back its full height after a pick
    });
    $('chips').appendChild(b);
  }
}

// ---- Login-link detector ---------------------------------------------------
// Claude prints its OAuth URL into the TTY where it soft-wraps and can't be
// tapped or copied. Buffer recent output, strip ANSI, rejoin the wrap-broken
// URL pieces, and surface the whole link as Open/Copy plus a paste-code box for
// the step where Claude asks you to paste the auth code back.
const ANSI = /\x1b\[[0-9;?]*[A-Za-z]/g; // strip CSI/SGR (colors, cursor moves)
const URLCH = "A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-";
const JOIN_WRAP = new RegExp(`([${URLCH}])[\\r\\n]+(?=[${URLCH}])`, 'g');
const LOGIN_URL = /https:\/\/(?:claude\.ai\/oauth[^\s'"]*|(?:console|auth)\.anthropic\.com\/[^\s'"]*)/i;
let outBuf = '';
let lastLoginUrl = '';
function scanForLogin(chunk) {
  outBuf = (outBuf + chunk).slice(-8192);
  const clean = outBuf.replace(ANSI, '').replace(JOIN_WRAP, '$1');
  const m = clean.match(LOGIN_URL);
  if (!m) return;
  const url = m[0].replace(/[)\].,;]+$/, ''); // trim trailing prose punctuation
  if (url !== lastLoginUrl) { lastLoginUrl = url; showLogin(url); }
}
function showLogin(url) {
  const b = $('login-banner');
  $('lb-open').href = url;
  b.dataset.url = url;
  b.style.top = (document.querySelector('header').getBoundingClientRect().bottom + 8) + 'px';
  b.removeAttribute('hidden');
  toast('Claude login link detected', false);
}
function hideLogin() { $('login-banner').setAttribute('hidden', ''); }

// ---- terminal <-> ws -------------------------------------------------------
function connect(name) {
  if (ws) ws.close();
  outBuf = ''; lastLoginUrl = ''; hideLogin();
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws?session=${encodeURIComponent(name)}`);
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.type === 'data') { term.write(m.data); scanForLogin(m.data); }
  };
  ws.onopen = () => { requestAnimationFrame(syncFit); };
}

term.onData((d) => { if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'data', data: d })); });
window.addEventListener('resize', syncFit);

// header controls
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

// prompts overlay controls — stopPropagation so the document handler below
// doesn't immediately re-close it; outside-tap and Escape both dismiss.
$('prompts').addEventListener('click', (e) => { e.stopPropagation(); togglePrompts(); });
document.addEventListener('click', (e) => {
  if (promptsOpen() && !$('prompts-panel').contains(e.target) && e.target !== $('prompts')) closePrompts();
});
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closePrompts(); });

// login banner controls
$('lb-copy').addEventListener('click', async () => {
  const url = $('login-banner').dataset.url || '';
  try {
    await navigator.clipboard.writeText(url);
    toast('Login URL copied', false);
  } catch {
    const ta = document.createElement('textarea');
    ta.value = url; document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); toast('Login URL copied', false); }
    catch { toast('Copy failed — long-press the link instead', true); }
    ta.remove();
  }
});
$('lb-send').addEventListener('click', () => {
  const code = $('lb-code').value.trim();
  if (!code) return;
  if (!ws || ws.readyState !== WebSocket.OPEN) { toast('No session connected', true); return; }
  ws.send(JSON.stringify({ type: 'data', data: code + '\r' }));
  $('lb-code').value = '';
  toast('Code sent to Claude', false);
  hideLogin();
});
$('lb-dismiss').addEventListener('click', hideLogin);

(async () => {
  await Promise.all([refreshSessions(), refreshDirs(), loadChips()]);
  if ($('sessions').value) connect($('sessions').value);
})();
