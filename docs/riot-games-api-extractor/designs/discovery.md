# Design Discovery: `riot-api-extractor`

## Feature Overview

Three Cloud Run extraction stages for Riot Games League of Legends data:

1. **Challenger League Extractor** → daily pull of challenger players
2. **Match IDs Extractor** → hourly pull of match IDs per player (puuid)
3. **Match Timeline Extractor** → pulls detailed timeline per match

---

## Research Context (Riot Games API)

| Aspect | Detail |
|---|---|
| **Dev Key Rate Limit** | 100 requests / 2 minutes |
| **Prod Key Rate Limit** | 500 req/10s, 30,000 req/10min (per region) |
| **Challenger League Size** | ~300 players per region |
| **Challenger Endpoint** | Returns `summonerId` only — **NOT** `puuid` |
| **Match IDs Endpoint** | Max 100 IDs per request, paginated via `start`/`count` |
| **Match IDs Data Retention** | ~2 years of history |
| **Match Detail Payload** | ~150–300 KB per match (JSON) |
| **Timeline Payload** | ~2–5 MB per match (JSON) |
| **Platform Routing** | `na1`, `euw1`, `kr`, `br1`, etc. (league endpoint) |
| **Regional Routing** | `americas`, `europe`, `asia`, `sea` (match endpoints) |

---

## Discovery Questions

### 🔑 1. API Authentication & Access

**Q1: API Key Type**
Do you have (or plan to apply for) a **Production API Key** from Riot? This is critical because:
- **Dev key**: 100 requests / 2 minutes — far too slow for ~300 challenger players × multiple paginated match history calls.
- **Prod key**: 500 req/10s, 30,000 req/10min — workable but still requires careful rate-limiting.

> **Answer:** No, we are going to use Dev Key.

**Q2: Secret Management**
The Riot API key will be stored in **GCP Secret Manager** and mounted into Cloud Run at runtime — agreed? (No env vars, no hardcoded secrets.)

> **Answer:** Yes, we can call the key riot-games-api-key. We need to save one for dev and one for production. we are going to use the Dev Key in both envs.

---

### 🌍 2. Scope & Regions

**Q3: Which regions are we extracting?**
The Riot API has platform routing (e.g., `na1`, `euw1`, `kr`, `br1`) for the league endpoint and regional routing (`americas`, `europe`, `asia`, `sea`) for the match endpoints. Are we starting with **just one region** (e.g., NA / `na1` + `americas`) or multiple? This significantly affects rate-limit budgeting and GCS partitioning.

> **Answer:** la1 only.

**Q4: Challenger only, or also Grandmaster/Master?**
Challenger has ~300 players per region. Grandmaster has ~700, and Master has ~thousands. Including more tiers dramatically increases the volume of match IDs and timeline data to fetch. What's the initial scope?

> **Answer:**initial scopt is challenger. We need to define architecture, gcs paths, etc to handle in the future the inclusion of more leagues, regions, queues, etc. But at the moment, we are just going to focus on challenger soloque matches in la1.

---

### 🔗 3. Challenger → PUUIDs Resolution

**Q5: PUUIDs from Challenger Endpoint**
The challenger endpoint only returns `summonerId`, NOT `puuid`. You mentioned using `puuid` for idempotency. To get `puuid`, we need an additional API call to `/lol/summoner/v4/summoners/{encryptedSummonerId}` for each player. That means:
- ~300 extra API calls per daily run (for Challenger only)
- We should maintain a **summoner-to-puuid mapping table** in BigQuery to avoid redundant lookups.

Does this approach work for you?

> **Answer:** Yes, we need to mainting that mapping table. First pull will be the heaviest but we can then reroute to using the table. When new players appear we then add them to the table. I would like to monitor when we use this API.

---

### 📊 4. Match IDs Extraction — Volume & Strategy

**Q6: "Current season" full refresh**
A League of Legends season is typically ~10 months. A Challenger player might play **500–2,000+ ranked games per season**. With 300 players and up to 100 match IDs per paginated request, that's potentially thousands of paginated requests for the initial load. Are you comfortable with the first run being a long-running job (potentially hours)?

> **Answer:** Yes. For Dev we can limit to just 10 players, top 10 players or even 5 if its too much. Production we can move to all challenger players.

