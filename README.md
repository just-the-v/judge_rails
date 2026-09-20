# jev-in-rails

Semantic judgments from [TypeSafe Jev](https://docs.typesafe.ai) as ordinary ActiveRecord attributes.

Jev answers typed questions about text and returns a calibrated probability. This gem turns that into
a column on your model: indexable, sortable, paginable, and kept up to date for you.

```ruby
class Ticket < ApplicationRecord
  jev_source { [subject, body] }

  jev_attribute :urgency,     Jev.noul("Does this need a human within the hour?")
  jev_attribute :intent,      Jev.choice("What is this about?", %w[billing technical sales])
  jev_attribute :frustration, Jev.score("How frustrated is the customer?", ["Calm", "Frustrated", "Very angry"])
end

Ticket.urgency_above(0.8).intent_is("billing").order_by_frustration.limit(20)
```

That last line is one indexed SQL query. No API call, no join, no waiting.

## Install

```ruby
gem "jev-in-rails"
```

```sh
bin/rails generate jev:install
bin/rails generate jev:attribute Ticket urgency:noul intent:choice frustration:score
bin/rails db:migrate
```

Set `JEV_API_KEY` in your environment or Rails credentials.

## The console comes first

Everything the macro does, you can do by hand. The ActiveRecord layer has no private path to the network,
which means the console is a first-class way to work.

```ruby
Jev.ask("this customer sounds angry", text: ticket.body)
# => #<Jev::Result :answer noul value=0.91 p=0.91>

Jev.choice("what is this about?", %w[billing technical sales], name: :intent)
Jev.score("how urgent", 1..5, name: :urgency)

Jev.ask([
  Jev.noul("mentions a refund", name: :refund),
  Jev.choice("intent", %w[complaint question praise], name: :intent),
  Jev.score("severity", 1..5, name: :severity)
], text: ticket.body)
# => #<Jev::ResultSet [:refund, :intent, :severity] model="jev-1.13.0" latency=0.14>
```

Three judgments, one round trip. The macro batches the same way: every attribute that shares a
`jev_source` travels in a single call per record.

## Four primitives, four things Rails already has

| Jev primitive | What it becomes | Column type |
|---|---|---|
| `Jev.noul` | a probability attribute + `record.urgency?(0.8)` | `float` |
| `Jev.choice` | a string attribute, effectively an enum | `string` |
| `Jev.score` | an ordinal attribute with `level` and `label` | `float` |
| `jev:` validation | an ordinary ActiveModel validation | none |

Each attribute stores its value in a column named exactly as you declared it, plus a `<name>_jev` jsonb
sidecar holding the provenance: probability, confidence, the full distribution, the model version,
latency, and the digests used for invalidation.

## Invalidation is automatic

```ruby
ticket.jev_stale?      # => false
ticket.body = "actually, all sorted, thanks"
ticket.jev_stale?      # => true
ticket.jev_pending     # => [:urgency, :intent, :frustration]
```

Two things invalidate a judgment: the source text changing, and the question changing. The question
fingerprints itself, so editing the wording of a prompt marks every stored judgment stale without you
touching a version number.

## Reading the judgment

```ruby
ticket.urgency              # => 0.91
ticket.urgency?(0.8)        # => true
ticket.urgency_probability  # => 0.91
ticket.intent_confidence    # => 0.88
ticket.urgency_computed_at  # => 2026-09-20 11:42:10 UTC
ticket.urgency_jev_meta     # the full sidecar
```

## Act on the band, not on a boolean

The calibrated probability is the point. Collapsing it to true/false throws away what you are paying for.

```ruby
case ticket.jev_decide(:urgency, above: 0.9, below: 0.1)
when :yes    then ticket.escalate!
when :no     then ticket.queue_normally!
when :unsure then ticket.assign_to_human!
end
```

## Filtering and sorting

Declared attributes give you real scopes over real columns.

```ruby
Ticket.urgency_above(0.8)
Ticket.intent_is("billing", "technical")
Ticket.frustration_at_least(2)
Ticket.order_by_urgency(:desc)
Ticket.jev_uncomputed
```

The boundaries line up with `jev_decide` on purpose: `_above(p)` is `>= p`, `_below(p)` is `<= p`, and
`_between(lo, hi)` is the strict middle. So these three partition the table exactly, and a row the SQL puts
in one band is the row Ruby puts in the same band.

```ruby
Ticket.urgency_above(0.8).count +
  Ticket.urgency_between(0.2, 0.8).count +
  Ticket.urgency_below(0.2).count == Ticket.where.not(urgency: nil).count
```

For a question you never declared, there is an ad-hoc path. It loads records, judges them, and returns an
Array rather than a Relation, because the work has already happened and pretending otherwise would be a lie.

```ruby
Ticket.where(channel: "chat").jev_filter("mentions a chargeback", limit: 500)
```

`limit:` is required. Without it an unbounded scan is one API call per row, and at roughly 39 cents per
thousand judgments a forgotten `limit` on a large table is an invoice, not a bug report.

## When to compute

```ruby
jev_attribute :urgency, Jev.noul("..."), sync: true          # inline, in the save
jev_attribute :urgency, Jev.noul("...")                      # async, after_commit (default)
jev_attribute :urgency, Jev.noul("..."), callbacks: :queue   # batched bulk job
jev_attribute :urgency, Jev.noul("..."), callbacks: false    # manual only
```

Async is the default on purpose. An HTTP call inside a save holds a pooled database connection for the
duration of the request, so a slow vendor exhausts the connection pool and takes down more than the
feature. Async means a Jev outage degrades a column.

Backfill an existing table:

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

A validation is inherently synchronous. `on_error` defaults to `:pass`, so a TypeSafe outage cannot stop
your users from saving. **That default is wrong for moderation**: a check that blocks spam or personal data
and then fails open lets through exactly what it exists to catch. Use `on_error: :fail` there.

## Configuration

```ruby
Jev.configure do |c|
  c.api_key     = ENV["JEV_API_KEY"]
  c.model       = "jev-latest"
  c.timeout     = 10.0
  c.max_retries = 2
end
```

## Without Rails

The core is plain Ruby with no dependencies outside the standard library. `require "jev"` gives you
questions, results and the client. `require "jev/rails"` adds the ActiveRecord layer.

## Licence

MIT.
