# BENCHMARK

Pre-registered protocol for the `Judge::Batch` batching engine, written before anything ran.

**Status on 2026-09-21: the campaign is finished and all five arms have run. The verdict is in
section 7: batching fails the criterion and is not wired in.** Every figure in this document is
either measured or arithmetic that is labeled as such.

**Rename note.** The gem was called `jev-in-rails` when these measurements were taken, and has been
`judge_rails` since 2026-09-23. Paths and identifiers in this document were updated so it stays
reproducible. The measurements themselves are unchanged. `wiki/queries/why-the-gem-was-renamed.md`
explains why.

The protocol comes first because the house rule is "verify, do not assert", and a protocol fixed
after seeing the results proves nothing.

## 1. The question

`judge_filter` makes one network call per row, in series. pg_jev judges 2000 rows in 3.5 seconds by
packing 20 subjects into one `state` with one question per subject, and keeping 16 requests in
flight. Can batching carry over here without degrading the judgment, and by how much?

The API has no "subjects" dimension. It takes `{state, model, questions}`. Batching therefore means
encoding the subjects inside the `state` and asking one anchored question per subject. For the
model that is a different input regime. The transport stays the same.

## 2. Measured offline, free, reproducible

Everything below is read from a file in the workspace, with no network call.

### 2.1 The baseline

`judge_rails_demo/db/seed_judgments.rb`, 250 judgments produced by the unbatched path against the
real model.

| Quantity | Value |
|---|---|
| Judgments | 250 |
| Model | `jev-1.13.0`, only one |
| Distinct question digests | 3 (`9e08ebfeb6e0e0fa`, `5f3c0bad775abc1c`, `d3f59e90f1ce9b41`) |
| Mean latency | 0.309 s |
| Latency p50 / min / max | 0.286 s / 0.228 s / 0.773 s |

Each row carries the noul probability, the full `probabilities` distribution of the choice, and the
value, level and distribution of the score. Agreement is measured against this baseline.

### 2.2 The inputs

`judge_rails_demo/db/seed_tickets.rb`, where the `state` is `[subject, body]` joined by two newlines
(`app/models/ticket.rb:14`).

| Quantity | Value |
|---|---|
| Tickets | 250 |
| `state` in characters | mean 208, p50 156, max 851 |
| `state` total | 52,114 characters |
| The 3 questions + criteria | ~620 characters |
| Rows that fit in 24,000 characters | ~115 |

On this dataset the accuracy ceiling (20 to 25 rows) bites about five times earlier than the `state`
size ceiling. The demo will never reach the character budget.

### 2.3 The current paths, read from the code

| Path | File | Requests | Parallelism |
|---|---|---|---|
| `judge_filter` / `map` / `sort` | `lib/judge/rails/relation.rb:41-44` | 1 per row | **1 thread** |
| backfill by job | `lib/judge/rails/jobs.rb:56-61` | 1 per record | depends on the queue |
| single computation | `lib/judge/rails/storage.rb:26-34` | 1 per record | n/a |
| `judge:demo:precompute` | `judge_rails_demo/lib/tasks/judge_demo.rake:8-30` | 1 per ticket | **8 threads** |

None of these paths puts two subjects in one request. `Jobs.batch` (`jobs.rb:39-48`) groups ids to
reduce the number of jobs. The number of requests stays the same.

## 3. Projected: arithmetic, not measured

Labeled separately because nothing here was observed.

### 3.1 Requests to judge 250 tickets on 3 questions

| Shape | Requests | Calculation |
|---|---|---|
| Current | 250 | 1 per ticket, 3 questions in the request |
| A, 1 question × 20 rows | 39 | 3 definitions × ceil(250/20) |
| B, 3 questions × 20 rows | 13 | ceil(250/20) |

### 3.2 Tokens per row, estimated at 4 characters per token

| Shape | Tokens / row | Detail |
|---|---|---|
| A | ~400 | the ticket `state` is sent 3 times, once per definition |
| B | ~296 | the `state` is sent once, with 3 questions per row |

Estimated difference: **B is about 26% cheaper than A**, far from a factor of 3. With short rows the
per-row instructions dominate the cost, more than the `state` does.

For reference, pg_jev documents ~175 input tokens per row in batches of 20, against ~435 for a single
row. Our questions carry richer criteria than its conditions, hence the higher figure.

### 3.3 Campaign cost

~430 requests, ~710,000 input tokens, so **~$0.03** at the $0.042 per million input tokens quoted in
the pg_jev documentation. **That price is borrowed and was never checked with Jev.** The real cost
will show up in `ResultSet#usage`, which the client already fills in (`result_set.rb:34`).

## 4. What the protocol cannot establish

- **Absolute calibration.** We measure agreement with the unbatched path, with no human labels to
  measure correctness against. This workspace has no human-labeled dataset.
- **Generalization beyond this dataset.** 250 short, synthetic support tickets in English. Long
  documents and multilingual data are not covered.
- **Behavior near the 32k limit.** No input in the dataset comes close.

## 5. Design decisions that define the experiment

Taken before the run, so that the arms of the protocol mean something.

| # | Decision |
|---|---|
| D1 | Batching is opt-in. `Judge.config.batch_rows` and `Judge.config.concurrency`, `nil` by default |
| D2 | Only the bulk paths read the setting. The sync `before_save` cannot be batched, because a `before_save` has to finish before its own save. The validator is excluded because it fails closed |
| D3 | `state` = strict JSON `{condition, rows:[{id, text}]}`. One question per row, named `row0`, `row1`, with instructions prefixed by an anchor that names the id and says to treat the text as data |
| D4 | The batch path never substitutes the anchored question into the `Definition`. The sidecar carries the digest of the original question, otherwise `stale?` loops |
| D5 | Incomplete response: bisection. The batch is split in two and retried, depth capped at 5, and the one-row base case goes through the single path |
| D6 | The character budget is a guard that raises with the measured size in the message. Packing counts rows, not characters |
| D7 | This document decides the chosen shape (A or B) and the value of `batch_rows`. Nothing before it does |

## 6. Protocol

