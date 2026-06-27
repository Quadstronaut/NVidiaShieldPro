// The headless Claude Code driver (spec D1, refined by the plan to one
// process-per-turn + --resume). Spawns real `claude` in print/stream-json mode,
// splits its newline-delimited JSON event stream, and normalizes each event into
// the WS event schema the UI renders. This REPLACES the v1 node-pty/tmux bridge:
// the UI is now a renderer over Claude Code's structured events, never an ANSI
// terminal (NI1/NI2).
import { spawn as childSpawn } from 'node:child_process';

// Map a raw Claude Code stream-json event to zero-or-more normalized WS events.
// Observed event taxonomy (on-device probe, CC 2.1.185):
//   system/init · stream_event (SSE deltas) · assistant · user(tool_result) · result
// Delta events are marked {ephemeral:true} so the hub streams them live but does
// NOT buffer them into the replayable transcript.
function normalize(ev) {
  switch (ev.type) {
    case 'system':
      if (ev.subtype === 'init') {
        return [{
          type: 'status', running: true,
          model: ev.model, sessionId: ev.session_id,
          slashCommands: ev.slash_commands || [],
        }];
      }
      return [];

    case 'stream_event': {
      const e = ev.event || {};
      if (e.type === 'content_block_delta') {
        if (e.delta?.type === 'text_delta') {
          return [{ type: 'assistant_delta', text: e.delta.text, ephemeral: true }];
        }
        if (e.delta?.type === 'thinking_delta') {
          return [{ type: 'assistant_delta', text: e.delta.thinking, thinking: true, ephemeral: true }];
        }
        return []; // input_json_delta etc. — the tool card lands on the assistant event
      }
      if (e.type === 'message_stop') {
        return [{ type: 'assistant_delta', done: true, ephemeral: true }];
      }
      return [];
    }

    case 'assistant': {
      const blocks = ev.message?.content || [];
      const out = [];
      for (const b of blocks) {
        if (b.type === 'text' && b.text) out.push({ type: 'assistant_message', text: b.text });
        else if (b.type === 'tool_use') out.push({ type: 'tool_use', id: b.id, name: b.name, input: b.input || {} });
        else if (b.type === 'thinking' && b.thinking) out.push({ type: 'assistant_thinking', text: b.thinking });
      }
      return out;
    }

    case 'user': {
      // In headless single-turn flows the only `user` events are tool results.
      const blocks = ev.message?.content;
      if (!Array.isArray(blocks)) return [];
      const out = [];
      for (const b of blocks) {
        if (b.type === 'tool_result') {
          out.push({
            type: 'tool_result', id: b.tool_use_id,
            content: stringifyResult(b.content), isError: !!b.is_error,
          });
        }
      }
      return out;
    }

    case 'result': {
      const u = ev.usage || {};
      // Approx context fill: this turn's input (fresh + cached) over the model's
      // window. modelUsage carries contextWindow; default to 200k (Sonnet/Haiku).
      const win = firstContextWindow(ev.modelUsage) || 200000;
      const used = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
      const leftPct = Math.max(0, Math.min(100, Math.round(100 * (1 - used / win))));
      return [
        { type: 'result', costUsd: ev.total_cost_usd || 0, stopReason: ev.stop_reason, contextLeftPct: leftPct },
        { type: 'status', running: false },
      ];
    }

    default:
      return []; // rate_limit_event and anything unrecognized: ignore safely
  }
}

function firstContextWindow(modelUsage) {
  if (!modelUsage) return null;
  for (const k of Object.keys(modelUsage)) {
    if (modelUsage[k]?.contextWindow) return modelUsage[k].contextWindow;
  }
  return null;
}

// tool_result content can be a string or an array of {type:'text',text} blocks.
function stringifyResult(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    return content.map((c) => (typeof c === 'string' ? c : c.text || JSON.stringify(c))).join('\n');
  }
  return content == null ? '' : JSON.stringify(content);
}

// Run one user turn. Resolves with the (possibly newly-assigned) session id once
// the process exits. `onEvent` receives normalized WS events as they stream.
// `spawn` is injectable so the normalizer + line-splitter are unit-testable.
export function runTurn({ cwd, sessionId, text, skipPermissions = true, onEvent, spawn = childSpawn }) {
  const args = ['-p', text, '--output-format', 'stream-json', '--verbose', '--include-partial-messages'];
  if (sessionId) args.push('--resume', sessionId);
  if (skipPermissions) args.push('--dangerously-skip-permissions');

  const proc = spawn('claude', args, { cwd, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });

  let resolvedId = sessionId || null;
  let buf = '';
  proc.stdout.on('data', (chunk) => {
    buf += chunk.toString();
    let nl;
    while ((nl = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (!line.trim()) continue;
      let ev;
      try { ev = JSON.parse(line); } catch { continue; } // skip non-JSON noise
      if (ev.session_id) resolvedId = ev.session_id;
      for (const out of normalize(ev)) onEvent(out);
    }
  });

  let stderr = '';
  proc.stderr.on('data', (c) => { stderr += c.toString(); });

  const done = new Promise((resolve) => {
    proc.on('close', (code, signal) => {
      // Flush any trailing line without a newline.
      if (buf.trim()) {
        try { for (const out of normalize(JSON.parse(buf))) onEvent(out); } catch { /* ignore */ }
      }
      if (code !== 0 && !signal) {
        onEvent({ type: 'error', message: (stderr.trim() || `claude exited ${code}`).slice(0, 500) });
      }
      onEvent({ type: 'status', running: false });
      resolve({ sessionId: resolvedId, ok: code === 0, interrupted: !!signal });
    });
    proc.on('error', (err) => {
      onEvent({ type: 'error', message: `failed to spawn claude: ${err.message}` });
      onEvent({ type: 'status', running: false });
      resolve({ sessionId: resolvedId, ok: false });
    });
  });

  return { proc, kill: () => { try { proc.kill('SIGTERM'); } catch { /* gone */ } }, done };
}

export { normalize }; // exported for unit tests
