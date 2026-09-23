# Advanced

Everything here is shipped, tested and supported. It is not in the README because a reader meeting
three callback modes before the second example leaves, and because none of it is needed to use the
gem. Read [README.md](README.md) first.

## Synchronous attributes

```ruby
judge_attribute :urgency, Judge.noul("..."), sync: true
```

The judgment is computed inline, in a `before_save`, so the value is there the moment the record is
saved and never briefly nil.

The cost is real and it is the reason this is not the default: an HTTP call inside a save holds a
pooled database connection for its whole duration. A vendor having a slow minute becomes a connection
pool exhausted, which takes down more than this feature. Use it when a nil value is worse than a slow
save, and not otherwise.

### `on_error`

Only a synchronous attribute can honour it. Anything else has already committed by the time the call
runs, so there is nothing left to block. Declaring `on_error` on an async attribute raises at load
time rather than silently doing nothing.

```ruby
judge_attribute :urgency, Judge.noul("..."), sync: true, on_error: :pass   # default, save goes through
judge_attribute :urgency, Judge.noul("..."), sync: true, on_error: :fail   # save is blocked
judge_attribute :urgency, Judge.noul("..."), sync: true, on_error: :raise  # error propagates
```

`:pass` is the default because most judgments are advisory: a ticket with no urgency score is still a
ticket. `:fail` is for the case where acting without the judgment is worse than not acting, which in
practice means moderation.

## Conditional attributes

```ruby
judge_attribute :spam, Judge.noul("Is this spam?"),
              source: :body,
              if_condition: ->(ticket) { ticket.channel == "web" }
```

A Symbol naming a predicate method works too. Records that fail the condition are never judged and
never enqueued, so this is the cheapest filter available: it costs no call at all, unlike
`judge_filter`, which costs one per row.

The condition is evaluated at save time and again on refresh. A record that becomes eligible later
is judged then. A lambda with no argument runs against the record, like `if_condition: -> { open? }`.

A record that stops being eligible keeps its last judgment. Closing a ticket does not erase its urgency.

## Manual attributes

```ruby
judge_attribute :urgency, Judge.noul("..."), callbacks: false
```

The attribute is declared, its column and scopes exist, and nothing computes it automatically. It
only moves when you ask:

```ruby
ticket.judge_refresh          # recompute in memory
ticket.judge_refresh!         # recompute and save
ticket.judge_refresh_later    # enqueue it
```

This is the mode for a column you backfill deliberately rather than maintain continuously, and it is
what makes `judge_refresh_all` below do anything.

## Backfill

```ruby
summary = Ticket.judge_refresh_all(batch_size: 100)
summary.to_h   # => {records: 250, computed: 250, skipped: 0, failed: 0, calls: 250}

Ticket.where(channel: "chat").judge_refresh_all(resume: true)
```

`resume: true` skips records whose judgments are already current, so an interrupted run continues
where it stopped rather than paying for everything again. It walks in batches and keeps the last
good value on failure, counting the failure rather than aborting.

It makes one call per record. That is deliberate: several records sharing one request degrades the
judgment badly, which `BENCHMARK.md` measures. To go faster, go wider, not fuller.

## The enqueuer

ActiveJob is optional. The gem enqueues through one injectable callable, so a different queue system
is a lambda:

```ruby
Judge::Rails::Jobs.enqueuer = lambda do |payload|
  MyQueue.push(model: payload.model_name, ids: payload.ids, names: payload.names)
end

Judge::Rails::Jobs.reset_enqueuer!   # back to ActiveJob
```

The payload it receives is what the job needs to do the work later: a model name, record ids, and
attribute names. Replaying it is `Judge::Rails::Jobs.perform(payload)`. That logs and drops every
failure. Pass `raise_retryable: true` to let a 429, a 5xx or a transport error reach your queue's own
retry, which is what `RefreshJob` does.

## Concurrency

`judge_filter`, `judge_map` and `judge_sort` fan out across records. The default is 8 threads.

```ruby
Ticket.judge_filter("...", limit: 500, concurrency: 16)
Judge.configure { |c| c.concurrency = 16 }
```

The pool is available on its own, and it is plain Ruby with no Rails in it:

```ruby
Judge::Pool.map(texts, concurrency: 8) { |text| Judge.ask(question, text: text) }
```

Input order is preserved. `concurrency: 1` runs inline without creating a thread. The first error
drains the queue so no new request starts, then is re-raised once every worker has stopped, so
nothing is left running behind a raise. The same holds when the caller is interrupted, by
`Rack::Timeout` for instance: requests in flight finish, and nothing new starts.

Workers run inside the Rails executor when Rails is loaded, carry the caller's log tags, and close
their connections when they exit.

Measured against the live API on 100 records: 1.9x at 2 threads, 3.6x at 4, 6.9x at 8, 11.7x at 16,
18.4x at 32, with no rate limiting observed and input tokens identical at every level. Efficiency
falls as threads rise, which is why the default is 8 and not 32. Your key's quota is yours to know.
