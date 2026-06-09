# Requirements: Riot API Extractor

## 1. Feature Summary

A multi-stage data extraction pipeline that pulls League of Legends Challenger league data from the Riot Games API and lands it in Google Cloud Storage (GCS) as compressed JSON with metadata envelopes. Three Cloud Run Jobs handle distinct extraction stages: (1) daily Challenger league snapshots with summoner-to-puuid resolution, (2) hourly match ID discovery per player, and (3) EventArc-triggered match timeline extraction. Firestore provides low-latency state tracking for summoner caching and match deduplication. BigQuery external tables expose the raw GCS data, with Dataform transformations producing a per-player-per-match analytics table.

## 2. Stakeholder Decisions

* **API & Credentials**
  * **Q:** What API key type will be used (Dev vs Production)?
    * **A:** Dev Key only (100 requests / 2 minutes). This is a portfolio project — production infrastructure is provisioned but never actively runs. Only the dev environment operates at small scale.
      * **Rationale:** No need for production throughput. Dev key is free and sufficient for 5–10 players. The architecture must still be designed with production-grade rate-limiting, but actual volume will be constrained.
  * **Q:** How will the Riot API key be managed?
    * **A:** GCP Secret Manager with the secret named `riot-games-api-key`. One secret per environment (dev and prod), both containing the Dev Key value.
      * **Rationale:** Follows least-privilege and no-secrets-in-code principles. Secret Manager is free for 6 active secret versions.

* **Scope & Volume Boundaries**
  * **Q:** Which regions are in scope?
    * **A:** `la1` only (platform routing), with `americas` regional routing for match endpoints. Architecture must support adding more regions, leagues, and queues in the future.
      * **Rationale:** Minimizes API calls and cost. GCS paths and Firestore collections include region as a dimension for future extensibility.
  * **Q:** Which league tiers are in scope?
    * **A:** Challenger only (initial scope). Architecture must support Grandmaster, Master, etc. in the future.
      * **Rationale:** Challenger has ~300 players — manageable with Dev Key limits when using a subset (5–10 in dev).
  * **Q:** Are long-running initial loads acceptable for the first season full-refresh?
    * **A:** Yes. Dev environment limits to top 5–10 players. Production would handle all ~300 players but will never actively run.
      * **Rationale:** Portfolio project constraints — demonstrate the architecture, not run at scale.
  * **Q:** How should backfill work?
    * **A:** A separate, dedicated Cloud Run Job invoked manually with `startTime`/`endTime` parameters.
      * **Rationale:** Clean separation of concerns. Backfill is ad-hoc and shouldn't interfere with the scheduled incremental pipeline.

* **Data Extraction & State Tracking**
  * **Q:** How do we resolve puuids from the Challenger endpoint (which only returns summonerId)?
    * **A:** Make `/lol/summoner/v4/summoners/{encryptedSummonerId}` calls with Firestore as the caching layer. First pull is heavy; subsequent runs use the cache. New players trigger cache writes. Monitor cache miss rate (API calls vs cache hits).
      * **Rationale:** Firestore provides ~10–50ms lookups vs ~1–3s for BigQuery. Free tier covers expected volume (50K reads/day, 20K writes/day).
  * **Q:** How should match ID deduplication work?
    * **A:** Firestore (not BigQuery) for state tracking. Check `processed_matches/{matchId}` before writing to GCS. Firestore also handles summoner-to-puuid caching.
      * **Rationale:** Firestore excels at point lookups (10–50ms). Serves both dedup and summoner cache use cases within free tier.
  * **Q:** Can the Match ID or Timeline extractors be further optimized at the API level?
    * **A:** **Match IDs:** Yes. Store the timestamp of the last successful hourly run and pass it as the `startTime` parameter (epoch seconds) to `/lol/match/v5/matches/by-puuid/{puuid}/ids`. This returns only new matches, drastically reducing payload size and wasted API calls. **Timelines:** No further optimization possible; Riot does not support bulk timeline fetching. The Cloud Tasks rate-limiting queue is the optimal pattern for this 1:1 limit.
      * **Rationale:** The `startTime` optimization prevents fetching the same 100 historical matches every hour per player, preserving API rate limits and compute cycles.

* **Data Storage & Analytics**
  * **Q:** What storage format for GCS?
    * **A:** Compressed JSON (gzip) with a metadata envelope wrapping every API response:
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
      This envelope applies to all three extractor outputs.
      * **Rationale:** Gzip provides ~70–80% size reduction; BQ reads gzip natively. Metadata envelope enables full lineage tracking.
  * **Q:** What hive partitioning scheme for GCS?
    * **A:** Partition by discovery date (when Cloud Run extracted, not match time) with region as a hive key:
      ```
      gs://bucket/matches/region=la1/year=YYYY/month=MM/day=DD/{match_id}.json.gz
      gs://bucket/timelines/region=la1/year=YYYY/month=MM/day=DD/{match_id}.json.gz
      ```
      Region uses the platform code (`la1`, not `americas`).
      * **Rationale:** Discovery date is deterministic from the extraction run. Region as hive partition enables future multi-region support. Platform code is more specific than regional routing.
  * **Q:** What BigQuery table layering and analytics grain?
    * **A:** Three layers:
      - **Bronze (Raw):** External tables over GCS raw data
      - **Silver (Staging):** Materialized tables that flatten JSON, normalize data types, dedup
      - **Gold (Analytics):** Per-player-per-match grain, clustered by player summoner name and match ID, partitioned by match start time.
      * **Rationale:** Standard medallion architecture. Per-player-per-match grain supports player performance analysis.
  * **Q:** Are the data volume and storage costs acceptable for timelines?
    * **A:** Yes for production design. Dev limits to top 5–10 players to keep costs minimal.
      * **Rationale:** At full scale (~300 players), timeline storage could reach $3.60–$7.20/month. Dev will be negligible.

