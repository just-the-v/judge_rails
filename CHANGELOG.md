# Changelog

## Unreleased

Initial release.

### Core (plain Ruby, no dependencies outside the standard library)

- `Jev::Question::Noul`, `Choice` and `Score` value objects. Frozen, comparable, serialisable to the
  wire format. Each fingerprints itself with a digest over its type, instructions and criteria.
- `Jev::Result` and `Jev::ResultSet`: typed answers carrying value, calibrated probability, confidence,
  the full distribution, the score legend, model version, token usage and latency.
- `Jev::Client`: `Net::HTTP` with a per-thread persistent connection, bearer auth, jittered exponential
  backoff on 429 and 5xx, `Retry-After` support, and a full error taxonomy.
- `Jev.ask` facade: a Question, a String, an Array or a Hash in; a `Result` or a `ResultSet` out.
  Many questions travel in one request.

### ActiveRecord layer (`require "jev/rails"`)

- `jev_attribute` declares a judgment as an ordinary column plus a `<name>_jev` provenance sidecar.
- `jev_source` sets the text once per model, so every attribute sharing it costs one API call per record.
- Automatic invalidation on either the source text or the question wording changing.
- Compute timing: `sync: true` inline, `:async` after_commit (default), `:queue` batched, or `false`.
- `jev_refresh_all` resumable backfill with a per-run summary.
- Generated scopes per attribute, plus `jev_filter` / `jev_map` / `jev_sort` for undeclared questions,
  with a mandatory `limit:`.
- `validates :body, jev: { refute: "..." }` with `on_error: :pass | :fail | :raise`.
- `jev:install` and `jev:attribute` generators, and a `jev_attribute` migration helper.
