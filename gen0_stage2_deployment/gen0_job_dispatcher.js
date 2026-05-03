/**
 * GEN 0 JOB DISPATCHER - Regular Worker (not Durable Object)
 *
 * Role: Router/Bus in virtual computer architecture
 * Responsibilities:
 *   1. Assign jobs from D1 queue to available workers
 *   2. Track job assignments with timeout recovery
 *   3. Maintain round-robin distribution
 *   4. Handle worker heartbeats and failures
 */

class JobDispatcher {
  constructor(env) {
    this.env = env;
    this.workerIndex = 0; // Round-robin pointer
    this.lastCleanup = Date.now();
  }

  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    try {
      // GET /request-job - Worker requests next job
      if (path === '/request-job' && request.method === 'GET') {
        const workerId = url.searchParams.get('worker_id');
        return await this.requestJob(workerId);
      }

      // POST /job-complete - Worker reports job completion
      if (path === '/job-complete' && request.method === 'POST') {
        const { job_id, worker_id, status } = await request.json();
        return await this.jobComplete(job_id, worker_id, status);
      }

      // GET /status - Dispatcher status
      if (path === '/status' && request.method === 'GET') {
        return await this.statusRequest();
      }

      // POST /assign-job - Admin assigns specific job
      if (path === '/assign-job' && request.method === 'POST') {
        const { job_id, worker_id } = await request.json();
        return await this.assignJob(job_id, worker_id);
      }

      return new Response('Job Dispatcher\n\nEndpoints:\nGET /request-job?worker_id=X\nPOST /job-complete\nGET /status\n', {
        headers: { 'Content-Type': 'text/plain' }
      });
    } catch (error) {
      return json({ error: error.message }, 500);
    }
  }

  /**
   * Worker requests next job
   */
  async requestJob(workerId) {
    // Periodic cleanup: timeout jobs assigned >60s ago
    if (Date.now() - this.lastCleanup > 30000) {
      await this.cleanupTimedOutJobs();
      this.lastCleanup = Date.now();
    }

    // Get next available job from D1
    let job = null;
    if (this.env.DB) {
      try {
        job = await this.env.DB.prepare(
          'SELECT * FROM job_queue WHERE status=? ORDER BY created_at ASC LIMIT 1'
        ).bind('pending').first();

        if (job) {
          // Mark as assigned immediately (atomic with state)
          await this.env.DB.prepare(
            'UPDATE job_queue SET status=? WHERE job_id=?'
          ).bind('assigned', job.job_id).run();

          // Record assignment
          await this.recordAssignment(job.job_id, workerId);
        }
      } catch (error) {
        console.error('DB error in requestJob:', error.message);
        return json({ error: 'Database error: ' + error.message }, 500);
      }
    }

    return json({
      job: job || null,
      worker_id: workerId,
      timestamp: new Date().toISOString()
    });
  }

  /**
   * Worker reports job completion
   */
  async jobComplete(jobId, workerId, status) {
    if (!jobId || !workerId) {
      return json({ error: 'Missing job_id or worker_id' }, 400);
    }

    try {
      // Update job status
      if (this.env.DB) {
        await this.env.DB.prepare(
          'UPDATE job_queue SET status=? WHERE job_id=?'
        ).bind(status === 'success' ? 'completed' : 'failed', jobId).run();

        // Update assignment
        await this.env.DB.prepare(`
          UPDATE job_assignments SET status=? WHERE job_id=?
        `).bind('completed', jobId).run();
      }

      return json({
        success: true,
        job_id: jobId,
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      return json({ error: error.message }, 500);
    }
  }

  /**
   * Manual job assignment
   */
  async assignJob(jobId, workerId) {
    if (!jobId || !workerId) {
      return json({ error: 'Missing job_id or worker_id' }, 400);
    }

    try {
      if (this.env.DB) {
        // Mark job as assigned
        await this.env.DB.prepare(
          'UPDATE job_queue SET status=? WHERE job_id=?'
        ).bind('assigned', jobId).run();

        // Record assignment
        await this.recordAssignment(jobId, workerId);
      }

      return json({
        success: true,
        job_id: jobId,
        worker_id: workerId,
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      return json({ error: error.message }, 500);
    }
  }

  /**
   * Record job assignment in D1
   */
  async recordAssignment(jobId, workerId) {
    if (!this.env.DB) return;

    try {
      await this.env.DB.prepare(`
        CREATE TABLE IF NOT EXISTS job_assignments (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          job_id TEXT NOT NULL,
          worker_id TEXT NOT NULL,
          assigned_at DATETIME DEFAULT CURRENT_TIMESTAMP,
          status TEXT DEFAULT 'assigned'
        )
      `).run();

      await this.env.DB.prepare(
        'INSERT INTO job_assignments (job_id, worker_id) VALUES (?, ?)'
      ).bind(jobId, workerId).run();
    } catch (error) {
      console.error('Error recording assignment:', error.message);
    }
  }

  /**
   * Cleanup timed-out jobs (>60s without completion)
   */
  async cleanupTimedOutJobs() {
    if (!this.env.DB) return;

    try {
      // Find assignments older than 60 seconds still marked "assigned"
      const timedOut = await this.env.DB.prepare(`
        SELECT ja.job_id FROM job_assignments ja
        WHERE ja.status = 'assigned'
        AND datetime(ja.assigned_at) < datetime('now', '-60 seconds')
      `).all();

      for (const row of timedOut.results || []) {
        // Reset job back to pending for reassignment
        await this.env.DB.prepare(
          'UPDATE job_queue SET status=? WHERE job_id=?'
        ).bind('pending', row.job_id).run();

        // Mark assignment as timed out
        await this.env.DB.prepare(
          'UPDATE job_assignments SET status=? WHERE job_id=?'
        ).bind('timeout', row.job_id).run();
      }

      console.log(`Cleanup: ${(timedOut.results || []).length} jobs recovered from timeout`);
    } catch (error) {
      console.error('Error in cleanup:', error.message);
    }
  }

  /**
   * Dispatcher status
   */
  async statusRequest() {
    let stats = { pending: 0, assigned: 0, completed: 0, failed: 0 };

    if (this.env.DB) {
      try {
        const result = await this.env.DB.prepare(`
          SELECT
            SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END) as pending,
            SUM(CASE WHEN status='assigned' THEN 1 ELSE 0 END) as assigned,
            SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END) as completed,
            SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) as failed
          FROM job_queue
        `).first();

        stats = {
          pending: result?.pending || 0,
          assigned: result?.assigned || 0,
          completed: result?.completed || 0,
          failed: result?.failed || 0
        };
      } catch (error) {
        console.error('Error getting stats:', error.message);
      }
    }

    return json({
      id: this.id,
      uptime_ms: Date.now(),
      queue_stats: stats,
      timestamp: new Date().toISOString()
    });
  }
}

/**
 * Utility: JSON response
 */
function json(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { 'Content-Type': 'application/json' }
  });
}

// Export default handler for Worker
export default {
  async fetch(request, env) {
    const dispatcher = new JobDispatcher(env);
    return await dispatcher.fetch(request);
  }
};