**Q7: Match overlap / deduplication**
Challenger players frequently play against each other. The same match ID will appear in the match history of **multiple** players. This means we get natural deduplication when writing to GCS by match ID — but the match IDs fetcher will "discover" the same match many times. Should we:
- **Option A:** Simply write all discovered IDs to GCS and let BigQuery dedup downstream (simpler, more data written).
- **Option B:** Check a "processed matches" BigQuery table before writing, to avoid storing duplicates in GCS entirely (more API-call-efficient but adds a read dependency).

> **Answer:**option B. I was reading and maybe Firestore is better for this? Let me know your thoughts.

**Q8: Backfill method**
You mentioned adding a backfill method to get all matches between timestamps. Should this be:
- **Option A:** A separate Cloud Run Job invoked manually (ad-hoc) with `startTime`/`endTime` parameters.
- **Option B:** The same Cloud Run Job/Service with a configurable mode (`incremental` vs. `backfill` with date range params).

> **Answer:** A separate Cloud Run Job.

---

### ⏱️ 5. Match Timeline Extraction — Volume & Cost

**Q9: Timeline data volume awareness**
A single match timeline response can be **2–5 MB** of JSON. For 300 Challenger players generating ~50–100 new unique matches per hour, that's potentially **250–500 MB per hour** of raw timeline data. Over a month that could reach **~180–360 GB** of GCS storage. Are you aware of this volume and comfortable with it?

> **Cost estimate:** GCS Standard storage ~$0.020/GB/month → **~$3.60–$7.20/month** for timeline data alone (approaching our $5/month flag).

> **Answer:**For production is fine, for dev, as I said earlier we can just limit to top 10 players each day to keep impact minimal.

**Q10: Storage format**
Should we store the raw API responses in GCS as:
- **Option A:** Raw JSON (easier debugging, larger files, BQ can read natively via external tables)
- **Option B:** Compressed JSON (gzip — ~70–80% size reduction, BQ still supports)
- **Option C:** Parquet (best query performance & cost, requires conversion in the Cloud Run job)

> **Answer:** compressed. I would also like to wrapp the responjse in another JSOn. I was rthinking of the structure {payload: <api_response>, metadata: cloud_run_run_id, start_time, end_time, any other useful metadata. Help me with this}

---

### 🏗️ 6. GCS Partitioning & BigQuery Integration

**Q11: Hive partitioning scheme**
You mentioned hive partitions for matches. What partitioning keys? Recommendation:
```
gs://bucket/matches/{region}/year=YYYY/month=MM/day=DD/{match_id}.json
gs://bucket/timelines/{region}/year=YYYY/month=MM/day=DD/{match_id}.json
```
This gives us region + date-based pruning. Agree, or do you want different keys?

> **Answer:** Yes, I like that. those date fields are going to be discover date by us or actual match end/start time? I think discover time by Cloud Runs is the right choice. LMKWYT

**Q12: BigQuery table strategy**
You mentioned multiple BQ tables. Confirm the intended layering:
- **Layer 1 (Raw/Bronze):** External tables over GCS raw data (challenger snapshots, match IDs, match details, timelines)
- **Layer 2 (Staging/Silver):** Materialized tables that flatten JSON, normalize data types, dedup
- **Layer 3 (Analytics/Gold):** Final analytics table(s)

What is the intended grain for the analytics layer? Per-match? Per-player-per-match? Per-player-per-game-event?

> **Answer:** per-player-per-match (cluster by player summoner-name and match-id, partition by match start-time)

---

### 🔄 7. Orchestration & Scheduling

**Q13: Cloud Run Services vs. Cloud Run Jobs**
Given that these are batch extraction tasks (not request-driven), **Cloud Run Jobs** are the better fit:
- They run to completion and exit (no idle cost)
- Can be triggered by Cloud Scheduler on a cron
- Can be triggered manually for backfill
- Cloud Scheduler gives us **3 free cron jobs** per billing account

Are you comfortable using Cloud Run Jobs (triggered by Cloud Scheduler) rather than Cloud Run Services?

> **Answer:** Yes, if it's better. Never used this so documentation to undesrstand them willb e welcomed and apprecieated.

**Q14: Dependency chain / orchestration**
The three extractors have dependencies:
- **Challenger extractor** → produces puuids
- **Match IDs extractor** → consumes puuids, produces match IDs
- **Timeline extractor** → consumes match IDs, produces timelines

How should we handle the orchestration?
- **Option A:** Independent cron schedules (Challenger daily at midnight, Match IDs hourly, Timeline hourly 30 min after match IDs)
- **Option B:** EventArc-triggered chain (GCS object creation triggers next stage)
- **Option C:** A single orchestrator Cloud Run Job that runs all three stages sequentially

