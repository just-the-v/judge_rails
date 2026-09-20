# jev-in-rails

**Semantic judgments as ordinary ActiveRecord attributes.**

[TypeSafe Jev](https://docs.typesafe.ai) answers typed questions about text and returns a calibrated
probability. This gem turns that into a column on your model: indexable, sortable, paginable, and kept
up to date for you. It also works as a plain Ruby client with no Rails and no dependencies outside the
standard library.

```ruby
class Ticket < ApplicationRecord
  jev_source { [subject, body] }

  jev_attribute :urgency,     Jev.noul("Does this need a human within the hour?")
  jev_attribute :intent,      Jev.choice("What is this about?", %w[billing technical sales])
  jev_attribute :frustration, Jev.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
end

Ticket.urgency_above(0.8).intent_is("billing").order(frustration: :desc).limit(20)
```

Three judgments cost one API call per record. That last line is one indexed SQL query and no API call at all.

## Features

**Questions**

- **Noul:** `Jev.noul("is this urgent?")` returns a calibrated probability, not a boolean
- **Choice:** `Jev.choice("which team?", %w[billing technical])` returns a winner plus the full distribution
- **Score:** `Jev.score("how urgent?", 1..5)` returns a continuous value, a rounded level and its label
- **Criteria:** every question type accepts descriptions per option to sharpen the judgment
- **Self-fingerprinting:** each question carries a digest of its own type, wording and criteria

**Calls**

- **Batching:** `Jev.ask` sends many questions about one text in a single request
- **Shapes:** pass a Question, a plain String, an Array or a Hash; get a `Result` or a `ResultSet`
- **Results:** value, probability, confidence, full distribution, score legend, level and label
- **Decisions:** `result.decide(above:, below:)` returns `:yes`, `:no` or `:unsure`
- **Metadata:** resolved model version, input and output tokens, measured latency
- **Client:** `Net::HTTP`, one persistent connection per thread, keyed on URL and timeouts
- **Retries:** jittered exponential backoff on 429 and 5xx, honours `Retry-After`, never retries other 4xx
- **Errors:** `AuthenticationError`, `RateLimitError`, `InvalidRequestError`, `ServerError`, `TransportError`, `InvalidResponseError`, `ConfigurationError`
- **Zero dependencies:** stdlib only, and `net/http` is not loaded until you make a call

**Attributes**

- **Declaration:** `jev_attribute :urgency, Jev.noul("...")` on any ActiveRecord model
- **Shared source:** `jev_source { [subject, body] }` once per model, so every attribute travels in one call
- **Storage:** a real typed column named as you declared it, plus a `<name>_jev` jsonb provenance sidecar
- **Provenance:** probability, confidence, distribution, legend, model version, latency and both digests
- **Invalidation:** editing the source text or the question wording marks the attribute stale by itself
- **Readers:** `urgency_probability`, `urgency_confidence`, `urgency_computed_at`, `urgency_stale?`, `urgency_jev_meta`
- **Predicates:** a noul attribute gets `urgency?(0.8)` with a threshold
- **Bands:** `record.jev_decide(:urgency, above: 0.9, below: 0.1)`
- **Conditions:** `if_condition:` skips an attribute per record
- **Inspection:** `jev_stale?`, `jev_pending`, `jev_refresh`, `jev_refresh!`

**Timing**

- **Async by default:** `after_commit` enqueues, so a vendor outage degrades a column and never a save
- **Inline:** `sync: true` computes during the save, when you need the value in the same request
- **Queued:** `callbacks: :queue` batches ids, and `Jobs.batch { }` coalesces them into one job
- **Manual:** `callbacks: false`
- **No ActiveJob required:** an injectable enqueuer means the gem works without it
- **Nothing wasted:** a save that changes nothing relevant enqueues nothing
- **Backfill:** `Ticket.jev_refresh_all(batch_size: 100, resume: true)` with a per-run summary

**Queries**

- **Noul scopes:** `urgency_above`, `urgency_below`, `urgency_between`, `urgency_unknown`
- **Choice scopes:** `intent_is`, `intent_not`, `intent_unknown`, raising on an option you never declared
- **Score scopes:** `frustration_at_least`, `frustration_at_most`, `frustration_level`, by name or index
- **Ordering:** `order_by_urgency(:desc)`, or plain `order(urgency: :desc)` since it is a real column
- **Coverage:** `jev_computed`, `jev_uncomputed`
- **Exact bands:** the scopes partition the table exactly the way `jev_decide` does
- **Ad-hoc:** `jev_filter`, `jev_map` and `jev_sort` for questions you never declared
- **Cost guard:** `limit:` is mandatory on all three, because each row is one API call

**Validations**

- **Refute:** `validates :body, jev: { refute: "contains a phone number" }`
- **Assert:** `validates :body, jev: { assert: "is written in English", threshold: 0.8 }`
- **Failure policy:** `on_error: :pass` (default), `:fail` or `:raise`
- **Batching:** several jev validations on one attribute travel in a single call
- **Free:** a blank attribute costs no API call
- **Explanations:** `record.jev_validation_results` holds the judgment behind every verdict

**Rails plumbing**

- **Generators:** `rails g jev:install` and `rails g jev:attribute Ticket urgency:noul intent:choice`
- **Migrations:** `jev_attribute :tickets, :urgency, :noul`, and `t.jev_attribute :urgency, :noul` inside `create_table`
- **Reversible:** built from `add_column` and `add_index`, so it works inside `change`
- **Adapter aware:** `jsonb` plus a GIN index on PostgreSQL, `json` elsewhere

## Installation

```ruby
gem "jev-in-rails"
```

```sh
bin/rails generate jev:install
bin/rails generate jev:attribute Ticket urgency:noul intent:choice frustration:score
bin/rails db:migrate
```

Set `JEV_API_KEY` in the environment or under `jev.api_key` in Rails credentials.

## Start in the console

The ActiveRecord layer has no private path to the network. Everything the macro does, you can do by hand,
with the same objects.

```ruby
Jev.ask("this customer sounds angry", text: ticket.body)
# => #<Jev::Result :answer noul value=0.91 p=0.91>

Jev.ask({
  refund:   Jev.noul("mentions a refund"),
  intent:   Jev.choice("what is this about?", %w[complaint question praise]),
  severity: Jev.score("how severe", 1..5)
}, text: ticket.body)
# => #<Jev::ResultSet [:refund, :intent, :severity] model="jev-1.13.0" latency=0.14>
```

Three judgments, one round trip. The macro batches the same way.

## Reading a judgment

```ruby
ticket.urgency              # => 0.91   the calibrated probability
ticket.urgency?(0.8)        # => true
ticket.urgency_confidence   # => 0.88
ticket.urgency_computed_at  # => 2026-09-20 11:42:10 UTC
ticket.urgency_jev_meta     # the full provenance sidecar

ticket.intent               # => "billing"
ticket.frustration          # => 2.39
```

## Acting on the band

The calibrated probability is what you are paying for. Collapsing it to a boolean throws it away.

```ruby
case ticket.jev_decide(:urgency, above: 0.9, below: 0.1)
when :yes    then ticket.escalate!
when :no     then ticket.queue_normally!
when :unsure then ticket.assign_to_human!
end
```

## Invalidation

```ruby
ticket.jev_stale?   # => false
ticket.body = "actually, all sorted, thanks"
ticket.jev_stale?   # => true
ticket.jev_pending  # => [:urgency, :intent, :frustration]
```

Two things invalidate a judgment: the source text changing, and the question changing. The question
fingerprints itself, so editing the wording of a prompt marks every stored judgment stale without you
touching a version number.

## Filtering and sorting

Declared attributes are real columns, so this is plain indexed SQL.

```ruby
Ticket.urgency_above(0.8)
Ticket.intent_is("billing", "technical")
Ticket.frustration_at_least("Frustrated")
Ticket.order(urgency: :desc).limit(25).offset(25)
```

`_above` is `>=`, `_below` is `<=` and `_between` is the strict middle, so the three partition the table
exactly the way `jev_decide` does.

For a question you never declared, there is an ad-hoc path. It loads records, judges them and returns an
Array rather than a Relation, because the work has already happened.

```ruby
Ticket.where(channel: "chat").jev_filter("mentions a chargeback", limit: 500)
```

`limit:` is required. Without it an unbounded scan is one API call per row.

## When to compute

```ruby
jev_attribute :urgency, Jev.noul("...")                      # async after_commit, the default
jev_attribute :urgency, Jev.noul("..."), sync: true          # inline, in the save
jev_attribute :urgency, Jev.noul("..."), callbacks: :queue   # batched bulk job
jev_attribute :urgency, Jev.noul("..."), callbacks: false    # manual only
```

Async is the default on purpose. An HTTP call inside a save holds a pooled database connection for the
whole request, so a slow vendor exhausts the connection pool and takes down more than the feature.

```ruby
Ticket.jev_refresh_all(batch_size: 100)
Ticket.jev_refresh_all(resume: true)
```

## Validations

```ruby
validates :body, jev: { refute: "contains a phone number or email address" }
validates :body, jev: { assert: "is written in English", threshold: 0.8 }
validates :body, jev: { refute: "is spam", on_error: :fail }
```

A validation is synchronous by nature. `on_error` defaults to `:pass`, so a TypeSafe outage cannot stop
your users saving. **That default is wrong for moderation**: a check that blocks spam or personal data and
then fails open lets through exactly what it exists to catch. Use `on_error: :fail` there.

## Configuration

```ruby
Jev.configure do |config|
  config.api_key      = ENV["JEV_API_KEY"]
  config.model        = "jev-latest"
  config.timeout      = 10.0
  config.open_timeout = 5.0
  config.max_retries  = 2
  config.logger       = Rails.logger
end
```

## Without Rails

`require "jev"` gives you questions, results and the client, with no ActiveRecord and nothing outside the
standard library. `require "jev/rails"` adds the ActiveRecord layer.

## Demo

`jev-in-rails-demo` is a Rails app with 250 support tickets judged offline, a datatable built on these
scopes, and six pages explaining the escalation band, one-call batching, self-invalidation, per-request
keys, ad-hoc filtering and validation failure modes.

## Licence

MIT.
