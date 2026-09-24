# judge_rails

**Semantic judgments as ordinary ActiveRecord attributes.**

A judgment model answers typed questions about text and returns a calibrated probability. This gem
turns that into a column on your model: indexable, sortable, paginable, and kept up to date for you.
It is also a plain Ruby client, with no Rails and nothing outside the standard library.

It talks to [TypeSafe Jev](https://docs.typesafe.ai) out of the box, and to anything else through
one small seam if you ever need it.

```ruby
class Ticket < ApplicationRecord
  judge_source { [subject, body] }

  judge_attribute :urgency,     Judge.noul("Does this need a human within the hour?")
  judge_attribute :intent,      Judge.choice("What is this about?", %w[billing technical sales])
  judge_attribute :frustration, Judge.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
end

Ticket.urgency_above(0.8).intent_is("billing").order(frustration: :desc).limit(20)
```

Three judgments cost one API call per record. That query costs none.

## Install

```ruby
gem "judge_rails"
```

```sh
bin/rails generate judge:install
bin/rails generate judge:attribute Ticket urgency:noul intent:choice frustration:score
bin/rails db:migrate
```

Set `JEV_API_KEY` in the environment, or `judge.api_key` in Rails credentials. `TYPESAFE_API_KEY`
works too.

**That is the whole setup.** There is nothing to choose and nothing to wire: the default adapter is
TypeSafe Jev, and it is used unless you say otherwise. [Providers](#providers) is there if you ever
need something else, and you can ignore it until then.

### Two things worth knowing first

**A key is not automatic.** TypeSafe Jev is reached through an early-access waitlist, so
`bundle install` will not by itself get you a working gem. You can still evaluate the idea today:
`judge_rails_demo` boots with **250 support tickets already judged**, seeded from a committed file,
and needs no key at all.

```sh
bin/rails db:prepare db:seed   # 250 judged tickets, no API call
bin/rails server
```

**Pin `json` below 3 if you are on activesupport 8.1.** It calls `::JSON.parse(json, options)` with a
positional hash, which json 3.x rejects. It only surfaces on a jsonb column with a non-nil default,
which is exactly what the sidecar is, so it looks like a bug in this gem and is not:

```ruby
gem "json", "< 3"
```

## Questions

Three types. Each one is a frozen value object you can hold, pass around and compare.

```ruby
Judge.noul("Does this convey urgency?")
Judge.noul("Does this convey urgency?", { true: "Time-sensitive", false: "Can wait" })

Judge.choice("Which team?", %w[billing technical sales])
Judge.choice("Which team?", { billing: "Refunds, invoices", technical: "Bugs, outages" })

Judge.score("How frustrated?", ["Calm", "Mildly annoyed", "Frustrated", "Very angry"])
Judge.score("How urgent?", 1..5)
```

Criteria are optional on a noul and sharpen the judgment. An entry can also be an object, the form
TypeSafe documents for drawing a boundary between options:

```ruby
Judge.choice("Which team?", {
  billing:   { what: "Refunds, invoices", not_for: "Bugs", examples: ["I was charged twice"] },
  technical: { what: "Bugs, outages", not_for: "Charges or refunds", examples: ["The API returns 500"] }
})
Judge.noul("Does this need a human within the hour?", {
  true:  { what: "Money is stuck or a service is down", examples: ["Checkout has failed for an hour"] },
  false: { what: "Anything that can wait until tomorrow", examples: ["How do I export invoices?"] }
})
```

Worth doing wherever two options can be confused. On the demo's 250 tickets this raised agreement with
reference labels by about four points on both questions, for about 290 more input tokens per ticket,
which is a thousandth of a cent. The demo now declares its questions this way. The labels come from
two model annotators, not from people. `BENCHMARK.md` (in French), arm 8, has the numbers and their
limits.

A question fingerprints itself, which is what makes invalidation automatic later.

```ruby
question = Judge.choice("Which team?", %w[billing technical sales spam])
question.digest    # => "1c3be3cf24579b81"   over type, wording and criteria
question.options   # => ["billing", "technical", "sales", "spam"]

Judge.score("How frustrated?", ["Calm", "Mildly annoyed", "Frustrated", "Very angry"]).max_level  # => 3
```

## Asking

One question in, one `Result` out. Many questions in, one `ResultSet` out, and one HTTP request.

```ruby
Judge.ask("does this sound angry?", text: ticket.body)
# => #<Judge::Result :answer noul value=0.96 p=0.96>

results = Judge.ask({
  urgency:     Judge.noul("Does this need a human within the hour?"),
  intent:      Judge.choice("What is this about?", %w[billing technical sales spam]),
  frustration: Judge.score("How frustrated?", ["Calm", "Mildly annoyed", "Frustrated", "Very angry"])
}, text: ticket.body)
# => #<Judge::ResultSet [:urgency, :intent, :frustration] model="jev-1.13.0" latency=0.69>
```

A bare String is treated as a noul. An Array works too, named by each question or positionally.

## Reading a result

```ruby
results[:urgency].value          # => 0.96    a noul is its own probability
results[:urgency].true?(0.8)     # => true

results[:intent].value           # => "technical"
results[:intent].confidence      # => 1.0
results[:intent].probabilities   # => {"technical" => 1.0, "billing" => 0.0, ...}
results[:intent].probability_of(:billing)

results[:frustration].value      # => 2.01    continuous
results[:frustration].level      # => 2       rounded
results[:frustration].label      # => "Frustrated"

results.model                    # => "jev-1.13.0"
results.usage.input_tokens       # => 430
results.usage.total              # => 503
results.latency                  # => 0.69
```

The calibrated probability is what you are paying for, so act on the band rather than a boolean.

```ruby
case results[:urgency].decide(above: 0.9, below: 0.1)
when :yes    then escalate!
when :no     then queue_normally!
when :unsure then assign_to_human!
end
```

## Attributes

`judge_attribute` stores a judgment as a real column, plus a `<name>_judge` jsonb sidecar holding its
provenance. `judge_source` sets the text once, so every attribute sharing it travels in one call per record.

```ruby
class Ticket < ApplicationRecord
  judge_source { [subject, body] }

  judge_attribute :urgency,     Judge.noul("Does this need a human within the hour?")
  judge_attribute :intent,      Judge.choice("What is this about?", %w[billing technical sales spam])
  judge_attribute :frustration, Judge.score("How frustrated?", ["Calm", "Mildly annoyed", "Frustrated", "Very angry"])

  judge_attribute :spam, Judge.noul("Is this spam?"), source: :body
end
```

Every attribute gets readers for its value and its provenance. A noul also gets a threshold predicate.

```ruby
ticket.urgency              # => 0.96
ticket.urgency?(0.8)        # => true
ticket.urgency_probability  # => 0.96
ticket.intent_confidence    # => 1.0
ticket.urgency_computed_at  # => 2026-09-20 11:42:10 UTC
ticket.urgency_stale?       # => false
ticket.urgency_judge_meta
# => {"digest" => ..., "state_digest" => ..., "computed_at" => ..., "probability" => 0.96,
#     "probabilities" => {...}, "model" => "jev-1.13.0", "latency" => 0.69}

ticket.judge_decide(:urgency, above: 0.9, below: 0.1)   # => :yes
```

## Invalidation

Two things make a judgment stale: the source text changing, and the question changing. Both are detected
by comparing digests, which costs no API call.

```ruby
ticket.judge_stale?    # => false
ticket.body = "actually, all sorted, thanks"
ticket.judge_stale?    # => true
ticket.judge_pending   # => [:urgency, :intent, :frustration, :spam]

ticket.judge_refresh                         # recompute in memory, returns the names it touched
ticket.judge_refresh!                        # or recompute and store the judgment columns
ticket.judge_refresh(:urgency, force: true)  # or one attribute, even if it is fresh
```

`judge_refresh!` writes only the judgment columns and `updated_at`, with `update_columns`: no
validations and no save callbacks, so a refresh cannot trigger another one, and fragment caches keyed
on the record's version see the new judgment. Other unsaved edits on the record stay unsaved. If the
row was deleted meanwhile, it raises `ActiveRecord::RecordNotFound`.

On a record that was never saved, `judge_refresh!` creates it. If one of its requests fails, the row is
still created from the answers already paid for, without asking again, and then the error is raised.
Reload before retrying, or the retry creates a second row. To react to a
new judgment, for a broadcast say, use `after_judge_refresh`:

```ruby
after_judge_refresh { broadcast_replace_later_to :tickets }
```

Editing the wording of a question moves its digest, so every stored judgment for it goes stale on its own.
There is no version number to remember to bump.

Pinning a model does the same. Changing the pin makes every judgment made under the old one stale, and
two attributes on the same text but different models travel in two calls instead of one. An attribute
with no pin follows `config.model`, so changing that makes its judgments stale too.

```ruby
judge_attribute :urgency, Judge.noul("..."), model: "jev-1.13.0"   # the rest follow config.model
```

Blank source text has nothing to judge, and no call is made for it. An automatic attribute clears its
value and sidecar on save. A `callbacks: false` one shows as stale until `judge_refresh` clears it.

A source should depend only on content. One that reads `updated_at` or a column a callback rewrites
makes every ordinary save look like new text, and shows as stale right after its own refresh. The
refresh runs no callbacks, so it cannot feed a loop, but each of your saves will enqueue one more
judgment.

## When it runs

```ruby
judge_attribute :urgency, Judge.noul("...")                      # async after_commit (default)
judge_attribute :urgency, Judge.noul("..."), sync: true          # inline, during the save
judge_attribute :urgency, Judge.noul("..."), callbacks: false    # manual only
```

Async needs ActiveJob, or an enqueuer of your own (see [ADVANCED.md](ADVANCED.md)). Without either, the
first save raises `Judge::ConfigurationError` instead of silently skipping the judgment.

Async is the default on purpose. An HTTP call inside a save holds a pooled database connection for the
whole request, so a slow vendor exhausts the pool and takes down more than the feature. A save that
changes nothing relevant enqueues nothing, and ActiveJob is optional: the enqueuer is injectable.

```ruby
ticket.judge_refresh_later(:urgency)
```

`sync: true` buys one thing, the right to block a save when the judgment fails. That, `if_condition`
and bulk backfill are in [ADVANCED.md](ADVANCED.md).

## Querying

Judgments are real columns, so this is plain indexed SQL and no API call.

```ruby
Ticket.urgency_above(0.8)                      # >=
Ticket.urgency_below(0.2)                      # <=
Ticket.urgency_between(0.2, 0.8)               # the strict middle
Ticket.urgency_unknown                         # never judged

Ticket.intent_is("billing", "technical")
Ticket.intent_not("spam")                      # raises on an option you never declared

Ticket.frustration_at_least("Frustrated")      # by name
Ticket.frustration_at_most(1)                  # or by index
Ticket.frustration_level(2)                    # on numeric levels like 1..5, an Integer is the label

Ticket.order_by_urgency(:desc)                 # NULLs where your database puts them: first on PostgreSQL
Ticket.judge_computed
Ticket.judge_uncomputed
```

The bands partition the table exactly the way `judge_decide` does, so SQL and Ruby never disagree at the
threshold.

```ruby
Ticket.urgency_above(0.8).count +
  Ticket.urgency_between(0.2, 0.8).count +
  Ticket.urgency_below(0.2).count +
  Ticket.urgency_unknown.count == Ticket.count   # => true
```

For a question you never declared, there is an ad-hoc path. It loads records, judges them and returns an
Array rather than a Relation, because the work has already happened.

```ruby
Ticket.where(channel: "chat").judge_filter("mentions a chargeback", limit: 500)   # => [Ticket, ...]
Ticket.judge_map("how angry is this?", limit: 200)                                # => {ticket => Result}
Ticket.judge_sort("most likely to churn", limit: 200, dir: :desc)                 # => [Ticket, ...]

Ticket.judge_filter("mentions a chargeback")
# ArgumentError: judge_filter requires limit:. It makes one API call per row.
```

A choice or a score question needs a target, because "the answer is confident" says nothing about which
answer won. A missing target raises before any call is made.

```ruby
team = Judge.choice("Which team?", %w[billing technical sales])
Ticket.judge_filter(team, option: "billing", limit: 100)          # P(billing) >= threshold
Ticket.judge_sort(team, option: "billing", limit: 100)            # ranked by P(billing)

mood = Judge.score("How frustrated?", ["Calm", "Frustrated", "Very angry"])
Ticket.judge_filter(mood, at_least: "Frustrated", limit: 100)
```

Rows sharing the same text are asked once.

One row per request is not an accident, it is the only shape that keeps the judgment intact: Jev
scores each question against the whole state, so putting several records in one request makes every
answer a judgment about a mostly irrelevant document. Measured on 250 tickets, packing subjects cost
nine to fourteen points of decision agreement. `BENCHMARK.md` has the protocol and the numbers.

What is free is running those requests at the same time. The request is unchanged byte for byte, so
nothing is traded for the speed.

```ruby
Ticket.judge_filter("mentions a chargeback", limit: 500, concurrency: 16)
Judge.configure { |c| c.concurrency = 16 }   # or set the default once
```

Measured against the live API on 100 records: 6.9x faster at the default of 8 threads, 18.4x at 32,
with input tokens identical to the unit at every level.

TypeSafe documents a limit of 1,200 requests per minute and says it can change without notice. The
default of 8 threads runs at about 29 requests a second, above that limit. On 2026-09-23 one key
sustained 1,758 requests a minute at 8 threads and 6,696 at 32 without a single 429, but nothing
promises that tomorrow. A 429 is retried twice, honouring `Retry-After` up to `max_retry_wait`.

## Validations

An ordinary ActiveModel validation that happens to ask a model.

```ruby
class Ticket < ApplicationRecord
  validates :body, judge: { refute: "contains a phone number or email address" }
  validates :body, judge: { assert: "is written in English", threshold: 0.8, message: "must be in English" }
  validates :body, judge: { refute: "is spam", on_error: :fail }, if: -> { channel == "web" }
end

ticket.valid?
ticket.errors.full_messages            # => ["Body matched \"contains a phone number or email address\""]
ticket.judge_validation_results          # the judgment behind each verdict, never persisted
ticket.errors.of_kind?(:body, :judge_refuted)   # also :judge_unmatched, and :judge_unavailable on :fail
```

The messages are I18n keys under `errors.messages` (`judge_refuted`, `judge_unmatched`,
`judge_unavailable`), with the instruction as `%{instruction}`. A locale without them falls back to the
English text rather than "Translation missing". `strict:`, `on:`, `except_on:`, `if:` and
`unless:` behave as they do on any Rails validation.

Several judge validations on the same attribute travel in one call. A blank attribute costs nothing.
A record remembers the judgment of its current text, so saving it again without changing the text costs
nothing. The memory is per Ruby object: a record freshly loaded from the database pays one call per judge
validation on its first save. `if: :will_save_change_to_body?` avoids that when the text is all you check.
`reload` forgets it. A skipped `on_error: :pass` check is logged at warn level.

It works on a plain `ActiveModel::Model` form object too, one call per validation.

`on_error` defaults to `:pass`, so a TypeSafe outage cannot stop your users saving. **That default is
wrong for moderation**: a check that blocks spam or personal data and then fails open lets through
exactly what it exists to catch. Use `on_error: :fail` there.

## Migrations and generators

```ruby
class AddJudgeToTickets < ActiveRecord::Migration[8.0]
  def change
    judge_attribute :tickets, :urgency, :noul      # float + urgency_judge + an index on urgency
    judge_attribute :tickets, :intent, :choice     # string + intent_judge
    judge_attribute :tickets, :frustration, :score # float + frustration_judge
  end
end

create_table :tickets do |t|
  t.judge_attribute :urgency, :noul
end

change_table :tickets do |t|
  t.judge_attribute :intent, :choice
end
```

Built from `add_column` and `add_index`, so it is reversible inside `change`. The sidecar is `jsonb` with
no index on PostgreSQL and `json` elsewhere, chosen from the connection actually running the migration.
Nothing in the gem queries inside the sidecar, so an index there would only slow every write. The value
column always allows NULL: it is empty until judged, so `null: false` raises.
CI runs the suite on SQLite and MySQL, and the demo runs on PostgreSQL. MySQL rejects a default on a
JSON column, so there the sidecar is nullable with no default, and a nil sidecar reads as `{}`.

```sh
bin/rails generate judge:install
bin/rails generate judge:attribute Ticket urgency:noul intent:choice frustration:score
bin/rails generate judge:attribute Ticket spam:noul --database=secondary   # multi-database apps
```

The attribute generator writes live declarations with TODO questions, so replace the wording before the
first save: each save is judged, and billed, with whatever the question says. When the model has no
`judge_source`, it writes one from the table's `text` columns only, never its string columns, so a
`User` table does not send `encrypted_password` anywhere. With no `text` column it writes an empty one
that judges nothing until you fill it in. Later runs add their declarations below it, and `bin/rails destroy judge:attribute`
removes them.

## What it costs

A judged record is a billed network call. The gem's job is to make that number predictable.

| | |
|---|---|
| Per record, however many questions | **one** call. `judge_source` groups every attribute sharing a text |
| A save that changes nothing relevant | **zero** calls from `judge_attribute`: digests are compared first. A judge validation pays once per freshly loaded record |
| Any query over judged columns | **zero** calls. They are ordinary indexed columns |
| `judge_filter` / `judge_map` / `judge_sort` | **one call per row**, which is why `limit:` is mandatory |
| A request, before it carries anything | ~326 input tokens of fixed overhead |
| Each additional question in a request | ~24 input tokens |
| The demo's three questions, structured criteria, on a ~200-character ticket | ~825 input tokens, about 0.00003 USD |

Measured on 2026-09-21 and 2026-09-23 against the live model, at TypeSafe's published 0.042 USD per
million input tokens, output free; `BENCHMARK.md` carries the method. Those last two
lines are the whole argument for `judge_source`: three separate calls pay the overhead three times and
answer exactly the same thing.

Timeouts and retries are yours to set, and the defaults are deliberately short:

```ruby
Judge.configure do |config|
  config.timeout      = 10.0   # seconds, per request
  config.open_timeout = 5.0
  config.max_retries  = 2      # 429, 5xx and transport errors, jittered
  config.max_retry_wait = 10.0 # a longer Retry-After raises RateLimitError instead of sleeping
end
```

An async refresh that fails on a 429, a 5xx or a transport error raises out of `RefreshJob`, so
ActiveJob retries it with backoff, five attempts. Any other failure is logged and dropped.

Every request emits `request.judge` through `ActiveSupport::Notifications` when it is loaded, so an APM
sees them without any wiring:

```ruby
ActiveSupport::Notifications.subscribe("request.judge") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  event.payload   # => {model:, questions:, request_bytes:, latency:, input_tokens:, output_tokens:}
end
```

`model`, `questions` and `request_bytes` are always there. `latency` and the two token counts are
added once the response parses, so a **failed** request carries only the first three, plus the
`:exception` pair ActiveSupport adds itself. Read them with `dig`, not `fetch`.

One event spans the whole call, retries included, not one per HTTP attempt.

The event carries sizes and counts. It never carries the state or the key.

## Client and errors

```ruby
Judge.configure do |config|
  config.api_key      = "..."                # read from JEV_API_KEY or TYPESAFE_API_KEY by default
  config.model        = "jev-latest"
  config.timeout      = 10.0
  config.open_timeout = 5.0
  config.max_retries  = 2
  config.max_retry_wait = 10.0
  config.logger       = Rails.logger
end
```

`Net::HTTP`, one persistent connection per fiber keyed on URL and timeouts, never reused across a fork.
Jittered exponential backoff on 429, 5xx and connection failures, `Retry-After` honoured on 429 and 503 up
to `max_retry_wait`, no retry on any other 4xx. A read timeout is not re-sent, because the server may
already have judged (and billed) the request. Nothing about the key or the payload is ever logged, and
`inspect` on a configuration or a client hides the key.

```ruby
Judge::Error
├── Judge::ConfigurationError    # no usable key, or async attributes without a way to enqueue
├── Judge::TransportError        # timeout, reset, DNS, TLS
├── Judge::InvalidResponseError  # body or an answer was not what the API promises
└── Judge::APIError              # carries #status and #body
    ├── Judge::AuthenticationError  # 401, 403
    ├── Judge::InvalidRequestError  # 400, 404, 422
    ├── Judge::PayloadTooLargeError # 413
    ├── Judge::RateLimitError       # 429, carries #retry_after
    └── Judge::ServerError          # 5xx
```

A per-request client, for a key you do not want to keep:

```ruby
config = Judge::Configuration.new
config.api_key = params[:api_key]
Judge.ask(questions, text: text, adapter: Judge::Client.new(config: config))
```

## Providers

**Skip this unless you need it.** TypeSafe Jev is the default and needs no configuration: set a key
and everything above works. This section is the escape hatch.

Everything above goes through one seam. An adapter is any object answering a single method:

```ruby
call(state:, questions:, model:) -> Judge::ResultSet
```

`questions` is a Hash of `{name => Judge::Question}`. The adapter reaches a provider however it
likes and builds each answer from typed values, so **no adapter ever writes or reads a wire
format**:

```ruby
class LayaAdapter
  def call(state:, questions:, model: nil)
    answers = MyLayaService.judge(state, questions.transform_values(&:to_payload))

    results = questions.map do |name, question|
      answer = answers.fetch(name)
      Judge::Result.from_values(name: name, question: question, type: question.type,
                                value: answer.value, confidence: answer.confidence,
                                probabilities: answer.distribution, legend: answer.legend)
    end
    Judge::ResultSet.new(results, model: "laya-1")
  end
end

Judge::Adapter.register(:laya) { LayaAdapter.new }
Judge.configure { |c| c.adapter = :laya }
```

The default is `:jev` and stays `:jev` until you change it. `JUDGE_ADAPTER` picks one from the
environment, and `adapter:` overrides it for a single call, which is how the test suite installs a
recorder.

### You may not need an adapter at all

The portable thing is the protocol, not this registry. Anything already serving this shape works
with the default adapter and a changed `base_url`, with no code:

```
POST <base_url>
Authorization: Bearer <key>

{"state": "...",
 "model": "...",
 "questions": {"urgency": {"type": "noul", "instructions": "...", "criteria": {...}}}}
```

```json
{"model": "...",
 "answers": {"urgency": {"type": "noul", "noul": 0.96}},
 "usage": {"input_tokens": 430, "output_tokens": 73}}
```

`choice` answers carry `choice`, `confidence` and `probabilities`; `score` answers carry `score`,
`confidence`, `legend` and `probabilities`.

## Without Rails

```ruby
require "judge"        # questions, results, client, thread pool. Loads nothing from Rails
require "judge/rails"  # the ActiveRecord layer
```

`require "judge"` pulls in nothing but the standard library: no ActiveRecord, no ActiveSupport, and
`net/http` is not loaded until you make a call. The gemspec declares `activerecord` and
`activesupport` because `require "judge/rails"` needs them, which is the whole dependency list.

## Demo

`judge_rails_demo` is a Rails app with 250 support tickets judged offline, a datatable built on these
scopes, and six pages explaining the escalation band, one-call batching, self-invalidation, per-request
keys, ad-hoc filtering and validation failure modes.

## Licence

MIT.
