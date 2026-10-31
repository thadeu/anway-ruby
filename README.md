# anway-ruby

Ruby and Rails client and worker for [Anway](https://github.com/thadeu/anway). Ruby 3.4 or later. Rails 8.1 for the Rails integration.

```ruby
gem 'anway'
```

The server address comes from `ANWAY_URL`, for example `tcp://:password@localhost:7419`. Use `tcp+tls://` for TLS.

## Worker

```ruby
class WelcomeJob
  include Anway::Worker

  job_type 'email.send'
  job_options queue: 'mailers', retry: 5

  def perform(address)
    # ...
  end
end

WelcomeJob.perform_async('a@b.com')
WelcomeJob.perform_in(300, 'a@b.com')
WelcomeJob.set(queue: 'low').perform_async('a@b.com')
```

- `job_type` is optional. The default is the class name. Use a name when a worker in another language runs the job.
- `job_options` accepts `queue`, `retry`, `reserve_for`, `backtrace`, and `custom`, such as `custom: { unique_for: 600 }`.
- Args must be JSON types with string hash keys. Symbols, times, and objects raise `ArgumentError`.
- Delivery is at least once, so jobs must be idempotent.

To send a job that a worker in any language runs:

```ruby
Anway.push('image.resize', [42], queue: 'media')
```

## Rails

```ruby
config.active_job.queue_adapter = :anway
```

- Existing ActiveJob classes work. Each one runs in the Rails reloader.
- In a database transaction, a push waits for the commit, and a rollback cancels it. This also applies to `perform_async`.
- A job with `retry_on` keeps ActiveJob attempts, and its final error goes to the dead set.
- A job with no `retry_on` uses server retries.

Tasks in `recurring.yml` and jobs that wait in Solid Queue do not move automatically. Move recurring tasks to the server cron, and drain the old queue first.

## Process

```bash
bundle exec anway -q critical,mailers,default -c 10
```

| Flag | Default | Purpose |
|---|---|---|
| `-q`, `--queues` | Queues of the job classes, and `default` | Queues in order, as `name` or `name:weight` |
| `-c`, `--concurrency` | `10` | Job threads |
| `-t`, `--timeout` | `25` | Seconds for jobs to finish at a stop |
| `-r`, `--require` | `config/environment.rb` | File that loads the jobs. Required outside Rails. |
| `-C`, `--config` | `config/anway.yml` | YAML config file |
| `-e`, `--environment` | `RAILS_ENV`, `APP_ENV` | Environment section of the YAML file |
| `-l`, `--label` | None | Worker label |
| `-v`, `--verbose` | Off | Debug logs |
| `-V`, `--version` | | Print the version |

```yaml
concurrency: <%= ENV.fetch('WORKER_THREADS', 10) %>
timeout: 25
queues:
  - [critical, 4]
  - [mailers, 2]
  - [default, 1]

production:
  concurrency: 20
```

Flags have priority over the environment section, and the environment section has priority over top-level keys. A list without weights uses strict order.

| Signal | Effect |
|---|---|
| `TERM`, `INT` | Stop |
| `TSTP` | Quiet: stop fetching and stay alive |
| `TTIN` | Write thread data to the log |

Exit codes: `0` for a normal stop, `1` for a boot failure, `2` for a usage error.

At a stop, jobs get `--timeout` seconds to finish. Then `Anway::Shutdown` is raised in them, and they get 5 seconds to return. The process then fails jobs that still run and stops. Set the container stop timeout above 30 seconds.

Keep the database pool at the concurrency value or more. A job queue with no worker has no error, and its jobs wait.

## Tests in your app

```ruby
require 'anway/testing'

Anway::Testing.fake!
WelcomeJob.perform_async('a@b.com')
Anway::Testing.jobs.size
Anway::Testing.drain

Anway::Testing.inline!
```

## Client

`Anway::Client` has the operations of [anway-go](https://github.com/thadeu/anway-go), in snake_case. It is safe for threads and for forks.

```ruby
client = Anway::Client.new('tcp://localhost:7419')
client.push(Anway::Job.new('email.send', ['a@b.com']))
```

The error kinds are `Anway::NotUnique`, `Anway::Closed`, `Anway::ServerError`, and `Anway::ConnectionError`. A failed call does not resend.

## Configuration

```ruby
Anway.configure do |config|
  config.pool_size = 8
  config.timeout = 10
  config.tls = { ca_file: 'ca.pem' }
  config.use MyMiddleware.new
  config.on_error { |error, job| report(error, job) }
end
```

Middleware has `call(job)` and yields. The first one added is the outermost.

## Tests

```bash
SERVER_BIN=/path/to/anway bundle exec rspec
```

The specs map to the [conformance scenarios](https://github.com/thadeu/anway/blob/main/conformance/scenarios.md).

## License

MIT
