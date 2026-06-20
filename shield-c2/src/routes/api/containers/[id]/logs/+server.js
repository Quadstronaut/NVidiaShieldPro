import { json } from '@sveltejs/kit';
import { containerLogs } from '$lib/server/docker.js';

// logs (allowlist). text/plain, tail default 200 cap 1000.
export async function GET({ params, url }) {
  try {
    const tail = url.searchParams.get('tail');
    const text = await containerLogs(params.id, tail);
    return new Response(text, {
      status: 200,
      headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' }
    });
  } catch (err) {
    return json(
      { error: 'logs failed', detail: err?.detail ?? err?.message ?? String(err) },
      { status: err?.status && err.status < 600 ? err.status : 502 }
    );
  }
}
