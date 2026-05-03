/**
 * Consolidated Job Dispatcher - Multi-Pool
 * Routes to appropriate pool based on worker_id
 */

async function handleRequest(request, env) {
  const url = new URL(request.url);

  if (url.pathname === "/pull-job" && request.method === "GET") {
    const worker_id = url.searchParams.get("worker_id");
    if (!worker_id) {
      return new Response(JSON.stringify({ error: "Missing worker_id" }), { status: 400 });
    }

    const worker_num = parseInt(worker_id.split("-")[2]);
    if (isNaN(worker_num)) {
      return new Response(JSON.stringify({ error: "Invalid worker_id format" }), { status: 400 });
    }

    let pool_id;
    if (worker_num < 33) {
      pool_id = "moneroocean";
    } else if (worker_num < 66) {
      pool_id = "nanopool";
    } else if (worker_num < 100) {
      pool_id = "minexmr";
    } else {
      return new Response(
        JSON.stringify({ error: "Worker ID out of range" }),
        { status: 403 }
      );
    }

    try {
      const stmt = env.DB.prepare(
        "SELECT nonce, job_id, difficulty, pool_id FROM nonces WHERE pool_id = ? LIMIT 1"
      );
      const result = stmt.bind(pool_id).first();

      if (result) {
        env.DB.prepare("DELETE FROM nonces WHERE job_id = ?").bind(result.job_id).run();

        return new Response(
          JSON.stringify({
            nonce: result.nonce,
            job_id: result.job_id,
            difficulty: result.difficulty,
            pool_id: result.pool_id,
            worker_id: worker_id
          }),
          { status: 200 }
        );
      } else {
        return new Response(
          JSON.stringify({ error: "No jobs available for pool: " + pool_id }),
          { status: 404 }
        );
      }
    } catch (error) {
      return new Response(
        JSON.stringify({ error: error.message }),
        { status: 500 }
      );
    }
  }

  if (url.pathname === "/health") {
    return new Response(JSON.stringify({ status: "ok", service: "job-dispatcher" }), { status: 200 });
  }

  return new Response("Not Found", { status: 404 });
}

addEventListener("fetch", event => {
  event.respondWith(handleRequest(event.request, event.env || {}));
});
