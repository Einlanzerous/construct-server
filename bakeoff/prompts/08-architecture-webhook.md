Design problem — produce a structured design document, no implementation code required (small SQL/Drizzle snippets are fine where they make the design concrete).

I want to add a GitHub webhook receiver to Switchyard.

**Constraints:**

- Webhooks fire frequently (PR events, push events, comment events) — bursts of 10-50 events per second are possible during active development
- Each event takes 50-500ms to process (DB writes, sometimes external API calls)
- Cannot lose events — at-least-once delivery on our side is acceptable; lost events are not
- HMAC validation must happen at the edge (GitHub sends `X-Hub-Signature-256`)
- Switchyard is a single Hono+Bun backend pod (no autoscaling); Postgres 16 is the only datastore
- We do NOT want a new infra component — no Redis, no Kafka, no SQS. Postgres has to be the queue

**Cover, in order, with section headers:**

1. **HTTP handler responsibilities** — what happens between receiving the request and returning 200
2. **Queue data model** — concrete Drizzle/SQL: columns, types, indexes, status states
3. **Worker fetch** — the actual SQL for "claim the next pending event safely under N concurrent workers". This is the meat — be specific about `FOR UPDATE SKIP LOCKED` or whatever you choose, and explain why
4. **Retry & dead-letter** — when do you retry? back-off? when do you give up?
5. **HMAC validation failure** — status code, what (if anything) gets logged or persisted, observability hooks
6. **Failure modes** — what happens if Switchyard restarts mid-processing? Worker crashes? Postgres briefly unavailable?
7. **Trade-offs** — your approach vs Redis Streams, vs in-memory queue with restart-recovery, vs full Kafka. Two sentences each. Honest about what you're giving up

Keep total length around 600-900 words. Specificity over hand-waving — concrete types and SQL, not "we could use a queue."
