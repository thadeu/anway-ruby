<p>
  <a href="https://github.com/thadeu/anway">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thadeu/anway/main/brand/png/lockup-on-dark.png">
      <img src="https://raw.githubusercontent.com/thadeu/anway/main/brand/png/lockup-on-light.png" alt="Anway" width="320">
    </picture>
  </a>
</p>

# anway-ruby

Ruby and Rails client and worker for [Anway](https://github.com/thadeu/anway). Ruby 3.4 or later. Rails 8.1 for the Rails integration.

## Install in Rails

```bash
bundle add anway
bin/rails generate anway:install
bin/dev
```

That is all: no Redis and no migrations. The gem for each platform carries the Anway server, and `bin/dev` starts it with Puma. Add `--active-job` to the installer to use Anway as the Active Job adapter. Without it, Active Job stays as it is, and `include Anway::Worker` works in any class.

The installer writes `config/anway.yml` and `bin/anway`, adds `plugin :anway` to `config/puma.rb`, and adds the console mount to `config/routes.rb` as a comment.

`anway-demo/shop` is a full example app.

## Server: embedded or apart

Without a `url`, the app runs the Anway server itself: the server is **embedded**. With `url` in `config/anway.yml`, or with `ANWAY_URL`, the app uses a server that runs apart, and it runs only workers. Use cases:

1. A Rails app is the server, and runs its own workers and workers from other apps and languages.
2. A Rails app runs only workers, and the server runs apart.

```yaml
# config/anway.yml
queues: [default]
concurrency: 10

development:
  server:
    web: 127.0.0.1:7420     # optional: the HTTP API for the web console
    web_token: dev

production:
  url: <%= ENV["ANWAY_URL"] %>
```

| `server` key | Default | Purpose |
|---|---|---|
| `mode` | `embedded`, or `external` with a url | Set it only to override the url rule. `ANWAY_SERVER` also sets it. |
| `bind` | `127.0.0.1:7419` | Address of the embedded server. Use `0.0.0.0:7419` and a `password` for workers on other hosts. |
| `data` | `storage/anway` | Data folder of the embedded server |
| `password` | None | Server password |
| `web`, `web_token` | Off | HTTP API address and token, for the web console |

Run one server for each deployment. On more than one host, run `bin/anway server` once, or the `ghcr.io/thadeu/anway` image, and set `ANWAY_URL` on every host. Two embedded servers have two separate sets of queues.

`ANWAY_SERVER_PATH` names another server binary. The gem for the `ruby` platform has no server, so it needs `ANWAY_SERVER_PATH` or a url.

The server address comes from the settings, then from `ANWAY_URL`, for example `tcp://:password@localhost:7419`. Use `tcp+tls://` for TLS. `Anway.config.url` in an initializer overrides both.

## Console

```ruby
# config/routes.rb
authenticate :user, ->(user) { user.admin? } do
  mount Anway::Web => "/anway"
end
```

```yaml
# config/anway.yml
console:
  path: /path/to/anway-webui
```

`console.path`, or `ANWAY_CONSOLE_PATH`, names the console binary. `bin/anway`, and so the Puma plugin, then starts the console next to the server, on `127.0.0.1:7421`. With an embedded server, it also opens the server API on `127.0.0.1:7420`, with a random token that only these two processes know.

`Anway::Web` proxies the mount path to the console:

- It keeps the session cookie and `Authorization` in the app.
- It sends the mount path in `X-Forwarded-Prefix`, so the console links and redirects stay under it.
- The console accepts form posts only from its own pages, so a form on another site cannot change jobs with an admin's session.

| `console` key | Default | Purpose |
|---|---|---|
| `path` | None | Console binary. Without it, no console starts. |
| `bind` | `127.0.0.1:7421` | Console address, and where `Anway::Web` finds it |
| `api` | The API of the embedded server | Server API that the console reads, for a server that runs apart |
| `token` | The server `web_token` | Token for that API |

`bin/anway console` runs only the console. Mount `Anway::Web` only in a route that checks the user: the console can kill and delete jobs.

## Worker

```ruby
class WelcomeJob
  include Anway::Worker

  anway_options event: 'email.welcome', retry: 5
  anway_options topics: %w[user.created], queue: 'mailers'

  def perform(user_id)
    # ...
  end
end

WelcomeJob.perform_async(1)
WelcomeJob.perform_in(300, 1)
WelcomeJob.set(queue: 'low', unique_for: 60).perform_async(1)
```

- `anway_options` declares the options of the class. You can call it more than once. An unknown key raises `ArgumentError`.
- `event` is the name of what the job handles. It goes to the server as the job type. The default is the class name. Use a name when a worker in another language runs the job.
- Two classes with the same event raise `ArgumentError`. A worker has one class for each event.
- A subclass inherits all options except `event` and `topics`.
- `set` changes the options for one push. It takes the push keys below.
- Args must be JSON types with string hash keys. Symbols, times, and objects raise `ArgumentError`.
- Delivery is at least once, so jobs must be idempotent.

### Options

All Anway clients use the same keys. The gem translates them to the fields of the protocol.

| Key | Sent as | Note |
|---|---|---|
| `event` | `jobtype` | The default is the class name. Only in `anway_options`. |
| `queue` | `queue` | The default is `default`. |
| `retry` | `retry` | The server default is 25. `0` discards the job at the first failure. `-1` sends it to the Dead set at once. |
| `reserve_for` | `reserve_for` | Seconds. |
| `backtrace` | `backtrace` | Lines. The default for a class is 30. |
| `at` | `at` | A time to run later. Only for a push. |
| `unique_for` | `custom.unique_for` | Seconds. |
| `unique_until` | `custom.unique_until` | `success` or `start`. |
| `expires_in` | `custom.expires_in` | Seconds. |
| `expires_at` | `custom.expires_at` | A time. The gem sends it as RFC 3339. |
| `track` | `custom.track` | `true` sends `1`. |
| `on_dead` | `custom.on_dead` | `{ event:, queue: }`. When the job dies, the server pushes a job of this event. |
| `custom` | `custom` | The keys of your app. A key above wins over a key with the same name here. |
| `topics` | One `SUBSCRIBE` for each topic | Only in `anway_options`. See [Topics](#topics). |

When a class has more than one option set, the sets merge in call order:

- A single value, such as `queue` or `retry`: the last set that has it wins.
- `topics`: the topics of all sets add up, in order, with no duplicates.
- `custom`: the hashes merge, and a later key wins.

`set` merges with the options of the class by the same rules. `WelcomeJob.anway_options`, with no keys, returns the merged options.

To send a job that a worker in any language runs, give the event and the same push keys:

```ruby
Anway.push('image.resize', [42], queue: 'media', expires_in: 600)
Anway::Job.new('email.welcome', [1], unique_for: 60, queue: 'low')
```

## Bulk push

A bulk push sends many jobs with one `PUSHB` command, and the server puts them in with one write. Use it to push a large list of jobs fast. Bulk push needs server v0.3.2 or later.

```ruby
WelcomeJob.perform_bulk([[1], [2], [3]])
# => {}

WelcomeJob.set(queue: 'low', at: Time.now + 300).perform_bulk(users.map { |user| [user.id] })

Anway.push_bulk([Anway::Job.new('image.resize', [1]), Anway::Job.new('image.resize', [2])])
```

- Each item of `perform_bulk` is the args of one job. The jobs get the options of the class and of `set`, as `perform_async` does.
- The result is a hash with the reason for each job that the server refused, by jid. When all jobs are in, it is `{}`.
- A refused job, such as a duplicate jid or a job that a unique lock blocks, does not stop the other jobs.
- One `PUSHB` takes at most 1,000 jobs. `perform_bulk` and `Anway.push_bulk` split a longer list into several `PUSHB` commands, and merge the failures.
- The gem builds all jobs before the first send. An item that is not valid raises `ArgumentError`, and no job goes to the server.
- In a database transaction, the push waits for the commit, and the result is `nil`. A rollback cancels the push.
- A list of more than 1,000 jobs uses more than one `PUSHB`. If a connection error occurs after the first `PUSHB`, the jobs of the earlier commands stay in, and the gem does not send them again.

`client.push_bulk(jobs)` sends one `PUSHB`. It takes at most 1,000 jobs, and more raise `ArgumentError` before the send.

## Topics

A topic sends one event to many queues. Each subscription of the topic gets one copy of the event, as a normal job in its own queue. Topics need server v0.3.0 or later.

```ruby
class BroadcastMessage
  include Anway::Worker

  anway_options topics: %w[chat.message], queue: 'realtime'

  def perform(message)
    # ...
  end
end

Anway.publish('chat.message', [{ 'room' => 'general', 'body' => 'hi' }], id: 'msg-42')
# => #<data Anway::Client::Published event="msg-42", jobs=3, duplicate=false>
```

- Each topic in `topics` makes one subscription. The copies have the `event` of the class as their job type, and the `queue`, `retry`, and `reserve_for` of the class.
- The worker sends `SUBSCRIBE` for each subscription when it starts, before its first fetch. Without a queue list, it also fetches the subscription queues. With a list, it logs a warning for a subscription queue that is not in the list.
- With an `id`, a second publish of the same id within `unique_for` seconds (default one day) makes no job, and the reply has `duplicate: true`.
- The server adds `topic` and `event` to `custom` of each copy. Use `job.custom['event']` to make the handler idempotent.
- An event with no subscription goes to the Dead set, and the reply has `jobs: 0`.

The client has the same commands:

```ruby
client.publish('chat.message', [{ 'body' => 'hi' }], id: 'msg-42', unique_for: 3600, custom: { 'source' => 'web' })
client.subscribe('chat.message', queue: 'realtime', event: 'BroadcastMessage', retry: 3, reserve_for: 60)
client.unsubscribe('chat.message', queue: 'realtime', event: 'BroadcastMessage')
```

### Bulk publish

`Anway.publish_bulk` sends many events with one `PUBLISHB` for each 1,000 events. The server saves all copies of the events of one `PUBLISHB` in one write, so an import, an outbox relay, or a replay is much faster than one `publish` for each event. Use `publish` for one event, such as in a request.

```ruby
results = Anway.publish_bulk(orders.map { |order| { topic: 'order.paid', args: [order.id], id: "order-#{order.id}" } })

results.reject { |result| result.error.nil? }.each { |result| Rails.logger.warn("event #{result.event}: #{result.error}") }
```

- Each event is a hash with `topic:` and `args:`, and the options of `publish`: `id:`, `unique_for:`, and `custom:`.
- The results are `Anway::Client::PublishResult` values (`event`, `jobs`, `duplicate`, `error`), in the order of the events. A refused event, such as a bad topic, has `error` and does not stop the others.
- `client.publish_bulk(events)` sends one `PUBLISHB`. It takes at most 1,000 events, and more raise `ArgumentError` before the send. A bulk can make at most 10,000 jobs over all subscriptions.

[docs/topics.md](docs/topics.md) explains the chat example with three apps, the options, the tests, and problems.

## Rails

```ruby
config.active_job.queue_adapter = :anway
```

- Existing ActiveJob classes work. Each one runs in the Rails reloader.
- In a database transaction, a push waits for the commit, and a rollback cancels it. This also applies to `perform_async`.
- A job with `retry_on` keeps ActiveJob attempts, and its final error goes to the dead set.
- A job with no `retry_on` uses server retries.
- `ActiveJob.perform_all_later(jobs)` sends one `PUSHB` for each 1,000 jobs, for jobs of all classes and queues. A job with `set(wait:)` or `set(wait_until:)` keeps its time. Each job gets `successfully_enqueued`, and a job that the server refused gets an `ActiveJob::EnqueueError` in `enqueue_error`.

Tasks in `recurring.yml` and jobs that wait in Solid Queue do not move automatically. Move recurring tasks to the server cron, and drain the old queue first.

## Process

```bash
bundle exec anway                       # the embedded server when there is no url, and workers
bundle exec anway server                # only the server
bundle exec anway console               # only the console
bundle exec anway worker -q mailers     # only workers
bundle exec anway -C config/anway.yml -q critical,mailers,default -c 10
```

### Puma

`plugin :anway` in `config/puma.rb` runs `bin/anway` next to Puma, and stops it with Puma. `ANWAY_IN_PUMA` turns it on or off, as `SOLID_QUEUE_IN_PUMA` does. Without it, the plugin runs only in development. If `bin/anway` stops by itself, Puma stops too, so a broken worker is not hidden.

The worker process sets `ANWAY_WORKER=1` before it loads the app.

With Solid Cable 4.1, a code reload in one job thread can deadlock with a broadcast from another job thread. To avoid it, turn off reloading in the worker process in development, and run `bin/rails restart` after a change to a job:

```ruby
# config/environments/development.rb
config.enable_reloading = ENV["ANWAY_WORKER"].blank?
```

| Flag | Default | Purpose |
|---|---|---|
| `-q`, `--queues` | Queues of the job classes and of their subscriptions, and `default` | Queues in order, as `name` or `name:weight` |
| `-c`, `--concurrency` | `10` | Job threads |
| `-t`, `--timeout` | `25` | Seconds for jobs to finish at a stop |
| `-r`, `--require` | `config/environment.rb` | File that loads the jobs. Required outside Rails. |
| `-C`, `--config` | `config/anway.yml` | YAML config file |
| `-e`, `--environment` | `RAILS_ENV`, `APP_ENV` | Environment section of the YAML file |
| `-l`, `--label` | None | Worker label |
| `-g`, `--tag` | The app folder | Name of the app in the console |
| `-a`, `--autoscale` | Off | Turn on autoscale, up to this many threads |
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

The console shows each worker process as `hostname:pid`, with its tag, queues, threads, and start time, as Sidekiq does. The hostname is the machine name, and the tag is the app folder (`shop` for `~/code/shop`). To change them:

```yaml
hostname: worker.1   # or ANWAY_HOSTNAME, for example from the container or dyno name
tag: shop            # or ANWAY_TAG, or --tag
```

`ANWAY_HOSTNAME` and `ANWAY_TAG` have priority over the file.

### Threads and autoscale

The console and the server API can change the threads of a running worker. With autoscale, the server adds threads while jobs wait and removes them when the load drops:

```yaml
concurrency: 10   # the start count, and the autoscale min
autoscale:
  max: 40
```

The worker never runs more threads than its ActiveRecord pool, so make the pool of the worker process as large as `max`. [docs/threads-and-autoscale.md](docs/threads-and-autoscale.md) explains the setup, the console, the API, and problems.

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
WelcomeJob.perform_async(1)
Anway::Testing.jobs.size
Anway::Testing.drain

Anway.publish('chat.message', [{ 'body' => 'hi' }])
Anway::Testing.events.last['topic']

Anway::Testing.inline!
```

In inline mode, `Anway.publish` runs one copy in each job class of the app that subscribes to the topic. `Anway.publish_bulk` works as one `Anway.publish` for each event.

`perform_bulk` and `Anway.push_bulk` work as single pushes do: fake mode adds each job to `Anway::Testing.jobs`, and inline mode runs each job. The result is `{}`.

## Client

`Anway::Client` has the operations of [anway-go](https://github.com/thadeu/anway-go), in snake_case. It is safe for threads and for forks.

```ruby
client = Anway::Client.new('tcp://localhost:7419')
client.push(Anway::Job.new('email.welcome', [1]))
client.push_bulk([Anway::Job.new('email.welcome', [2]), Anway::Job.new('email.welcome', [3])])
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
