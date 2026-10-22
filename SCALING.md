# Scaling & access-control notes

Measured on the current deployment: 426 talks, 11,868 paragraphs, Supabase free tier.

## What is in place

| Concern | Measure |
|---|---|
| Vector search speed | HNSW cosine index on `paragraph_embeddings.embedding` (approximate nearest neighbour; no full scan) |
| Filtered vector search | `hnsw.iterative_scan` so speaker/topic filters still return a full result set instead of ~0 rows |
| Keyword search speed | `pg_trgm` GIN index so `ILIKE '%term%'` uses an index |
| Access control | RLS on every table. Content is readable only by `authenticated`; only `service_role` writes |
| Least privilege | `anon`/`authenticated` hold only the table privileges the app uses (RLS does not cover `TRUNCATE`); search/list functions are not executable by `anon` |
| Secrets | OpenAI key only in Supabase secrets; service key only in git-ignored `config.secret.json` |
| Cost abuse | JWT check, then per-user rate limit in Postgres (embed 120/hr, answer 30/hr), input size caps, relevance gate that skips GPT-4o for irrelevant queries |
| Unbounded growth | `pg_cron` purges `page_views` after 30 days and old rate-limit windows hourly |
| Schema as code | Every change is a versioned migration in `supabase/migrations/` |

## Measured sizes (current)

| Item | Size |
|---|---|
| `paragraph_embeddings` incl. TOAST + indexes | ~200 MB (~17 KB per paragraph) |
| of which HNSW index | 92 MB |
| Free-tier database limit | 500 MB |

Extrapolating linearly, **1M paragraphs is roughly 17 GB**, and the HNSW index (~8 GB) wants to stay in RAM.

## What breaks first at larger scale, and the fix

1. **Storage and index memory.** 1,536 float32 dimensions is ~6 KB per vector. Options: `halfvec` (2 bytes per dim, half the size), or request fewer dimensions from `text-embedding-3-small` (e.g. 512), or quantization. Needs a bigger compute tier either way.
2. **Index build time and write timeouts.** Inserting into HNSW slows as the graph grows; a batch of 100 exceeded the 8 s API statement timeout at ~9k rows. For millions of rows: drop the index, bulk load with `COPY`, rebuild with raised `maintenance_work_mem`, then re-create.
3. **Cold index.** The first search after an index rebuild took 6.6 s (index not in memory) against an 8 s limit. At scale, keep it warm or use a larger instance.
4. **Rate limit design.** Fixed-window counters can allow up to 2x the limit across a window boundary. A sliding window or token bucket would be stricter.
5. **Login email.** Supabase's built-in email is limited to 3 magic links per hour; a real launch needs a custom SMTP provider.
6. **OpenAI cost and limits.** Per-user limits protect against one account; a global daily budget cap (and OpenAI-side spend limits) protects against many.
7. **Extensions in `public`.** `vector` and `pg_trgm` are installed in `public`; Supabase's advisor prefers the `extensions` schema.