* **Infrastructure & Orchestration**
  * **Q:** Cloud Run Services vs Cloud Run Jobs?
    * **A:** Cloud Run Jobs triggered by Cloud Scheduler. User has never used Cloud Run Jobs — documentation and education will be provided during implementation.
      * **Rationale:** Jobs run to completion and exit (no idle cost). Cloud Scheduler provides 3 free cron jobs.
  * **Q:** How are the three extractors orchestrated?
    * **A:** Hybrid approach:
      - **Challenger extractor:** Cloud Scheduler cron, 1x per day
      - **Match IDs extractor:** Cloud Scheduler cron, every hour
      - **Timeline extractor:** EventArc trigger on `_DONE` sentinel file written by match IDs extractor
      - If match IDs extractor finds zero new matches, it does NOT write `_DONE` (no EventArc trigger, no timeline run).
      * **Rationale:** Crons for predictable schedules, EventArc for event-driven chaining. Avoids no-op timeline runs.
  * **Q:** Should we use a centralized rate-limiting gateway to prevent exceeding Riot API limits when multiple jobs run concurrently or when scaling to more regions/leagues?
    * **A:** Yes — Cloud Tasks as the rate-limiting queue. All Riot API calls are enqueued as Cloud Tasks. A queue per region with `max_dispatches_per_second` configured to respect the API key's limits dispatches to a Cloud Run Service that executes the API call and writes results to GCS/Firestore. This replaces direct API calls from Cloud Run Jobs.
      * **Rationale:** Cloud Tasks is the GCP-native pattern for outbound rate limiting. Free tier (1M ops/month) covers our volume. Solves multi-job concurrency (match IDs + timelines sharing one API key). Scales naturally with 1 queue per region. Built-in retry with exponential backoff. Alternative considered: in-process rate limiter (simpler but unsafe with concurrent jobs) and Redis/Memorystore (too expensive at ~$36/month).

* **Security & Networking**
  * **Q:** What service account configuration?
    * **A:** Dedicated `riot-extractor-sa` service account with least-privilege roles:
      - `roles/storage.objectCreator` on the extraction GCS bucket
      - `roles/secretmanager.secretAccessor` on the API key secret
      - `roles/datastore.user` on Firestore (for summoner cache + match dedup)
      - `roles/run.invoker` (for EventArc chain)
      * **Rationale:** Principle of least privilege enforced everywhere.
  * **Q:** What network boundaries for Cloud Run Jobs?
    * **A:** All traffic (default). No VPC connector needed — Riot API is public, GCS/BQ/Firestore are Google-managed services.
      * **Rationale:** VPC connector adds cost (~$6.50/month minimum) without benefit for this architecture.

* **Observability & Monitoring**
  * **Q:** What SLIs/SLOs matter most?
    * **A:** All of the following:
      - Extraction job success rate (% of scheduled runs that complete successfully)
      - Data freshness (time since last successful extraction)
      - API error rate (429s, 5xx from Riot)
      - Match coverage (% of known challenger matches extracted)
      - Summoner API cache miss rate (API calls to `/lol/summoner/v4/` vs Firestore cache hits)
      - Bytes processed by each extraction
      - Full match lineage tracking (which run extracted it, which timeline extractor processed it)
      * **Rationale:** Comprehensive observability demonstrates production-grade monitoring expertise.
  * **Q:** What logging strategy?
    * **A:** Structured JSON logs with fields: `job_type`, `region`, `player_puuid`, `match_id`, `api_latency_ms`, `status_code`, plus extraction lineage fields. Forwarded to Datadog.
      * **Rationale:** Structured logs enable filtering, alerting, and dashboard creation in Datadog.

## 3. Constraints & Boundaries

| Constraint | Value |
|---|---|
| **Riot API Key** | Dev Key: 100 requests / 2 minutes |
| **Target Region** | `la1` (platform) / `americas` (regional routing) |
| **Target League** | Challenger, Ranked Solo/Duo (`RANKED_SOLO_5x5`) |
| **Dev Player Limit** | 5–10 players per extraction run |
| **Cost Ceiling** | GCP Free Tier preferred; flag anything >$5/month |
| **Active Environment** | Dev only (prod provisioned but never runs) |
| **Storage Format** | Gzip-compressed JSON with metadata envelope |
| **State Store** | Firestore (summoner cache + match dedup) |
| **Rate Limiting** | Cloud Tasks queue per region (1M ops/month free tier) |
| **Orchestration** | Cloud Run Jobs + Cloud Scheduler (2 crons) + EventArc (1 trigger) + Cloud Tasks |

## 4. Out of Scope

- Grandmaster, Master, or other league tiers (future extensibility only)
- Multi-region extraction beyond `la1` (future extensibility only)
- Production API Key application or production workload execution
- Real-time / streaming extraction
- Player profile enrichment beyond summoner-to-puuid mapping
- Match detail endpoint (`/lol/match/v5/matches/{matchId}`) — only match IDs and timelines
- Frontend / dashboard / visualization layer
- Alerting automation (Datadog alerts defined in design but PagerDuty/Slack integration is out of scope)

## 5. Open Questions

<!-- EMPTY — All questions resolved. Ready for Phase 1.2. -->