### Arm 0. Latency as a function of the number of questions. RUN on 2026-09-21

**This arm decides whether the rest is worth anything.** The vendor claims that response time barely
moves when you add questions. The wiki carried that claim at `confidence: medium`, never checked
here.

`judge_rails/bin/arm0_latency`. One 280-character state, the same question repeated N times, 3
repetitions per point, 18 requests against the real model.

| N questions | Median latency | Spread | Input tokens | Tokens / question | vs N=1 |
|---|---|---|---|---|---|
| 1 | 0.280 s | 0.428 s | 350 | 350 | 1.00x |
| 2 | 0.264 s | 0.032 s | 373 | 186 | 0.94x |
| 5 | 0.242 s | 0.031 s | 442 | 88 | 0.86x |
| 10 | 0.234 s | 0.014 s | 557 | 56 | 0.84x |
| 20 | 0.242 s | 0.020 s | 797 | 40 | 0.86x |
| 40 | 0.246 s | 0.024 s | 1,277 | 32 | 0.88x |

**Latency is flat.** 40 questions in one request take the same time as one, at 0.88x. The go/no-go
criterion asked for less than 10x at N=20, and we measured 0.86x. The 0.428 s spread at N=1 is the
first request on a cold connection, and it does not recur at any other point.

The vendor's claim is **verified**, and the wiki can move `[[typesafe-jev]]` from `medium` to `high`
on this specific point.

**Cost structure, measured.** The fixed overhead of a request is about **326 tokens** (350 at N=1
minus the marginal cost of one question), and a marginal question costs
**(1277 - 350) / 39 ≈ 24 tokens**. Batching amortizes this fixed overhead. pg_jev documents the same
mechanism without putting a number on it for us.

Arithmetic consequence for the demo: judging 250 tickets without batching pays the overhead 250
times, ~81,500 tokens of pure structure. In batches of 20 it pays 13 times, ~4,200. **~77,000 tokens
saved on structure alone.**

**This arm refutes arm 4's conclusion on cost.** The byte proxy predicted +24.6% for batching. Real
billing says 8.75x fewer tokens per question at N=20. Bytes on the wire are not the bill: the ~326
token overhead has no visible counterpart in the payload. The proxy is dropped as a cost instrument
and `ResultSet#usage` replaces it.

**Caveat.** This arm keeps the state fixed and varies N. In a real batch the state grows with the
rows. The arm shows that latency does not depend on N and that the per-request overhead is real. The
total cost of a batch is an output of arms 2 and 3.

### Arm 1. Control: model determinism. RUN on 2026-09-21

`bin/rails judge:bench:control SAMPLE=50`. The unbatched path replayed on 50 tickets and compared to
the baseline. This is the noise floor, and no other arm can be read without it.

| Question | n | Decision agreement | Mean \|Δ\| | p95 \|Δ\| |
|---|---|---|---|---|
| urgency (noul) | 50 | **100.0%** | 0.0118 | 0.0300 |
| intent (choice) | 50 | **100.0%** | 0.0082 | 0.0400 |
| frustration (score) | 50 | **96.0%** | 0.0108 | 0.0400 |

50 requests, 26,492 input tokens, 13.52 s.

The model is close to deterministic. Mean drift is ~0.01 and decisions are stable, except for one
score level in 25 that flips. **The noise floor is therefore ~0.01 drift and 96 to 100% agreement.**
Everything that follows is read against those three numbers.

### Arms 2 and 3. Shapes A and B, four batch sizes. RUN on 2026-09-21

`bin/rails judge:bench:campaign SHAPE=a|b BATCH=n`, 250 tickets, compared to the baseline.

**Decision agreement, in percent. Control on the first row.**

| Batch | Shape | urgency | intent | frustration | Requests | Tokens |
|---|---|---|---|---|---|---|
| 1 | control | **100.0** | **100.0** | **96.0** | 250* | 132,460* |
| 2 | A | 91.6 | 90.4 | 90.0 | 375 | 228,021 |
| 2 | B | 93.2 | 89.2 | 89.2 | 125 | 129,882 |
| 5 | A | 91.2 | 89.6 | 84.4 | 150 | 165,999 |
| 5 | B | 91.2 | 90.4 | 86.4 | 50 | 110,083 |
| 10 | A | 88.0 | 87.6 | 83.6 | 75 | 145,324 |
| 10 | B | 88.4 | 88.0 | 85.6 | 25 | 103,483 |
| 20 | A | 86.4 | 87.6 | 84.4 | 39 | 136,120 |
| 20 | B | 85.6 | 89.6 | 86.8 | 13 | 100,795 |
| 40 | A | 83.2 | 87.6 | 82.4 | 21 | 131,518 |
| 40 | B | 85.2 | 86.8 | 84.4 | 7 | 99,451 |

\* control extrapolated from 50 to 250 tickets for the comparison.

**Mean \|Δ\| drift, control at ~0.01.**

| Batch | Shape | urgency | intent | frustration |
|---|---|---|---|---|
| 1 | control | 0.0118 | 0.0082 | 0.0108 |
| 2 | B | 0.0532 | 0.0804 | 0.1110 |
| 5 | B | 0.0730 | 0.0937 | 0.1394 |
| 10 | B | 0.0816 | 0.1042 | 0.1543 |
| 20 | B | 0.0819 | 0.1097 | 0.1587 |
| 40 | B | 0.0874 | 0.1146 | 0.1780 |

### Arm 5. 2x2 isolation, one row per request. RUN on 2026-09-21

`bin/rails judge:bench:isolate VARIANT=... SAMPLE=150`. With one row per request there is no
neighbor, so this square separates the two other causes: the JSON envelope around the `state`, and
the anchor prefix on the instructions.

| Variant | `state` | instructions | urgency | intent | frustration |
|---|---|---|---|---|---|
| `raw_plain` | raw text | original | **98.7** | **100.0** | **98.7** |
| `json_plain` | JSON `{rows:[...]}` | original | 96.0 | 98.0 | 95.3 |
| `raw_anchored` | raw text | prefixed | 98.0 | 94.0 | 95.3 |
| `json_anchored` | JSON | prefixed | 96.0 | 96.7 | 96.0 |

