# jev-in-rails

**Semantic judgments as ordinary ActiveRecord attributes.**

[TypeSafe Jev](https://docs.typesafe.ai) answers typed questions about text and returns a calibrated
probability. This gem turns that into a column on your model: indexable, sortable, paginable, and kept up
to date for you. It is also a plain Ruby client, with no Rails and nothing outside the standard library.

```ruby
class Ticket < ApplicationRecord
  jev_source { [subject, body] }

  jev_attribute :urgency,     Jev.noul("Does this need a human within the hour?")
  jev_attribute :intent,      Jev.choice("What is this about?", %w[billing technical sales])
  jev_attribute :frustration, Jev.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
end

Ticket.urgency_above(0.8).intent_is("billing").order(frustration: :desc).limit(20)
```

Three judgments cost one API call per record. That query costs none.

## Install

```ruby
gem "jev-in-rails"
```

```sh
bin/rails generate jev:install
bin/rails generate jev:attribute Ticket urgency:noul intent:choice frustration:score
bin/rails db:migrate
```

Set `JEV_API_KEY` in the environment, or `jev.api_key` in Rails credentials.

## Questions

Three types. Each one is a frozen value object you can hold, pass around and compare.

```ruby
Jev.noul("Does this convey urgency?")
Jev.noul("Does this convey urgency?", { true: "Time-sensitive", false: "Can wait" })

Jev.choice("Which team?", %w[billing technical sales])
Jev.choice("Which team?", { billing: "Refunds, invoices", technical: "Bugs, outages" })

Jev.score("How frustrated?", ["Calm", "Mildly annoyed", "Frustrated", "Very angry"])
Jev.score("How urgent?", 1..5)
```

Criteria are optional on a noul and sharpen the judgment. A question fingerprints itself, which is what
makes invalidation automatic later.

```ruby
question = Jev.choice("Which team?", %w[billing technical sales spam])
question.digest    # => "9e08ebfeb6e0e0fa"   over type, wording and criteria
question.options   # => ["billing", "technical", "sales", "spam"]

Jev.score("How frustrated?", ["Calm", "Mildly annoyed", "Frustrated", "Very angry"]).max_level  # => 3
```

## Asking

One question in, one `Result` out. Many questions in, one `ResultSet` out, and one HTTP request.

```ruby
Jev.ask("does this sound angry?", text: ticket.body)
# => #<Jev::Result :answer noul value=0.96 p=0.96>

results = Jev.ask({
  urgency:     Jev.noul("Does this need a human within the hour?"),
  intent:      Jev.choice("What is this about?", %w[billing technical sales spam]),
  frustration: Jev.score("How frustrated?", ["Calm", "Mildly annoyed", "Frustrated", "Very angry"])
}, text: ticket.body)
# => #<Jev::ResultSet [:urgency, :intent, :frustration] model="jev-1.13.0" latency=0.69>
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

`jev_attribute` stores a judgment as a real column, plus a `<name>_jev` jsonb sidecar holding its
provenance. `jev_source` sets the text once, so every attribute sharing it travels in one call per record.

```ruby
class Ticket < ApplicationRecord
  jev_source { [subject, body] }

  jev_attribute :urgency,     Jev.noul("Does this need a human within the hour?")
  jev_attribute :intent,      Jev.choice("What is this about?", %w[billing technical sales spam])
  jev_attribute :frustration, Jev.score("How frustrated?", ["Calm", "Mildly annoyed", "Frustrated", "Very angry"])

  jev_attribute :spam, Jev.noul("Is this spam?"),
                source: :body,
                if_condition: ->(ticket) { ticket.channel == "web" }
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
ticket.urgency_jev_meta
# => {"digest" => ..., "state_digest" => ..., "computed_at" => ..., "probability" => 0.96,
#     "probabilities" => {...}, "model" => "jev-1.13.0", "latency" => 0.69}

ticket.jev_decide(:urgency, above: 0.9, below: 0.1)   # => :yes
```

## Invalidation

Two things make a judgment stale: the source text changing, and the question changing. Both are detected
by comparing digests, which costs no API call.

```ruby
ticket.jev_stale?    # => false
ticket.body = "actually, all sorted, thanks"
ticket.jev_stale?    # => true
ticket.jev_pending   # => [:urgency, :intent, :frustration]

ticket.jev_refresh   # recompute in memory, returns the names it touched
ticket.jev_refresh!  # recompute and save
ticket.jev_refresh(:urgency, force: true)
```

Editing the wording of a question moves its digest, so every stored judgment for it goes stale on its own.
There is no version number to remember to bump.

## When it runs

```ruby
jev_attribute :urgency, Jev.noul("...")                      # async after_commit (default)
jev_attribute :urgency, Jev.noul("..."), sync: true          # inline, during the save
jev_attribute :urgency, Jev.noul("..."), callbacks: :queue   # batched bulk job
jev_attribute :urgency, Jev.noul("..."), callbacks: false    # manual only
```

Async is the default on purpose. An HTTP call inside a save holds a pooled database connection for the
whole request, so a slow vendor exhausts the pool and takes down more than the feature. A save that
changes nothing relevant enqueues nothing, and ActiveJob is optional: the enqueuer is injectable.

```ruby
Jev::Rails::Jobs.batch do        # coalesce :queue attributes into one job
  tickets.each(&:save!)
end

ticket.jev_refresh_later(:urgency)

summary = Ticket.jev_refresh_all(batch_size: 100, resume: true)
summary.to_h   # => {records: 250, computed: 250, skipped: 0, failed: 0, calls: 250}
```

Only `sync: true` attributes can honour `on_error`, since anything else has already committed. Declaring
`on_error` on an async attribute raises at load time rather than doing nothing.

```ruby
jev_attribute :urgency, Jev.noul("..."), sync: true, on_error: :pass   # default, save goes through
jev_attribute :urgency, Jev.noul("..."), sync: true, on_error: :fail   # save is blocked
jev_attribute :urgency, Jev.noul("..."), sync: true, on_error: :raise  # error propagates
```

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
Ticket.frustration_level(2)

Ticket.order_by_urgency(:desc)                 # or plain order(urgency: :desc)
Ticket.jev_computed
Ticket.jev_uncomputed
```

The bands partition the table exactly the way `jev_decide` does, so SQL and Ruby never disagree at the
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
Ticket.where(channel: "chat").jev_filter("mentions a chargeback", limit: 500)   # => [Ticket, ...]
Ticket.jev_map("how angry is this?", limit: 200)                                # => {ticket => Result}
Ticket.jev_sort("most likely to churn", limit: 200, dir: :desc)                 # => [Ticket, ...]

Ticket.jev_filter("mentions a chargeback")
# ArgumentError: jev_filter requires limit:. It makes one API call per row.
```

## Validations

An ordinary ActiveModel validation that happens to ask a model.

```ruby
class Ticket < ApplicationRecord
  validates :body, jev: { refute: "contains a phone number or email address" }
  validates :body, jev: { assert: "is written in English", threshold: 0.8, message: "must be in English" }
  validates :body, jev: { refute: "is spam", on_error: :fail }, if: -> { channel == "web" }
end

ticket.valid?
ticket.errors.full_messages            # => ["Body matched \"contains a phone number or email address\""]
ticket.jev_validation_results          # the judgment behind each verdict, never persisted
```

Several jev validations on the same attribute travel in one call. A blank attribute costs nothing.

`on_error` defaults to `:pass`, so a TypeSafe outage cannot stop your users saving. **That default is
wrong for moderation**: a check that blocks spam or personal data and then fails open lets through
exactly what it exists to catch. Use `on_error: :fail` there.

## Migrations and generators

```ruby
class AddJevToTickets < ActiveRecord::Migration[8.0]
  def change
    jev_attribute :tickets, :urgency, :noul      # float + urgency_jev + indexes
    jev_attribute :tickets, :intent, :choice     # string + intent_jev
    jev_attribute :tickets, :frustration, :score # float + frustration_jev
  end
end

create_table :tickets do |t|
  t.jev_attribute :urgency, :noul
end
```

Built from `add_column` and `add_index`, so it is reversible inside `change`. The sidecar is `jsonb` with
a GIN index on PostgreSQL and `json` elsewhere, chosen from the connection actually running the migration.

```sh
bin/rails generate jev:install
bin/rails generate jev:attribute Ticket urgency:noul intent:choice frustration:score
```

## Client and errors

```ruby
Jev.configure do |config|
  config.api_key      = ENV["JEV_API_KEY"]   # or TYPESAFE_API_KEY
  config.model        = "jev-latest"
  config.timeout      = 10.0
  config.open_timeout = 5.0
  config.max_retries  = 2
  config.logger       = Rails.logger
end
```

`Net::HTTP`, one persistent connection per thread keyed on URL and timeouts, jittered exponential backoff
on 429 and 5xx, `Retry-After` honoured, no retry on any other 4xx. Nothing about the key or the payload is
ever logged.

```ruby
Jev::Error
├── Jev::ConfigurationError    # no usable key
├── Jev::TransportError        # timeout, reset, DNS
├── Jev::InvalidResponseError  # body was not what the API promises
└── Jev::APIError              # carries #status and #body
    ├── Jev::AuthenticationError  # 401, 403
    ├── Jev::InvalidRequestError  # 400, 404, 422
    ├── Jev::RateLimitError       # 429, carries #retry_after
    └── Jev::ServerError          # 5xx
```

A per-request client, for a key you do not want to keep:

```ruby
config = Jev::Configuration.new
config.api_key = params[:api_key]
Jev.ask(questions, text: text, client: Jev::Client.new(config: config))
```

## Without Rails

```ruby
require "jev"        # questions, results, client. No ActiveRecord, nothing outside stdlib
require "jev/rails"  # the ActiveRecord layer
```

`net/http` is not loaded until you make a call.

## Demo

`jev-in-rails-demo` is a Rails app with 250 support tickets judged offline, a datatable built on these
scopes, and six pages explaining the escalation band, one-call batching, self-invalidation, per-request
keys, ad-hoc filtering and validation failure modes.

## Licence

MIT.
