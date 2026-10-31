# Project Instructions

Ruby and Rails client and worker for the Anway job server. The gem is `anway`. Read `README.md` first.

The contract comes from other repositories:

- Client rules and shutdown: `docs/dev/clients.md` in `thadeu/anway`.
- Scenarios: `conformance/scenarios.md` in `thadeu/anway`.
- Operations: `README.md` in `thadeu/anway-go`, which sets the contract.

## Rules

- **Contract:** `Anway::Client` has the same operations, argument order, defaults, and error kinds as anway-go, in snake_case. `Anway::Worker` is the one exception. It is a job API above the client.
- **Versions:** Support Ruby 3.4 and later, and Rails 8.1. Do not add code for old versions.
- **Dependencies:** The only runtime dependency is `logger`. Discuss a new one before you add it.
- **Rails:** Rails and ActiveJob load only when they exist. Plain Ruby must work without them.
- **Security:** A job type never becomes a free constant lookup. Only registered classes run.
- **Args:** Job args are JSON types with string hash keys, because other languages read them.
- **Forks:** A forked process never uses a parent socket.
- **Signals:** Signal handlers only write to the pipe. All work runs outside trap context.
- **Shutdown:** `Anway::Shutdown` is raised only inside `perform`. A fetch in progress is not canceled.
- **Retries:** The server owns retries. A job with `retry_on` sends `retry: -1`, not `retry: 0`, because `0` discards the job.
- **ActiveJob ids:** Each push has a new `jid`, because a `retry_on` attempt keeps its `job_id`.

## Tests

```bash
SERVER_BIN=/path/to/anway bundle exec rspec
```

- Run the suite on Ruby 3.4 and 4.0 before a release.
- Specs run against a real server. Each scenario ID maps to one spec.
- Test CLI and Rails changes with the real process, as in `spec/cli_spec.rb` and `spec/rails_spec.rb`.
- A new protection needs a spec that fails when you remove the protection.
- No lint or Brakeman in CI. CI runs tests only.

## Release

1. Change `lib/anway/version.rb`.
2. Push to `main`, and wait for green CI.
3. Push a `vX.Y.Z` tag. `release.yml` tests and publishes with trusted publishing.

A failed test stops the publish. A published version number cannot be used again.

## Code style

- Use one blank line between blocks with different responsibilities: before `if`, `unless`, `case`, `while`, `begin`, and `return`, and after a block end when more statements follow.
- Keep lines that build the same value together.
- Use `frozen_string_literal` and single quotes.
