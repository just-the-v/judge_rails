# Changelog

## 0.0.1 (unreleased)

The first version under this name, not published yet. It will ship as 0.0.1 rather than 1.0.0 on
purpose: the surface is expected to move, and nothing here has a second user yet.

### Added

- **Structured criteria.** A Choice option or a Noul `true`/`false` entry can be a Hash or an Array,
  in the `{ what:, not_for:, examples: }` form TypeSafe documents. Keys become strings and keep their
  order, nested numbers and booleans keep their JSON type, nil entries are dropped, and two keys that
  collide once stringified raise. String criteria serialise and fingerprint exactly as before, so no
  existing judgment goes stale.
- **An adapter seam.** Everything now goes through one method, `call(state:, questions:, model:)
  -> Judge::ResultSet`. An adapter builds its answers with `Judge::Result.from_values`, which takes
  typed values, so no adapter reads or writes a wire format. `Judge::Adapter.register(:name) { ... }`
  adds one, `Judge.config.adapter` or `JUDGE_ADAPTER` picks it, and `adapter:` overrides it per call.
  The default stays `:jev`.
- `Judge::Result.from_values`, the typed entry point an adapter answers with.
- `Judge::Pool`, a standard-library thread pool. `judge_filter`, `judge_map` and `judge_sort` fan out across
  records through it, default 8, set with `concurrency:` or `Judge.config.concurrency`. Measured
  against the live API: 6.9x at 8 threads, 18.4x at 32, with the request unchanged and no judgment
  traded for the speed.
- `request.judge` instrumentation through `ActiveSupport::Notifications` when it is loaded. Carries
  model, question count, request size, latency and token counts. Never the state, never the key.
- `after_judge_refresh`, a model callback that runs once a refresh has stored new judgments.
- `option:` on `judge_filter` and `judge_sort` for a choice question, and `at_least:` on `judge_filter`
  for a score question.
- `config.max_retry_wait` (10 s, `nil` for no cap), and an adapter object accepted directly by
  `config.adapter`.
- `change_table` support for `t.judge_attribute`, and `--database` on `judge:attribute`.
- `ADVANCED.md` for `sync: true`, `on_error`, `if_condition`, `callbacks: false`, backfill and the
  injectable enqueuer, so the README keeps one path.
- `activerecord` and `activesupport` declared as runtime dependencies. They were required by
  `judge/rails` and declared nowhere, so bundler could not resolve them.

### Removed

- `callbacks: :queue` and `Judge::Rails::Jobs.batch`. They coalesced job dispatch, never requests: one
  demonstrated caller in the whole workspace, and it was a test. `judge_refresh_all` covers the same
  ground with no setup.
- `Judge::Rails::BulkRefreshJob` and the `kind` field on the job payload, which only that mode reached.
- `config.batch_rows`, which nothing read.
- The GIN index on a PostgreSQL sidecar. Nothing queried inside it, and it tripled the cost of a
  refresh write.
- `null: false` on the migration helper. A value column is empty until judged, so it now raises.

### Changed

- **Renamed from `jev-in-rails` to `judge_rails`**, before publishing rather than after. The macro
  prefix is `judge_`, the module is `Judge`, the sidecar column is `<name>_judge`, the generators are
  `judge:install` and `judge:attribute`, and the validator key is `judge:`. TypeSafe Jev keeps its
  name everywhere it is the subject: it is the default adapter, `:jev`, and the model string is still
  `jev-latest`, because a gem named for one provider while carrying adapters for others is harder to
  rename later than now.
- `client:` is `adapter:` everywhere, and `Judge.client` is `Judge.adapter`. One word for one concept.
- `required_ruby_version` is `>= 3.2.0`, which is what CI actually tests. It claimed 3.1 and never
  ran it.
- `judge_refresh!` and `judge_refresh_all` store judgments with `update_columns`. Validations and save
  callbacks no longer run, `updated_at` does not move, and other unsaved edits stay unsaved. A refresh
  no longer re-bills judge validations, and a row that fails validation still gets its judgment.
- `judge_filter` and `judge_sort` with a choice or score question raise without a target, before any
  call. They used to keep any row whose winning option was confident, whatever it was.
- Judge validation errors have types (`:judge_refuted`, `:judge_unmatched`, `:judge_unavailable`) and
  I18n messages, honour `strict:` and `except_on:`, and evaluate `if:` lambdas the way Rails does.
- A read timeout is not re-sent by the client: the server may already have billed it.
  `RefreshJob` still retries it.
- An async attribute with neither ActiveJob nor a custom enqueuer raises `Judge::ConfigurationError`
  on the first save instead of skipping the judgment.
- `Result#true?` on a non-noul answer raises `ArgumentError`, a caller error, instead of
  `InvalidResponseError`.
- Scopes are defined when the attribute is declared, not on first call.

### Fixed

