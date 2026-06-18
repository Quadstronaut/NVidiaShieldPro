import { json } from '@sveltejs/kit';
import { getSnapshot } from '$lib/server/sampler.js';

// One-shot MetricsSnapshot for non-SSE clients / tests (no auth — A2).
export async function GET() {
  try {
    const snap = await getSnapshot();
    if (!snap) {
      return json({ error: 'sampler not ready' }, { status: 503 });
    }
    return json(snap, {
      headers: { 'cache-control': 'no-store' }
    });
  } catch (err) {
    return json(
      { error: 'metrics failed', detail: err?.message ?? String(err) },
      { status: 500 }
    );
  }
}
