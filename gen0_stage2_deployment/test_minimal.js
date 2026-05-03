export default {
  async fetch(request, env, ctx) {
    return new Response(JSON.stringify({
      status: "ok",
      db_bound: !!env.DB,
      kv_bound: !!env.KV,
      worker_id: env.WORKER_ID
    }, null, 2), {
      headers: { 'Content-Type': 'application/json' }
    });
  }
};