- `gem "judge_rails"` now loads the gem. There was no `lib/judge_rails.rb`, so `Bundler.require` loaded
  nothing and the generated initializer crashed on boot.
- `judge:attribute` no longer crashes on every run. Its `create_migration` step shadowed the method
  `migration_template` calls.
- The generated initializer keeps a key already read from `JEV_API_KEY` or `TYPESAFE_API_KEY`.
- `judge_filter`, `judge_map` and `judge_sort` never raise a `limit` the relation already set, and skip
  records with blank text.
- Judge validations remember a judgment per text on the record, so a save that leaves the text alone
  costs nothing, and the prefetch runs after `before_validation` normalizers. A failed call is retried
  on the next pass. A plain `ActiveModel` object can be validated.
- TLS and protocol failures are `Judge::TransportError`, so `on_error: :pass` covers them.
- A `Retry-After` above `config.max_retry_wait` (10 s, `nil` for no cap) raises `RateLimitError`
  instead of sleeping.
- `RefreshJob` hands a 429, a 5xx, a transport error or a database deadlock back to ActiveJob, for up
  to five attempts with backoff. It used to report success and leave the record unjudged. It is
  defined once ActiveJob loads, so `queue_name_prefix` applies.
- `Judge::Pool` stops starting requests when the caller is interrupted and returns at once, closes
  each worker's HTTP connections, returns any database connection a worker leased, and gives workers
  the caller's log tags. Any exception, not only a `StandardError`, stops the queue.
- Blank source text is never sent. An automatic attribute clears on save, so it no longer enqueues a
  job on every save.
- A zero-argument `if_condition` lambda runs against the record instead of raising.
- `model:` on `judge_attribute` is sent. A pin change makes old judgments stale, and so does changing
  `config.model` for unpinned attributes.
- Changing `config.adapter` after the first call takes effect.
- A refresh never saves the record, so a source that changes on every save cannot feed a loop, and a
  second save inside one transaction is still enqueued.
- A keep-alive connection opened before a fork is never reused by the child, which used to read
  another process's answers.
- An answer missing its value, of the wrong type, or naming an option or level the question does not
  have raises `InvalidResponseError` inside `Judge.ask`, so `on_error:` and `rescue Judge::Error`
  cover it.
- An error body that is JSON but not an object (`null`, `[]`, `502`) maps to the right `APIError`, and a
  413 is `PayloadTooLargeError`.
- `judge_refresh_all` judges each STI row with its own class's attributes.
- A refresh that fails part way stores the judgments it already paid for.
- Saving a record loaded with a partial `select` skips the judgments it cannot read.
- A skipped judge validation no longer reads its attribute, `dup` gets its own judgment cache, and a
  frozen form object can be validated.
- `inspect` on a configuration or a client hides the API key, and a key read with surrounding
  whitespace is trimmed.
- On numeric score levels, an Integer passed to `_at_least`, `_at_most` or `_level` is the label.
- The sidecar migration works on MySQL, which rejects a default on a JSON column.

### Not added, on purpose

Subject batching, packing several records into one request the way `pg_judge` does. It was built,
measured against 250 committed judgments, and rejected: it costs 9 to 14 points of decision
agreement at every batch size, because Jev scores each question against the whole state.
`BENCHMARK.md` carries the protocol, which was written before the runs, and the numbers.

### What 0.0.1 contains

#### Core (plain Ruby, no dependencies outside the standard library)

- `Judge::Question::Noul`, `Choice` and `Score` value objects. Frozen, comparable, serialisable to the
  wire format. Each fingerprints itself with a digest over its type, instructions and criteria.
- `Judge::Result` and `Judge::ResultSet`: typed answers carrying value, calibrated probability, confidence,
  the full distribution, the score legend, model version, token usage and latency.
- `Judge::Client`: `Net::HTTP` with a per-fiber persistent connection, bearer auth, jittered exponential
  backoff on 429, 5xx and connection failures, `Retry-After` support, and a full error taxonomy.
- `Judge.ask` facade: a Question, a String, an Array or a Hash in; a `Result` or a `ResultSet` out.
  Many questions travel in one request.

#### ActiveRecord layer (`require "judge/rails"`)

- `judge_attribute` declares a judgment as an ordinary column plus a `<name>_judge` provenance sidecar.
- `judge_source` sets the text once per model, so every attribute sharing it costs one API call per record.
- Automatic invalidation on either the source text or the question wording changing.
- Compute timing: `sync: true` inline, `:async` after_commit (default), or `false`.
- `judge_refresh_all` resumable backfill with a per-run summary.
- Generated scopes per attribute, plus `judge_filter` / `judge_map` / `judge_sort` for undeclared questions,
  with a mandatory `limit:`.
- `validates :body, judge: { refute: "..." }` with `on_error: :pass | :fail | :raise`.
- `judge:install` and `judge:attribute` generators, and a `judge_attribute` migration helper.
