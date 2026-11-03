# Threads and Autoscale

The Anway server can change the threads of a running worker. You can set the count from the console or the API, or turn on autoscale: the server adds threads while jobs wait, and removes them when the load drops.

The server holds the rule. [worker-threads.md](https://github.com/thadeu/anway/blob/main/docs/dev/worker-threads.md) in the server repo explains it in full, with an example.

## Turn on autoscale

```yaml
# config/anway.yml
concurrency: 10   # the start count, and the autoscale min
autoscale:
  max: 40
  # min: 5        # optional: lower than the start count
```

Or with the CLI:

```bash
bin/anway --concurrency 10 --autoscale 40
```

Then:

- While jobs wait in the worker's queues and all threads are busy, each beat adds a quarter of the threads, up to `max`.
- In a burst, with at least 2 waiting jobs for each thread, each beat doubles the threads and adds 15% more, up to `max`.
- After a minute with no waiting jobs and at most half of the threads busy, each step removes a quarter, down to `min`.
- The worker beats every 15 seconds. In a burst, from 10 to 40 threads takes about 30 seconds (10, 22, 40). Back to 10 takes about 5 minutes.

## Set the database pool

Each job thread can hold an ActiveRecord connection. If the worker runs more threads than its pool, jobs fail with `ActiveRecord::ConnectionTimeoutError`. To prevent this:

- The worker sends its pool size to the server as its limit.
- The server refuses a count or an autoscale `max` above the limit.
- A `max` in `config/anway.yml` above the pool goes down to the pool size, and the worker logs a warning at start.

Make the pool of the worker process as large as `max`. The gem sets `ANWAY_WORKER=1` in the worker process before Rails boots, so the web process keeps its own pool:

```yaml
# config/database.yml (Rails 8.1 calls the key max_connections; before, pool)
default: &default
  max_connections: <%= ENV.fetch("RAILS_MAX_THREADS") { ENV["ANWAY_WORKER"] ? 40 : 5 } %>
```

Check the pool that the worker gets:

```bash
ANWAY_WORKER=1 bin/rails runner 'puts ActiveRecord::Base.connection_pool.size'
```

The database server must also accept the connections: for PostgreSQL, `max_connections` must hold the pool of each process.

## Change the threads from the console

Mount the console (see the README), then open **Workers**:

- The bar shows busy threads in green and free threads in grey. A dashed part is the room that autoscale can still add. An amber mark is a count that the worker gets at its next beat.
- **Scale** opens a dialog. Set the thread count, or turn on autoscale with a min and a max.

The worker gets the change at its next beat, up to 15 seconds later. The server saves the change for the worker name (hostname and tag), so after a restart or a deploy the worker starts with it, not with `config/anway.yml`. The console shows "saved in console" on that worker. **Reset to config** in the dialog drops the saved setting, and `config/anway.yml` applies again. In containers, set `ANWAY_HOSTNAME` to a stable name, such as `worker.1`, or each deploy has a new name.

## Change the threads from the API

The server API is on `server.web` (`127.0.0.1:7420` next to the console). Set `server.web_token` to call it from scripts, because without it the token is random at each start.

```bash
# Find the worker id
curl -s http://127.0.0.1:7420/api/v1/workers -H "Authorization: Bearer $TOKEN"

# Run 20 threads
curl -X PATCH http://127.0.0.1:7420/api/v1/workers/$WID -H "Authorization: Bearer $TOKEN" \
  -d '{"concurrency": 20}'

# Autoscale from 5 to 40, then off
curl -X PATCH http://127.0.0.1:7420/api/v1/workers/$WID -H "Authorization: Bearer $TOKEN" \
  -d '{"autoscale": {"min": 5, "max": 40}}'
curl -X PATCH http://127.0.0.1:7420/api/v1/workers/$WID -H "Authorization: Bearer $TOKEN" \
  -d '{"autoscale": false}'
```

## Plain Ruby

`Anway::Runner` takes the same options:

```ruby
runner = Anway::Runner.new(
  queues: %w[default],
  concurrency: 10,
  autoscale: { max: 40 },
  limit: 40              # the most threads that this process can run
)

runner.run
```

Without `limit`, the server accepts up to 1000 threads.

## How the worker changes its threads

- To add threads, the worker grows its connection pool and starts new job threads at once.
- To remove threads, the worker asks threads to stop. Each one first finishes its job. It never stops a running job to scale down.
- A stop that is still pending is canceled when the server asks for more threads again.
- The worker reports the new count at once, so the console shows the threads that run.

`Anway::Client#heartbeat(state, concurrency:)` sends the count and returns the state and the wanted count. `Anway::Client#beat` works as before.

## Problems

| Problem | Cause and fix |
|---|---|
| **Scale** is off in the console | The worker does not report its threads. Update the gem, or the worker is from another client. |
| "this worker can run at most N threads" | N is the database pool of the worker process. Raise the pool, as above. |
| The bar shows "→ N at next beat" for a long time | The worker has not beat yet. It beats every 15 seconds. If the mark stays, check the worker log for `beat failed`. |
| Autoscale does not add threads | No jobs wait in the worker's own queues, or not all threads are busy. Jobs in other queues do not count. |
| The count went back after a deploy | The saved setting belongs to the worker name. A container with a random hostname has a new name at each deploy. Set `ANWAY_HOSTNAME` to a stable name. |
| A change in `config/anway.yml` has no effect | The worker runs on a setting saved in the console ("saved in console"). Use **Reset to config** in the Scale dialog. |