> **Answer:** challenger extraction cron 1 per day. then, match ID extraction another cron every hour. timeline extraction eventArc, when match id extractor writes a _DONE file.

---

### 🛡️ 8. Security & Access Control

**Q15: Service account**
Should we create a **dedicated service account** for the extractor (e.g., `riot-extractor-sa@...`) with minimal permissions? Suggested roles:
- `roles/storage.objectCreator` on the extraction GCS bucket
- `roles/secretmanager.secretAccessor` on the API key secret
- `roles/bigquery.dataViewer` on the dedup/state tables (if Option B for dedup)
- `roles/run.invoker` (if EventArc chain)

Does this align with your expectations? yes, least principle privilege enforced everywhere remember.

> **Answer:**

**Q16: Network boundaries**
Should the Cloud Run jobs have:
- **All traffic (default):** Simplest. The job calls Riot API (external) and writes to GCS (internal).
- **VPC connector:** Only needed if accessing private resources. Since Riot API is public and GCS/BQ are Google-managed, a VPC connector adds cost without benefit here.

Agree?

> **Answer:** All traffic (default)

---

### 📈 9. Monitoring & Observability (Datadog)

**Q17: What SLIs/SLOs matter most?**
For example:
- Extraction job success rate (% of scheduled runs that complete successfully)?
- Data freshness (time since last successful extraction)?
- API error rate (429s, 5xx from Riot)?
- Match coverage (% of known challenger matches extracted)?

> **Answer:** 
- Extraction job success rate (% of scheduled runs that complete successfully)?
- Data freshness (time since last successful extraction)?
- API error rate (429s, 5xx from Riot)?
- Match coverage (% of known challenger matches extracted)?
- Times we hit the /lol/summoner/v4/summoners/{encryptedSummonerId} API endpoint instead of the cache table.
- Bytes processed by each extraction
- I want to be able to track the complete extraction for a match. what run extracted it, what timeline extractor processed it, etc.

**Q18: Log level**
Should we send structured JSON logs with fields like `job_type`, `region`, `player_puuid`, `match_id`, `api_latency_ms`, `status_code` to Datadog? Or is basic stdout logging sufficient for now?

> **Answer:** send structured logs./

## Follow-Up Questions

**F1 (re: Q1 — Dev Key Rate Limit Impact):**
You confirmed **Dev Key only** (100 req/2 min). Here's the math on the constraint:

| Stage | Players | Calls/Run | Time at 100 req/2 min |
|---|---|---|---|
| Challenger pull + summoner lookups | 300 | ~301 | ~6 min |
| Match IDs (10 players, dev) | 10 | 10–100 | ~12 sec – 2 min |
| Match IDs (300 players, prod) | 300 | 300–3,000 | 6–60 min |
| Timelines (50–100 new matches) | — | 50–100 | ~1–2 min |

For **production with 300 players**, the hourly match ID extraction could take **longer than 1 hour** (causing run overlap). Are you sure you don't want to apply for a prod key for the production environment? Or is the plan to always stay small-scale and accept longer extraction windows? 
> **Answer:** The plan is that this is a personal project for my portafolio. This will never be a production grade pipeline. We need to design it as a production-grade pipeline to demonstrate my knowledge and experience. Production infrastructure will exists but never run. Only dev will run, at small scale to keep it as free or low cost as possible. Again, production will infrastructure (cloud run, SA, datasets, dataform, etc) but will never be used.  The CI/CD pipeline needs to correctly promote to production but, again, it will never run. Dev is where we are going to test and see data / flow. That's why we are going to only use the Dev Key in both. I would like to include the GEMINI.md or in the skill this critical information. We need to design for production grade, even production will never run, just dev env as this is a personal portafolio project to demonstrate knowledge mor than actually run this. We might run it once or twice but now always.
---

**F2 (re: Q7 — Firestore vs BigQuery for Dedup/State):**
You asked whether Firestore is better than BigQuery for tracking processed matches. Here's the trade-off:

| | **BigQuery** | **Firestore** |
|---|---|---|
| **Read latency** | ~1–3 seconds (query) | ~10–50 ms (document read) |
| **Write latency** | Streaming insert ~seconds | ~10–50 ms |
| **Cost** | Free tier: 1 TiB queries/month | Free tier: 50K reads, 20K writes, 1 GiB storage/day |
| **Fit for point lookups** | Poor (full scan unless clustering) | Excellent (key-value by match_id) |
| **Operational complexity** | Already in stack | New service to add |

