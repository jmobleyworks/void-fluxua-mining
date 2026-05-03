export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      return new Response(JSON.stringify({
        status: 'operational',
        path: url.pathname,
        method: request.method,
        timestamp: new Date().toISOString()
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      });
    } catch (e) {
      return new Response(JSON.stringify({
        error: e.message,
        stack: e.stack
      }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' }
      });
    }
  }
};
