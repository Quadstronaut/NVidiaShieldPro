import { subscribe } from '$lib/server/sampler.js';
import { config } from '$lib/server/config.js';

// SSE: text/event-stream, one long-lived response per client, all fed by the
// single shared sampler (I7). Sampler faults emit `event: error` but the stream
// stays open.
export function GET({ request }) {
  const encoder = new TextEncoder();

  const stream = new ReadableStream({
    start(controller) {
      const send = (event, data) => {
        try {
          controller.enqueue(
            encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)
          );
        } catch {
          /* controller closed */
        }
      };

      // Advertise cadence to the client immediately.
      send('hello', { sampleIntervalMs: config.intervalMs });

      const unsubscribe = subscribe(
        (snap) => send('metrics', snap),
        (err) => send('error', err)
      );

      // Heartbeat comment keeps proxies from closing an idle connection.
      const ping = setInterval(() => {
        try {
          controller.enqueue(encoder.encode(`: ping\n\n`));
        } catch {
          /* closed */
        }
      }, 15000);
      if (typeof ping.unref === 'function') ping.unref();

      const close = () => {
        clearInterval(ping);
        unsubscribe();
        try {
          controller.close();
        } catch {
          /* already closed */
        }
      };
      request.signal.addEventListener('abort', close);
    }
  });

  return new Response(stream, {
    headers: {
      'content-type': 'text/event-stream',
      'cache-control': 'no-store',
      connection: 'keep-alive'
    }
  });
}