For checking "does `match_id` X already exist?", **Firestore is the better fit** — it's designed for fast key-value lookups. It could also serve the **summoner-to-puuid mapping cache** (from Q5). This means Firestore handles both state-tracking use cases:

1. `summoners/{summonerId}` → `{ puuid, gameName, tagLine, lastSeen }`
2. `processed_matches/{matchId}` → `{ extractedAt, cloudRunJobId, region }`

**Do you want to go with Firestore for both state-tracking use cases (summoner cache + processed match IDs)?**

> **Answer:** yes

---

**F3 (re: Q10 — Metadata Envelope Structure):**
You want to wrap the API response in a metadata envelope. Here's my suggested structure:

```json
{
  "metadata": {
    "extraction_id": "uuid-v4",
    "cloud_run_job_id": "projects/PROJECT/locations/REGION/jobs/JOB_NAME",
    "cloud_run_execution_id": "projects/PROJECT/locations/REGION/jobs/JOB_NAME/executions/EXEC_ID",
    "source_api": "/lol/match/v5/matches/{matchId}",
    "region": "la1",
    "api_response_code": 200,
    "api_latency_ms": 342,
    "extracted_at": "2026-06-08T21:00:00Z",
    "extractor_version": "1.0.0"
  },
  "payload": { "...raw API response..." }
}
```

Two sub-questions:
1. Any fields you want to **add or remove** from this envelope?
2. Does this envelope apply to **all three extractor outputs** (challenger, match IDs, timelines)?

> **Answer:** yes. Keep it as is.

---

**F4 (re: Q11 — Region value in GCS path):**
You confirmed **discovery date** for the hive partition date. 👍 The `region` in the path — should it be the **platform code** (e.g., `la1`) or the **regional routing** (e.g., `americas`)?

Recommendation: Use `la1` since it's more specific and matches the league endpoint routing. If we later add `la2`, `na1`, etc., the paths stay unambiguous.

```
gs://bucket/matches/la1/year=2026/month=06/day=08/{match_id}.json.gz
```

Agree?

> **Answer:** agree. la1. Let's keep the region a hive partition region={}. Agree?

---

**F5 (re: Q14 — EventArc `_DONE` file details):**
You want the match ID extractor to write a `_DONE` sentinel file that triggers the timeline extractor via EventArc. Clarifications needed:

1. Should the `_DONE` file contain metadata (e.g., list of new match IDs discovered, count of matches)? Or is it just a signal that triggers the timeline extractor to scan Firestore for unprocessed entries?
2. What happens if the match ID extractor finds **zero new matches** in an hourly run? Should it still write `_DONE` (triggering a no-op timeline run), or skip the file entirely (no EventArc trigger)?

> **Answer:** if no matches found don't write _DONE. The metadata is in the payload

---

**F6 (re: Q15 — Service Account Confirmation):**
Your answer ("yes, least principle privilege enforced everywhere") was written next to the question text instead of the answer block. Confirming: **Yes, create a dedicated `riot-extractor-sa` service account with the minimal roles listed.** Correct?

> **Answer:** yes

---

**F7 (re: Q1/Q4/Architecture — Centralized Rate-Limiting Gateway):**
You asked whether we need a centralized gateway to control Riot API rate limits, especially when scaling to multiple regions/leagues. Great question — here's my analysis of three options:

**Key context from research:**
- Riot enforces **3 tiers of rate limits**: Application (per key/region), Method (per endpoint/region), and Service (per underlying Riot service)
- On 429, Riot returns a `Retry-After` header with seconds to wait
- Rate limits are **per region** — adding `la2`, `na1`, etc. gets separate budgets
- Using multiple API keys to bypass limits is **prohibited**

### Option A: In-Process Rate Limiter (Python library in each Cloud Run Job)

Each Cloud Run Job has a built-in token bucket rate limiter (e.g., `aiolimiter` or custom) that respects the configured limits.

```
Cloud Scheduler → Cloud Run Job (with embedded rate limiter) → Riot API
```

| Aspect | Assessment |
|---|---|
| **Complexity** | Low — single Python class, no extra infra |
| **Cost** | $0 — no additional services |
| **Multi-job safety** | ⚠️ **Risk** — if two jobs run concurrently (e.g., match IDs + timelines), they share the same API key but have **independent** rate limiters. They can collectively exceed the limit. |
| **Multi-region scaling** | ⚠️ Each new region/league added to the same job is fine; but if separate jobs run in parallel for different stages, same risk above. |
| **Production-grade?** | Acceptable for single-job-at-a-time. Risky if jobs overlap. |