600 requests, ~351,000 tokens, ~22 s in total.

`raw_plain` reproduces the control, which validates the harness. Each of the two transformations
costs about 2 to 4 points on its own, and the two together cost about **3 points**.

### Breaking down the gap

The batch of 20 lost 10 to 14 points against the control. Arm 5 says where they come from:

| Cause | Points lost | Avoidable? |
|---|---|---|
| JSON envelope + anchor prefix | **~3** | maybe, by changing the shape |
| Neighbors present in the `state` | **~9** | no, that is batching itself |

The dominant cause is the neighbors, more than the JSON or the prefix.

**Corrected on 2026-09-23 by arm 7.** This split is a residual, not a measurement, and arm 7 refutes
it at a batch of 2: there the neighbor's content costs -0.3 points, the object shape -5.6 and a
second key -3.2. See arm 7.

### What the TypeSafe documentation says, and how it explains the result

The [Parallel Questions](https://docs.typesafe.ai/cookbooks/parallel_questions.md) cookbook measures
13 batched questions against 13 separate questions on a 54,000-character article: **12.2x cheaper,
10.0x faster, no change in answers**, with a standard deviation of exactly 0.0 on most questions. It
gives the reason:

> "each question is scored on its own against the document, so its answer doesn't depend on what
> else is in the request."

A question does not depend on the other questions. It depends entirely on the **document**. Putting
20 tickets in the `state` leaves the questions alone and changes the document each one is scored
against. Every ticket is judged in the middle of 19 texts that have nothing to do with it.

The [Re-Ranking](https://docs.typesafe.ai/cookbooks/rerank_typesafe.md) cookbook is the same problem
as ours, 3,565 passages to judge independently, and TypeSafe solves it with a
`{query_excerpt, candidate_passage}` state, **one candidate per request**, and **1,200 concurrent
calls in a thread pool**, 1,536,002 input tokens for $0.0645. Batching by subject does not appear.

**Corrected on 2026-09-23.** The cookbook does not say "1,200 concurrent calls". It runs 40 queries ×
30 candidates preselected by BM25 out of the 3,565 passages, 1,200 calls in total, in a
`ThreadPoolExecutor(max_workers=12)`. The lesson we kept (one candidate per request) still holds. The
concurrency figure never existed. Re-read in `wiki/raw/transcripts/vendor-docs-check-2026-09-23.md`.

**Conclusion.** Batching by question is the documented route and the gem already follows it: three
`judge_attribute` on a ticket go out in one request (`storage.rb:26-34`). Batching by subject is not
a documented route, and the measurement shows why.

### The diagnosis behind the curve

The degradation is **already complete at a batch of 2** and moves little up to 40. Going from 1 to 2
rows costs about 8 points of agreement. Going from 2 to 40 costs only 5 more.

**The dominant cause is the change of shape, more than the number of neighbors.** Two things change
at once between the control and a batch of 2:

1. the `state` goes from raw text to a JSON object `{condition, rows:[{id, text}]}`,
2. the question instructions are rewritten with an anchor prefix.

The protocol does not separate these two causes. That is the next test to run, and it is cheap.

### Shape A against shape B

Agreement is the same for both shapes, within the noise. B is strictly cheaper: at a batch of 20, 13
requests against 39 and 100,795 tokens against 136,120, so **26% fewer tokens for the same
accuracy**. If batching were adopted, it would take shape B. That settles A against B, though it
does not make batching acceptable.

### What batching would buy, and at what price

| Axis | Control | Shape B, batch 20 | Effect |
|---|---|---|---|
| Wall time per ticket | 0.270 s | 0.0055 s | **49x faster** |
| Tokens per ticket | 530 | 403 | **-24%** |
| urgency agreement | 100.0% | 85.6% | **-14.4 points** |
| intent agreement | 100.0% | 89.6% | **-10.4 points** |
| frustration agreement | 96.0% | 86.8% | **-9.2 points** |

The speed gain is real and large. The token saving is real and modest, far from the 8.75x that arm 0
suggested: once the rows are in the `state`, the `state` dominates, and the amortized fixed overhead
no longer weighs much.

### Arm 4. Offline throughput, no API. RUN on 2026-09-21

`judge_rails/bin/bench_batch`, against `FakeJev` with **0.300 s** of injected latency, the mean
measured in 2.1. 250 rows of a size comparable to the demo's. It measures the thread pool and the
packing. The model is not involved.

| Configuration | Requests | Wall time | Bytes sent | vs sequential 1 thread |
|---|---|---|---|---|
| sequential, 1 thread | 250 | 76.11 s | 127,480 | 1.0x |
| sequential, 8 threads | 250 | 9.75 s | 127,480 | 7.8x |
| batch 20, 8 threads | 13 | 0.62 s | 158,858 | **122.8x** |
| batch 20, 16 threads | 13 | 0.32 s | 158,858 | **241.4x** |

Reproducible: `cd judge_rails && bundle exec ruby bin/bench_batch`. `ROWS` and `LATENCY` can be
overridden.

**A caveat that governs the whole table.** `FakeJev` answers in a fixed time whatever the number of
questions in the request. The 122x and 241x figures therefore assume, **by construction**, that
latency does not grow with the number of questions. Arm 0 exists to test exactly that assumption.
Until arm 0 has run, these two figures are a theoretical ceiling, not a measurement of the real gain.

**A result that contradicts a starting assumption.** Batching sends **more** bytes: 158,858 against
127,480, **+24.6%**, or 635 bytes per row against 510. There are two causes, both measured here: the
anchor prefix is sent once per row instead of once per request, and the JSON wrapping of each row
(`{"id":n,"text":...}`) adds bytes the single path does not have.

So **the offline bench cannot settle the cost axis**, contrary to what section 3.2 projected. The
token saving pg_jev documents (175 against 435 per row) comes from amortizing a per-request overhead
of about 270 tokens, which is billed on the server and does not appear in the payload. Only the
`ResultSet#usage` returned by the real API can decide, which makes the token count an output of arms
1 to 3 and not of arm 4.

### Arm 4b, in the test suite

`test/batch_throughput_test.rb`, 6 tests, 0.1 s of injected latency, small volumes. It checks in
under a second that the pool really overlaps requests and that batching reduces the request count.
The faithful version of arm 4 takes 76 seconds, so it has no place in `rake test`.

### Arm 6. Concurrency sweep on the real API. RUN on 2026-09-21

`bin/rails judge:bench:isolate VARIANT=raw_plain SAMPLE=100 CONCURRENCY=n`. The exact production
shape: `state` in raw text, 3 questions per ticket, one ticket per request. Only the thread count
changes.

| Threads | Wall time | Speedup | Efficiency | urgency | intent | frustration | Tokens |
|---|---|---|---|---|---|---|---|
| 1 | 25.01 s | 1.0x | 100% | 99.0 | 99.0 | 98.0 | 52,859 |
| 2 | 13.02 s | 1.92x | 96% | 100.0 | 99.0 | 100.0 | 52,859 |
| 4 | 6.87 s | 3.64x | 91% | 99.0 | 99.0 | 99.0 | 52,859 |
| 8 | 3.60 s | **6.95x** | 87% | 99.0 | 99.0 | 100.0 | 52,859 |
| 16 | 2.13 s | **11.7x** | 73% | 100.0 | 99.0 | 99.0 | 52,859 |
| 32 | 1.36 s | **18.4x** | 57% | 99.0 | 99.0 | 98.0 | 52,859 |

What the table shows:

1. **No ceiling observed up to 32.** No errors, no 429s, and wall time keeps dropping. Efficiency
   degrades (57% at 32) but the speedup stays monotonic.
   **Caveat added on 2026-09-23:** `models.md` documents 1,200 requests per minute. 100 requests per
   level never fill a minute, so this arm could not see the limit. See arm 9.
2. **Accuracy does not move.** 98 to 100% at every level, the same as in series. That is expected,
   and it is the basic difference from batching: the request is **byte for byte the same**, and only
   its scheduling changes.
3. **Tokens are identical to the unit**, 52,859 at every level. Concurrency costs nothing.

**Default chosen: 8.** 6.95x at 87% efficiency, and 8 connections per process is reasonable for a
gem that runs inside an application server. The sweep ran on one machine, with one key and 100
requests. It says nothing about the quota of a shared key under real load. `Judge.config.concurrency`
and the `concurrency:` keyword exist for anyone whose own measurement says otherwise.

### Arm 7. Object `state` with named keys. PRE-REGISTERED, then RUN on 2026-09-23

**Why this arm.** Re-read on 2026-09-23, arm 5 does not measure what the "breaking down the gap"
section attributes to it. The ~9 points "from the neighbors" are a residual, not a measurement.
Between one JSON row and a batch of 20, several things change at once: the presence of foreign text
(dilution), designating the subject by a numeric `id` in an array (addressing), the number of
questions and the length of the `state`. The `raw_anchored` cell is inconsistent: it mentions a
"rows array" that a text `state` does not contain. The sample for arms 1 and 5 (`first(n)` by id)
contains no spam ticket.

The TypeSafe documentation (`concepts/state.md`, `primitives/advanced.md`) describes an **object**
`state` where each part has a name, and instructions that name the part they target. A manual test
in the playground, `{"State_1": "Shut up !", "State_2": "Shut up ?"}` with "Is State_1 a question ?",
returns 2% and 98%: the API accepts the shape and addressing holds on a minimal pair. This arm
measures whether addressing by named key recovers the accuracy that `rows[id]` lost.

**Shape.** `state` = a real JSON object (not a string), keys `ticket_1` to `ticket_N`. One question
per key and per definition, named `ticket_k_<name>`, whose original instruction is rewritten to name
the key ("Does ticket_1 need a human...", "Which team should handle ticket_1?", "How frustrated does
the customer in ticket_1 sound?"). No anchor prefix. Criteria unchanged.

**Variants, all on the 250 tickets**, compared to the `db/seed_judgments.rb` baseline:

| Variant | `state` | Requests | Isolates |
|---|---|---|---|
| `control` | raw text, original questions | 250 | noise floor on the same population |
| `named_1` | `{ticket_1}` | 250 | cost of the object shape alone |
| `named_same` | `{ticket_1, ticket_2}`, the same ticket twice | 250 | cost of a second key, with no foreign content |
| `named_2` | two different tickets | 125 | addressing + dilution, where the gap appeared |
| `named_20` | twenty different tickets | 13 | comparable to shape B at batch 20 |

Tickets are shuffled with a fixed seed (`SEED=7`) before grouping, so neighbors do not share a
category by construction. Concurrency 8. Each judged row is written as JSONL to `tmp/bench/`, with
the model that served it (`ResultSet#model`) and the neighbor ids.

**Criterion, fixed before the run.** A variant passes if, on each of the three questions, its
agreement is at least that of `control` minus 2 points (the range observed in arm 6 over six
repetitions of the production shape).

**Reading, fixed before the run.**

- `named_1` passes: the object shape is free.
- `named_same` passes and `named_2` fails: the cause is foreign content, and dilution is confirmed.
- `named_same` fails: a second key has a cost of its own, whatever its content.
- `named_2` and `named_20` pass: the 9 points of arms 2 and 3 came from the `rows[id]` shape, and
  batching by subject is back on the table.
- Contamination: among the disagreements in `named_2`, the share where the answer equals the
  neighbor's baseline answer, compared to chance.

Budget: 888 requests, ~500,000 input tokens, ~$0.02 at the borrowed price.

Command: `bin/rails judge:bench:named VARIANT=control|named_1|named_same|named_2|named_20`.
`DRY_RUN=1` prints the first request and calls nothing.

#### Results, 2026-09-23

888 requests, 668,120 input tokens, no errors. All 1,250 judgments were served by `jev-1.13.0`, the
baseline model, checked on `ResultSet#model` rather than assumed.

| Variant | urgency | intent | frustration | Mean | Requests | Tokens | Wall time |
|---|---|---|---|---|---|---|---|
| `control` | **99.2** | **98.8** | **97.6** | 98.5 | 250 | 134,664 | 9.55 s |
| `named_1` | 93.2 | 96.0 | 89.6 | 92.9 | 250 | 138,164 | 9.07 s |
| `named_same` | 92.8 | 94.0 | 82.4 | 89.7 | 250 | 211,828 | 9.85 s |
| `named_2` | 91.6 | 90.8 | 86.0 | 89.5 | 125 | 105,914 | 4.96 s |
| `named_20` | 84.4 | 84.0 | 85.2 | 84.5 | 13 | 77,550 | 0.80 s |

Pass threshold: 97.2 / 96.8 / 95.6. **No named variant passes, not even `named_1`.** `control`
reproduces arm 1 on the whole population, spam included, which validates the harness.

**Direction of the disagreements**, band and level moving up or down relative to the baseline:

| Variant | urgency up / down | frustration up / down | Dominant intent flip |
|---|---|---|---|
| `control` | 0 / 2 | 3 / 3 | none, 3 isolated flips |
| `named_1` | 3 / 14 | 1 / 25 | none |
| `named_same` | 2 / 16 | 1 / 43 | sales to spam x4 |
| `named_2` | 8 / 13 | 4 / 31 | billing to technical x9 |
| `named_20` | 3 / 36 | 10 / 27 | billing to technical x18 |

In the control the disagreements are symmetric, which is noise. In every named variant they go one
way: **a ticket placed as a named field of an object reads calmer and less urgent.** That is a
systematic calibration shift, with no sign of random scatter.

**Contamination in `named_2`**, disagreements equal to the neighbor's baseline against chance:
urgency 7 against 8.0, intent 2 against 6.1, frustration 7 against 10.1. **Wrong answers do not copy
the neighbor.** Agreement by position in `named_2`: 89.3% for `ticket_1`, 89.6% for `ticket_2`, no
position effect.

#### Reading, against the grid fixed before the run

| Step | Mean | Cost | What changes |
|---|---|---|---|
| `control` | 98.5 | - | - |
| `named_1` | 92.9 | **-5.6** | the shape: a one-key object, an instruction that names the key |
| `named_same` | 89.7 | **-3.2** | a second key, with no new content at all |
| `named_2` | 89.5 | **-0.3** | the neighbor's content |
| `named_20` | 84.5 | -5.0 | 18 more tickets |

1. **`named_1` fails: the object shape is not free.** It is the biggest measured step, and it is
   there with no neighbor at all.
2. **`named_same` fails: a second key has a cost of its own**, even though it only carries the same
   text. Frustration drops the most here, 43 of 44 disagreements.
3. **Foreign content costs almost nothing at a batch of 2**: -0.3 points between `named_same` and
   `named_2`, and contamination at or below chance. **"Dilution", in the sense of a neighbor bleeding
   into the answer, is not observed.**
4. **`named_20` fails** at the level of shape B at batch 20 (85.6 / 89.6 / 86.8). Batching by subject
   stays closed, whatever the addressing scheme.

**What this corrects.** The explanation written after arm 5, "3 points of shape, 9 points of
neighbors", has the wrong split. At a batch of 2, nearly all of the gap comes from leaving the
production shape (-5.6) and from the presence of a second key (-3.2). What the neighbor says barely
matters. At a batch of 20, the extra 5 points remain unattributed: `state` length, number of
questions and foreign content all change together.

**What this arm cannot say.** Agreement is measured against a baseline produced from raw text. A
shift toward "calmer" is a disagreement with the production shape, and not necessarily an error:
without human labels we cannot tell which of the two readings is more accurate. We do know they are
not interchangeable, and that the demo's thresholds (0.8 and 0.2) are tuned on the text shape.
`named_1` also conflates two changes, the object and the rewritten instruction ("this message"
becomes "ticket_1"), and this arm does not separate them. There is one run per variant. At n=250 one
ticket is worth 0.4 points, and the differences we keep are 8 to 40 tickets.

**Decision unchanged.** One subject per request, raw text, original questions. The thread pool is
still the way forward. Arm 7 does not reopen batching. It replaces the reason for rejecting it.

Raw data: `judge_rails_demo/tmp/bench/arm7_*.jsonl`, snapshotted in
`wiki/raw/transcripts/named-state-arm7-2026-09-23.md`.

### Reference labels. PRE-REGISTERED on 2026-09-23

**Why.** Every previous arm measures agreement with raw text, never correctness.
`db/seed_tickets.rb` carries no labels. Without a reference, the "calmer, less urgent" shift in arm 7
cannot be settled.

**Shape.** Two independent annotators label the 250 tickets on the three questions, using the exact
definitions in `app/models/ticket.rb`: urgency true or false, intent among the four teams,
frustration from 0 to 3. They read only `db/seed_tickets.rb`, never a Jev judgment. One reads in
order, the other in reverse. Each annotator flags the calls they consider borderline.

**Caveat, written before seeing the result.** Both annotators are models (Claude Opus), not humans.
The reference is their **consensus**: a ticket counts for a question only if both agree.
Disagreements are listed for human review. Any figure read against this reference is written as
"agreement with the annotator consensus", never as "correctness".

Storage: `db/ticket_labels.json`, keyed by `subject|customer_name` like `db/seed_judgments.rb`.

### Analyses without requests. PRE-REGISTERED on 2026-09-23

`bin/rails judge:eval:offline`. Reads `db/seed_judgments.rb` and `db/ticket_labels.json` and calls
nothing.

1. **Baseline correctness** against the consensus. urgency: decision at p >= 0.5 against the label,
   plus the Brier score. intent: argmax, plus the multiclass Brier. frustration: rounded level, plus
   the mean absolute error.
2. **Confidence bands.** The share of tickets in the noul `:unsure` band (0.2 < p < 0.8), and the
   share of intents below 0.6 confidence. For each band, the agreement with the consensus. If
   low-confidence answers are no less correct than the others, confidence tells us nothing here.
3. **Recalibration.** One temperature per question, fitted by likelihood on a random half (fixed
   seed) and tested on the other. Criterion: it is adopted only if the Brier on the test half drops
   by at least 10% against the identity. Otherwise Jev is declared calibrated on this dataset, to
   the precision of 125 tickets.

### Arm 7b. Is the named-key shift a constant? PRE-REGISTERED on 2026-09-23

The arm 7 JSONL files keep only the decisions, not the probabilities. `named_1` is replayed once (250
requests, seed 7) keeping the raw values. On one half, we estimate the mean logit shift between
`named_1` and the baseline, per question (urgency: logit of p; frustration: difference in continuous
value). We subtract it on the other half.

**Fixed reading.** If the test half's agreement with the baseline climbs back to within 2 points of
the control, the shift is a correctable constant. Otherwise it depends on the ticket. Either way,
the annotator consensus says which of the two readings is closer.

### Arm 8. Structured criteria. PRE-REGISTERED on 2026-09-23

**Why.** `docs.typesafe.ai/primitives/advanced.md` documents Choice options as
`{what, not_for, examples}` objects and Noul `true` and `false` criteria as objects, "to sharpen the
boundary". No figures are published. Until now the gem converted every entry to a string. It now
accepts objects, without changing the digest of a string criterion.

**Shape.** One subject per request, raw text, three questions, concurrency 8. Only the urgency and
intent criteria change. The `what` repeats the original text word for word, and `not_for` and two
generic `examples` are added. No example is taken from the 250 tickets. frustration does not change:
it is the control question and must not move.

| Variant | Criteria | Requests |
|---|---|---|
| `current` | those in `ticket.rb` | 250 |
| `structured` | objects | 250 |
| `structured_replay` | objects, first 50 tickets replayed | 50 |

**Criterion, fixed before the run**, against the annotator consensus, `structured` against
`current` from the same day:

- adopted if, on urgency and on intent, agreement drops by no more than one point and rises by at
  least 2 points on one of the two, or if the Brier drops by at least 10% with no loss of agreement;
- rejected otherwise. The extra token cost is reported, not weighed: at the confirmed price it is
  negligible.

`structured_replay` gives its noise floor. frustration must stay within the noise of arm 1.

Command: `bin/rails judge:eval:criteria VARIANT=current|structured|structured_replay`.
Since the demo switched over, `current` is called `plain`: the model's criteria are structured, and
`plain` rebuilds the original strings, including the digests `9e08ebfeb6e0e0fa` and
`5f3c0bad775abc1c`.

### Arm 9. Sustained rate limit. PRE-REGISTERED on 2026-09-23

**Why.** `docs.typesafe.ai/models.md` documents 1,200 requests per minute and 250,000 tokens per
second. Arm 6 sent 100 requests per level and could not fill a minute. At 8 threads the pool runs at
~28 requests per second, above the documented limit.

**Shape.** The production shape, looping over the 250 tickets for 75 s, with a client that never
retries (`max_retries = 0`) so every raw 429 and its `Retry-After` are visible. Levels run in
sequence: 8, then 16, then 32 only if 16 saw no 429. Two minutes of pause between levels.

**Fixed reading.**

- 429s at 8: the limit applies and the gem's default exceeds it. We need a client-side limiter or a
  `max_retry_wait` that covers the observed `Retry-After`.
- No 429 at 32 over 75 s: the documented limit is not enforced on this key today. The default of 8
  stays, and the limit is written down in the README.
- In between: the observed threshold is reported, and the default does not exceed the last level
  without a 429.

Budget: at most ~9,000 requests, ~4.8M tokens, ~$0.20 at the confirmed price.

Command: `bin/rails judge:eval:rate CONCURRENCY=8 DURATION=75`.

### Results of the 2026-09-23 arms (labels, 7b, 8, 9)

Everything was served by `jev-1.13.0`, checked on `ResultSet#model`. Total spend: 8,462,588 input
tokens, **~$0.36** at the confirmed price. Arm 9 cost 7.94M tokens against the 4.8M planned:
throughput doubled with each thread level, like everything else, and the budget underestimated it.

#### Labels

| Question | Inter-annotator agreement | kappa | Consensus kept |
|---|---|---|---|
| urgency | 96.4% | 0.88 | 241 |
| intent | 88.4% | 0.82 | 221 |
| frustration | 84.8% | 0.75 | 212 |

The main disagreement is telling: 15 thank-you messages are `technical` for one annotator and
`spam` for the other, because the spam definition includes "anything not a genuine support request".
The demo's criteria have no place for a message that is neither a request nor spam.

#### Analyses without requests

| Question | Baseline against consensus | Brier |
|---|---|---|
| urgency, decision at 0.5 | 82.6% | 0.1141 |
| intent | 84.2% | 0.2285 |
| frustration, rounded level | 60.8% | mean error 0.399 |

**The errors go one way.** Jev reads tickets as more urgent (41 false positives, 1 false negative at
0.5) and more frustrated (83 levels too high, 0 too low) than both annotators. For intent, it says
`billing` where the consensus says `technical` 18 times.

**Bands.** Confident urgency (p <= 0.2 or >= 0.8): 97.7% agreement on 131 tickets. `:unsure` band:
64.5% on 110. intent at confidence >= 0.6: 88.7% on 194; below 0.6: 51.9% on 27. Confidence sorts
the answers well, so routing the uncertain band makes sense here.

**Temperature.** urgency +0.2%, intent -0.2%, frustration -9.3% of Brier on the test half. None
crosses the 10% threshold: **no temperature recalibration.**

**Exploratory, not pre-registered, tested on a held-out half.** For frustration, subtracting 0.5
before rounding, which amounts to taking the integer part, raises agreement from 62.7% to 83.3%.
For urgency, the 0.5 threshold gives 80.8%, and the demo's 0.8 threshold gives 92.5%, on par with
the best learned threshold (0.75). The cost comes from how the demo reads the number: rounding and
the median threshold.

#### Arm 7b

Shift learned on 125 tickets: -0.164 in logit on urgency, -0.083 in value on frustration. The
per-ticket standard deviation is 0.188, the same order as the mean. The correction raises the test
half's agreement with the baseline from 115 to 121 out of 125 on urgency, and from 110 to 113 on
frustration. **The 2-point criterion is not met: the shift is not a constant.**

Against the consensus, however, `named_1` beats raw text on all three questions:

| | urgency | intent | frustration |
|---|---|---|---|
| raw text | 82.6% (Brier 0.114) | 84.2% (0.229) | 60.8% |
| `named_1` | 85.9% (0.099) | 86.4% (0.213) | 70.3% |

The "calmer, less urgent" shift from arm 7 moves **toward** the labels. Arm 7 measured distance from
raw text, and raw text is the reading furthest from the consensus. That still does not reopen
batching by subject: `named_20` was not re-read against the labels.

#### Arm 8

| Variant | urgency | intent | frustration | Tokens / ticket |
|---|---|---|---|---|
| `current` | 82.6% (Brier 0.1141) | 85.1% (0.2271) | 62.3% | 539 |
| `structured` | **86.7%** (0.0897) | **89.6%** (0.1608) | 61.8% | 825 |

Against the consensus. `current` reproduces the baseline (98.8 / 99.2 / 98.8%). `structured` against
its own replay on 50 tickets: 50/50, 50/50, 49/50, mean drift 0.008. frustration, the control
question, stays within the noise.

**Criterion met: adopted.** +4.1 and +4.5 points, Brier -21% and -29%. `billing` errors that should
have been `technical` drop from 18 to 12. Extra cost: +286 tokens per ticket, +53%, ~$0.000012.

A caveat noticed afterwards: at the demo's escalation threshold (0.8) rather than 0.5, urgency goes
from 91.3% to 90.0%, three tickets. The urgency gain rests on the Brier and the median threshold,
while the intent gain holds everywhere. The demo is not switched over: changing its criteria
invalidates the 250 committed judgments, and the reference is still a consensus of models.

#### Arm 9

| Threads | Requests | Throughput | Max over 60 s | 429 | Latency p50 / p95 |
|---|---|---|---|---|---|
| 8 | 2,187 | 29.2 /s | 1,758 | 0 | 0.268 / 0.336 s |
| 16 | 4,214 | 56.2 /s | 3,393 | 0 | 0.277 / 0.361 s |
| 32 | 8,355 | 111.4 /s | 6,696 | 0 | 0.279 / 0.371 s |

No 429s and no errors over 14,756 requests without retries. At 32 threads that is 5.6 times the
documented per-minute limit and ~60,000 tokens per second, a quarter of the token limit. Latency
does not move. **Fixed reading: the documented limit is not enforced on this key today.** The
default of 8 stays. The limit and this measurement are written in the gem's README, with the
provider's caveat ("can change without notice").

Raw data: `judge_rails_demo/tmp/bench/arm7bis_named_1.jsonl`, `arm8_*.jsonl`, `arm9_c*.jsonl`,
snapshotted in `wiki/raw/transcripts/labels-and-arms-8-9-2026-09-23.md`.

## 7. Acceptance criterion and verdict

### VERDICT, 2026-09-21: batching by subject fails, and the cause is structural.

The hard criterion required 100% agreement on the choice label, the noul band and the score level.
**It fails at every batch size, including 2.** Read relative to arm 1, as the section below
prescribes, the gap is still 9 to 15 points of agreement and the drift is 5 to 16 times the
control's noise floor.

Batching as implemented trades 10 to 15 points of decision accuracy for 49x the speed. For a gem
whose product is a calibrated probability, that is not an acceptable default trade. This protocol
was written before the result was known precisely so the result could not be rationalized
afterwards.

`Judge::Batch` stays in `lib/`, tested and not wired in. `Judge.config.batch_rows` stays `nil`. No
path in the gem batches.

### Next steps, decided by arm 5

**Corrected on 2026-09-23.** The "3 from shape, 9 from neighbors" split below is refuted by arm 7,
and arm 7b shows that the named shape is closer to the labels than raw text. The recommendation (the
thread pool) holds for other reasons, written up in arm 7.

Arm 5 ran and it closes the question: of the 12 points lost, 3 come from the shape and 9 from the
neighbors. Fixing the shape would still leave 9 points on the table, so no version of batching by
subject passes the hard criterion again.

**What to build instead, backed by the measurements:**

1. **A thread pool on `judge_filter`, with no batching.** Same request shape as today, so **zero
   accuracy loss**, and it is the solution the Re-Ranking cookbook applies to 3,565 passages. Arm 4
   measures 7.8x for 8 threads, and arm 5 confirms it on the real API: 150 tickets in 5.44 s at 8
   threads, 0.036 s per ticket against 0.270 s in series.
2. **Do not wire in `Judge::Batch`.** It stays in `lib/`, tested, with this document as the written
   reason.
3. **Move `[[typesafe-jev]]` to `high`** on flat latency as a function of the number of questions,
   which is now measured.

### The criterion, as it was fixed

A double budget, fixed before the run.

**Hard: must pass, or batching does not ship at that batch size:**

- 100% agreement on the choice label
- 100% agreement on the noul's `judge_decide` band, at the demo's thresholds
- 100% agreement on the integer level of the score

**Soft: read as a curve, not as a threshold:**

- mean and p95 `|Δp|` per batch size and per question type
- total variation distance on the choice distribution
- continuous value difference on the score

Both budgets are read **relative to arm 1**, never in absolute terms. If the unbatched control
itself drifts by 0.03 in mean `|Δp|`, a batch at 0.03 has degraded nothing.

The default `batch_rows` would be the largest batch size that passes the hard budget and whose soft
drift stays at the control's level. Not 20 just because pg_jev says 20.

## 8. What still needs protecting

- The current baseline must be snapshotted in `wiki/raw/transcripts/` with its sha256 **before** any
  regeneration of `db/seed_judgments.rb`, otherwise the baseline is lost.
- Arms 0 to 3 never run in `rake test`. The house rule is never to call the real API from a test.
  They will be a manual task. Arm 4 lives in `bin/bench_batch`, outside the suite, and only its
  reduced version is a test.
- Batching widens the blast radius of a prompt injection from 1 to `batch_rows`, since the rows share
  a `state` and the vendor's documentation describes the model as steerable by injected
  instructions. This protocol does not measure it. An adversarial arm would have to be written
  separately.

## 8b. The optimal request recipe, as measured

Three rules, each backed by an arm.

| Rule | Arm | Gain | Accuracy cost |
|---|---|---|---|
| **One subject per request** | 2, 3, 5, 7 | - | leaving raw text costs ~6 points of agreement with the baseline, a neighbor ~0.3 (arm 7). Against the labels, the named shape does better (arm 7b) |
| **All of the subject's questions in the same request** | 0 | 326-token overhead amortized, flat latency up to 40 questions | **zero** |
| **Thread fan-out over subjects** | 6 | 6.95x at 8 threads, 18.4x at 32 | **zero** |

The gem now applies all three: `storage.rb:26-34` groups a record's questions into one call, and
`relation.rb` fans the records out over a pool.

## 9. Log

### 2026-09-21, phase A

Written: `lib/judge/batch.rb` (L2 engine, stdlib only), `Judge::PayloadTooLargeError` in the error
taxonomy, `batch_rows` and `concurrency` on the configuration at `nil`, `test/batch_test.rb` (22
tests), `test/batch_throughput_test.rb` (6 tests), `bin/bench_batch`.

Measured: 200 tests green against 172 before, 580 assertions, zero rubocop offenses, and the Rails
7.2, 8.0 and 8.1 gemfiles all green. Arm 4 ran, table above.

Two corrections to the protocol, made while running it:

1. Arm 4 cannot live in the test suite. At the measured latency of 0.300 s, 250 rows in sequence
   take 76 seconds.
2. `rows:` carries no accuracy ceiling. The previous version of this plan set one at 25, which would
   have stopped arms 2 and 3 from measuring a batch of 40. The measured curve is the guard, not a
   guessed constant.

Naming decision: the questions are called `row0`, `row1` on the wire, in normalcase, because `row_0`
trips `Naming/VariableNumber` and the only alternatives were to disable the cop or to modify a
pre-existing test file that did not belong to this work.

### 2026-09-21, phase B

Written: `judge_rails/bin/arm0_latency`, `judge_rails_demo/lib/tasks/judge_bench.rake`,
`wiki/raw/transcripts/seed-judgments-baseline-2026-09-21.md` (sha256
`0b358b56125d79dfef0b42c351d63c5c603c99066263b78f287fe643457a5839`). `Judge::Batch.judge` extended to
accept a Hash of questions, which arm 3 required. 206 tests green, zero offenses.

Fixed along the way: the demo's `config/initializers/judge.rb` only read `JEV_API_KEY`, while
`Judge::Configuration` has always accepted `TYPESAFE_API_KEY` as a fallback. The demo now accepts
both.

Actual campaign spend: about 1,000 requests and ~1.40 million input tokens, so **~$0.06** at the
borrowed price of $0.042/M. The projected budget was $0.03 for 430 requests. The extra diagnosis at
a batch of 2 doubled the volume.

No database writes. `db/seed_judgments.rb` is intact, and the batched path never touched it.

### 2026-09-21, phase C revised

Batching by subject is not wired in and will not be. What was wired in instead:

- `lib/judge/pool.rb`, new. `Judge::Pool.map(items, concurrency:)` preserves input order, runs
  concurrency 1 inline with no thread, and re-raises the first error after all workers have
  stopped. `Judge::Batch` builds on it, so the threading code exists only once.
- `lib/judge/rails/relation.rb`. `judge_filter`, `judge_map` and `judge_sort` take `concurrency:` and
  fan out over the pool. The `state` values are built on the calling thread before the fan-out, so
  no worker touches an ActiveRecord connection.
- Default: explicit `concurrency:`, otherwise `Judge.config.concurrency`, otherwise 8.

219 tests green against 172 at the start, zero offenses, Rails 7.2, 8.0 and 8.1 green.

### 2026-09-23, labels and arms 7b, 8, 9

Written: `db/ticket_labels.json` (two model annotators, consensus), `lib/tasks/judge_eval.rake`
(`judge:eval:offline`, `named_values`, `criteria`, `rate`). In the gem, `Question::Choice` and
`Question::Noul` accept object or array entries. A string entry keeps its digest, checked against
the three baseline digests. 263 tests green on Rails 7.2, 8.0 and 8.1, zero offenses. Demo: 42 tests
green, zero offenses.

Fixed on re-reading: the gem's README showed `question.digest # => "9e08ebfeb6e0e0fa"` for a choice.
That is the digest of the demo's urgency question. The real value is `1c3be3cf24579b81`.

Pre-registered before any request, run afterwards. The key is read from the shell environment on
each command and never written into the project.

### 2026-09-23, the demo switches to structured criteria

Decided by the owner after arm 8. `app/models/ticket.rb` declares urgency and intent with the arm 8
criteria, word for word. The benches follow without changes, since they read the model's
definitions: `judge_bench.rake` (arms 1 to 7) and `judge_eval.rake`. The gem's two benches,
`bin/arm0_latency` and `bin/bench_batch`, declare the same shape.

**The baseline has changed.** `db/seed_judgments.rb` is regenerated: 250 requests, `jev-1.13.0` on
all 250, urgency digest `4f1911289ec33ca2` and intent digest `4234fcadf9f795b9`, frustration
unchanged at `d3f59e90f1ce9b41`. Against the structured replay from arm 8: 246/250, 250/250 and
243/250, within arm 1's noise. The old baseline is snapshotted in
`wiki/raw/transcripts/seed-judgments-plain-2026-09-23.md`. Any arm replayed from here on is read
against the structured baseline, not the one behind the figures above.

New baseline against the consensus: urgency 88.4% (Brier 0.090), intent 89.6% (0.162), frustration
62.3%. Confident bands: urgency 99.2% on 133, intent 93.9% on 196. No temperature crosses 10% yet
(urgency -6.7%, frustration -9.5%).

`db:seed` on an empty database restores 250 judgments, 0 stale. Demo: 42 tests green, zero offenses.
