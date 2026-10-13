// Pure scheduling policy for gh jobs. No processes, timers or domain cache.
// Interactive work stays FIFO ahead of background polling; duplicate reads
// retain their richer original payload while being promoted when requested.
function jobKey(job) {
        switch (job.kind) {
        case "watch": return "watch:" + job.slug;
        case "commits": return "commits:" + job.slug;
        case "stats": return "stats:" + job.sha;
        case "runs": return "runs:" + job.slug + ":" + job.generation;
        case "events": return "events:" + job.slug + ":" + job.generation;
        case "notifications": return "notifications:" + job.generation;
        default: return job.kind;
        }
}

function enqueue(queue, active, job) {
    const key = jobKey(job);
    if (active !== null && jobKey(active) === key)
        return { queue: queue, added: false };
    const queuedAt = queue.findIndex(queued => jobKey(queued) === key);
    let next;
    let remaining = queue;
    if (queuedAt >= 0) {
        if (job.interactive !== true || queue[queuedAt].interactive)
            return { queue: queue, added: false };
        next = Object.assign({}, queue[queuedAt], { interactive: true });
        remaining = queue.slice(0, queuedAt).concat(queue.slice(queuedAt + 1));
    } else {
        next = Object.assign({}, job, { interactive: job.interactive === true });
    }
    let at = next.interactive ? remaining.findIndex(queued => !queued.interactive) : -1;
    if (at < 0)
        at = remaining.length;
    return { queue: remaining.slice(0, at).concat([next], remaining.slice(at)),
        added: queuedAt < 0 };
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { jobKey: jobKey, enqueue: enqueue };