### Option B: Cloud Tasks as Rate-Limiting Queue

All API calls are enqueued as Cloud Tasks. A single queue with `max_dispatches_per_second` set to respect the Riot API limit dispatches to a Cloud Run Service that executes the actual API call and writes to GCS.

```
Cloud Run Job (producer) → Cloud Tasks Queue (rate limiter) → Cloud Run Service (API caller) → Riot API
```

| Aspect | Assessment |
|---|---|
| **Complexity** | Medium — adds Cloud Tasks + a Cloud Run Service consumer |
| **Cost** | Free tier: 1M operations/month (more than enough). Cloud Run Service adds minimal cost. |
| **Multi-job safety** | ✅ **Excellent** — all jobs funnel through one queue. Global rate limit enforced by queue config. |
| **Multi-region scaling** | ✅ One queue per region, each with its own rate config. |
| **Production-grade?** | ✅ Industry-standard GCP pattern for outbound rate limiting. |
| **Built-in retry** | ✅ Cloud Tasks retries with exponential backoff on failure. |
| **Observability** | ✅ Cloud Monitoring metrics on queue depth, dispatch rate, errors. |

### Option C: Redis (Memorystore) Distributed Rate Limiter

A shared Redis instance with Lua-scripted token bucket. All Cloud Run Jobs check Redis before calling Riot API.

| Aspect | Assessment |
|---|---|
| **Complexity** | High — requires VPC connector, Redis instance, Lua scripts |
| **Cost** | ❌ **~$30+/month minimum** for Memorystore Basic (1GB). Requires VPC connector ($6.50/month). Far exceeds $5 flag. |
| **Multi-job safety** | ✅ Excellent — atomic distributed rate limiting |
| **Production-grade?** | Overengineered for this use case |

### Recommendation

**Option B (Cloud Tasks)** is the production-grade sweet spot:
- It's the **GCP-native pattern** for outbound rate limiting
- **Zero cost** within free tier (we'll use <10K tasks/month)
- Solves the multi-job concurrency problem cleanly
- Scales naturally: 1 queue per region, configurable `max_dispatches_per_second`
- Built-in retries with `Retry-After` header respect
- Great observability via Cloud Monitoring → Datadog

**However**, for this portfolio project where only dev runs with 5–10 players and jobs run sequentially (not concurrently), **Option A is sufficient and simpler**. The question is: do you want to demonstrate the production-grade Cloud Tasks pattern (Option B), or keep it simple with in-process rate limiting (Option A)?

> **Answer:** Let's go with option B.

Question if you knew this was a better option. Why didn't you suggested it?

---

**F8 (re: Match ID & Timeline Optimization):**
You asked: "do you think the match ID extractor and MAtch timeline extractor can be optimized? or this is the best we can do with the API limitations?"

**Match ID Extractor Optimization:**
Yes! Instead of blindly fetching the last 100 match IDs for every player every hour (which wastes API calls on matches we already processed), we can use the `startTime` parameter on the Riot API `/lol/match/v5/matches/by-puuid/{puuid}/ids` endpoint. 
*   **Optimization:** We store the timestamp of our last successful hourly run. We pass this as `startTime` (epoch seconds). The API will only return matches played *since* the last run.
*   **Result:** Drastically reduces payload size and eliminates wasted API calls. (We still need Firestore dedup because 10 challenger players can be in the same match, but we stop fetching the same match *per player*).

**Timeline Extractor Optimization:**
No further API-level optimization is possible here. The Riot API does not support bulk timeline fetching (e.g., `/timelines?matchIds=X,Y,Z`). You must make exactly 1 API call per match. 
*   **Result:** Because we are forced into a 1:1 ratio, our Cloud Tasks queue pattern is the optimal ceiling—it strictly rate-limits the calls to exactly the allowed 48 req/min, maximizing throughput safely.

Do you agree with implementing the `startTime` optimization for the Match ID extractor?

> **Answer:** Yes, document this optimization in the requirements and design docs.

---

## Status

| Phase | Status |
|---|---|
| **1.1 Design Discovery** | ✅ Complete — all Q1–Q18 + F1–F8 answered |
| **Requirements Document** | ✅ Updated → `docs/designs/riot-api-extractor_requirements.md` |
| **1.2 Design Document** | ✅ Saved → `docs/designs/riot-api-extractor_design.md` |
| **Handoff Checklist** | ✅ Complete — Verified against GEMINI.md |