# ChessBuddy Operations Guide

This document provides operational procedures for running, monitoring, troubleshooting, and maintaining ChessBuddy in production environments.

## Table of Contents

- [System Monitoring](#system-monitoring)
- [Troubleshooting Guide](#troubleshooting-guide)
- [Performance Tuning](#performance-tuning)
- [Backup & Recovery](#backup--recovery)
- [Maintenance Procedures](#maintenance-procedures)
- [Incident Response](#incident-response)

## System Monitoring

### Health Checks

**Database Connectivity:**
```bash
dune exec bin/ingest.exe -- health check \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy
```

Expected output:
```
✓ PostgreSQL connection successful
✓ Server version: PostgreSQL 16.x
✓ Database: chessbuddy
✓ Extension: vector (enabled)
✓ Extension: pgcrypto (enabled)
✓ Extension: uuid-ossp (enabled)
```

**Extension Verification:**
```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'pgcrypto', 'uuid-ossp');
```

### Key Metrics to Monitor

#### Database Metrics

**Connection Pool Status:**
```sql
SELECT
  count(*) as total_connections,
  count(*) FILTER (WHERE state = 'active') as active,
  count(*) FILTER (WHERE state = 'idle') as idle
FROM pg_stat_activity
WHERE datname = 'chessbuddy';
```

**Table Sizes:**
```sql
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

**Index Health:**
```sql
SELECT
  schemaname,
  tablename,
  indexname,
  idx_scan as scans,
  idx_tup_read as tuples_read,
  idx_tup_fetch as tuples_fetched
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY idx_scan DESC;
```

#### Ingestion Metrics

**Pattern Detection Coverage:**
```sql
SELECT
  pattern_id,
  COUNT(*) FILTER (WHERE success) AS successful,
  COUNT(*) AS total,
  ROUND(AVG(confidence)::numeric, 3) AS avg_confidence,
  COUNT(DISTINCT game_id) AS games_covered
FROM pattern_detections
GROUP BY pattern_id
ORDER BY total DESC;
```

```sql
-- Confidence distribution (bucketed)
SELECT
  pattern_id,
  width_bucket(confidence, 0.0, 1.0, 5) AS bucket,
  COUNT(*)
FROM pattern_detections
GROUP BY pattern_id, bucket
ORDER BY pattern_id, bucket;
```

**Batch Statistics:**
```sql
SELECT
  COUNT(*) as total_batches,
  SUM((SELECT COUNT(*) FROM games WHERE ingestion_batch = batch_id)) as total_games,
  MIN(ingested_at) as first_ingestion,
  MAX(ingested_at) as last_ingestion
FROM ingestion_batches;
```

**Deduplication Rate:**
```sql
SELECT
  COUNT(DISTINCT gp.fen_id) as unique_fens,
  COUNT(*) as total_positions,
  ROUND(100.0 * (1 - COUNT(DISTINCT gp.fen_id)::float / COUNT(*)::float), 2) as dedup_percentage
FROM games_positions gp;
```

**Average Positions per Game:**
```sql
SELECT
  AVG(move_count) as avg_moves,
  MIN(move_count) as min_moves,
  MAX(move_count) as max_moves
FROM (
  SELECT game_id, COUNT(*) as move_count
  FROM games_positions
  GROUP BY game_id
) subq;
```

#### Search Performance Metrics

**Document Index Size:**
```sql
SELECT
  entity_type,
  COUNT(*) as document_count,
  pg_size_pretty(pg_total_relation_size('search_documents')) as index_size
FROM search_documents
GROUP BY entity_type;
```

**Embedding Coverage:**
```sql
SELECT
  COUNT(*) as total_fens,
  COUNT(fe.fen_id) as embedded_fens,
  ROUND(100.0 * COUNT(fe.fen_id) / COUNT(*), 2) as coverage_pct
FROM fens f
LEFT JOIN fen_embeddings fe ON f.fen_id = fe.fen_id;
```

### Performance Baselines

| Operation | Expected Time | Alert Threshold |
|-----------|--------------|-----------------|
| Health check | < 100ms | > 500ms |
| Player search | < 50ms | > 200ms |
| Game retrieval | < 100ms | > 500ms |
| FEN similarity (k=10) | < 50ms | > 200ms |
| Batch ingestion (1K games) | 2-5 min | > 10 min |
| Search query | 250-550ms | > 2s |

## Troubleshooting Guide

### Connection Issues

#### Error: "Connection refused"

**Symptoms:**
```
Error: connection to server at "localhost" (::1), port 5433 failed: Connection refused
```

**Diagnosis:**
```bash
# Check if PostgreSQL is running
docker ps | grep postgres

# Check logs
docker logs chessbuddy-postgres
```

**Solutions:**

1. **Start database:**
   ```bash
   docker-compose up -d
   ```

2. **Check port binding:**
   ```bash
   lsof -i :5433
   # If port in use, change in docker-compose.yml
   ```

3. **Verify network:**
   ```bash
   docker network ls
   docker network inspect chessbuddy_default
   ```

#### Error: "FATAL: password authentication failed"

**Symptoms:**
```
FATAL: password authentication failed for user "chess"
```

**Solutions:**

1. **Verify credentials in docker-compose.yml:**
   ```yaml
   environment:
     POSTGRES_USER: chess
     POSTGRES_PASSWORD: chess
     POSTGRES_DB: chessbuddy
   ```

2. **Reset password:**
   ```bash
   docker exec -it chessbuddy-postgres psql -U postgres
   ALTER USER chess WITH PASSWORD 'newpassword';
   ```

3. **Rebuild container:**
   ```bash
   docker-compose down -v
   docker-compose up -d
   psql "postgresql://chess:chess@localhost:5433/chessbuddy" -f sql/schema.sql
   ```

### Ingestion Issues

#### Error: "index row requires X bytes, maximum size is 8191"

**Symptoms:**
```
ERROR: index row requires 9234 bytes, maximum size is 8191
DETAIL: Values larger than 1/3 of a buffer page cannot be indexed.
```

**Cause:** PGN `source_pgn` field too large for UNIQUE index on `pgn_hash`.

**Solution:**

1. **Already fixed in schema** (v0.0.3+):
   ```sql
   -- Uses pgn_hash instead of source_pgn in constraint
   UNIQUE (white_id, black_id, game_date, round, pgn_hash)
   ```

2. **If using old schema, migrate:**
   ```bash
   # Backup first!
   pg_dump -U chess -h localhost -p 5433 chessbuddy > backup.sql

   # Apply migration
   psql "postgresql://chess:chess@localhost:5433/chessbuddy" <<EOF
   ALTER TABLE games DROP CONSTRAINT IF EXISTS games_white_id_black_id_game_date_round_source_pgn_key;
   ALTER TABLE games ADD CONSTRAINT games_dedup_key
     UNIQUE (white_id, black_id, game_date, round, pgn_hash);
   EOF
   ```

#### Error: "duplicate key value violates unique constraint"

**Symptoms:**
```
ERROR: duplicate key value violates unique constraint "ingestion_batches_checksum_key"
DETAIL: Key (checksum)=(a3f7b2e...) already exists.
```

**Cause:** Same PGN file ingested twice (expected behavior - idempotency).

**Verification:**
```sql
SELECT batch_id, label, source_path, ingested_at
FROM ingestion_batches
WHERE checksum = 'a3f7b2e...';
```

**Solutions:**

1. **Intended re-ingestion** (e.g., updated PGN):
   - Modify PGN file slightly to change checksum
   - Or delete old batch first (see [Batch Deletion](#deleting-a-batch))

2. **Accidental duplicate:**
   - This is working as designed (prevents duplicate work)
   - Check existing batch with `batches show --id UUID`

#### Pattern Detections Missing or Outdated

**Symptoms:**
- `pattern` CLI returns zero games despite known matches
- `pattern_detections` table significantly smaller than expected

**Diagnosis:**
```sql
SELECT COUNT(*) FROM pattern_detections;
SELECT pattern_id, COUNT(*) FROM pattern_detections GROUP BY pattern_id;
```

1. Confirm ingestion version: ensure pipelines were run after v0.0.8 deployment (look at `ingestion_batches.ingested_at`).
2. Check detector registry logs (`stdout` warnings) for failures.
3. Inspect recent application logs for raised exceptions inside detectors.

**Solutions:**
1. **Backfill recent batches:**
   ```bash
   # Re-run ingestion for affected PGNs (idempotent)
   dune exec bin/ingest.exe -- ingest \
     --db-uri $DB_URI \
     --pgn /path/to/file.pgn \
     --batch-label reprocess-$(date +%Y%m%d)
   ```
2. **Manual regeneration script** (when PGN unavailable):
   - Export game IDs with missing detections and write a small OCaml driver invoking `Ingestion_pipeline.process_game` (see Implementation Plan §5 for guidance).
3. **Detector bug fix:**
   - Patch detector logic and re-run ingestion/backfill.

#### Slow Ingestion Performance

**Symptoms:**
- Ingestion taking > 10 minutes per 1,000 games
- High database CPU usage

**Diagnosis:**

1. **Check connection pool:**
   ```sql
   SELECT count(*) FROM pg_stat_activity WHERE datname = 'chessbuddy';
   ```

2. **Check lock contention:**
   ```sql
   SELECT pid, state, wait_event_type, wait_event, query
   FROM pg_stat_activity
   WHERE datname = 'chessbuddy' AND wait_event IS NOT NULL;
   ```

3. **Monitor progress:**
   ```bash
   watch -n 5 "psql 'postgresql://chess:chess@localhost:5433/chessbuddy' -c \
     'SELECT COUNT(*) FROM games; SELECT COUNT(*) FROM games_positions'"
   ```

**Solutions:**

1. **Increase connection pool size:**
   ```ocaml
   (* In ingestion code *)
   let pool = Database.Pool.create ~max_size:20 db_uri
   ```

2. **Disable search indexing during bulk ingestion:**
   ```bash
   # Ingest without --enable-search-index
   dune exec bin/ingest.exe -- ingest \
     --db-uri $DB_URI \
     --pgn large_file.pgn

   # Index separately after
   # (Feature planned)
   ```

3. **Check for missing indexes:**
   ```sql
   SELECT schemaname, tablename, indexname
   FROM pg_indexes
   WHERE schemaname = 'public'
   ORDER BY tablename;
   ```

### Search Issues

#### Error: "OPENAI_API_KEY is not set"

**Symptoms:**
```
Error: OPENAI_API_KEY is not set
```

**Solutions:**

1. **Set environment variable:**
   ```bash
   export OPENAI_API_KEY="sk-..."
   ```

2. **Use .env file:**
   ```bash
   echo "OPENAI_API_KEY=sk-..." > .env
   ```

3. **Verify:**
   ```bash
   dune exec bin/ingest.exe -- ingest --help
   # Check for --api-key option
   ```

#### Slow Search Queries

**Symptoms:**
- Search queries taking > 2 seconds
- High database CPU during search

**Diagnosis:**

1. **Check vector index:**
   ```sql
   SELECT indexname, idx_scan
   FROM pg_stat_user_indexes
   WHERE tablename = 'search_documents';
   ```

2. **Check document count:**
   ```sql
   SELECT COUNT(*) FROM search_documents;
   ```

**Solutions:**

1. **Rebuild vector index:**
   ```sql
   REINDEX INDEX CONCURRENTLY idx_search_documents_embedding;
   ```

2. **Tune IVFFLAT parameters:**
   ```sql
   -- For > 100K documents, increase lists
   DROP INDEX idx_search_documents_embedding;
   CREATE INDEX idx_search_documents_embedding
   ON search_documents USING ivfflat (embedding vector_cosine_ops)
   WITH (lists = 1000);
   ```

3. **Consider HNSW index:**
   ```sql
   -- Better for read-heavy workloads
   DROP INDEX idx_search_documents_embedding;
   CREATE INDEX idx_search_documents_embedding
   ON search_documents USING hnsw (embedding vector_cosine_ops)
   WITH (m = 16, ef_construction = 64);
   ```

### Database Issues

#### Database Disk Space Issues

**Check disk usage:**
```bash
docker exec chessbuddy-postgres df -h
```

**Check PostgreSQL bloat:**
```sql
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) -
                 pg_relation_size(schemaname||'.'||tablename)) AS index_size
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

**Solutions:**

1. **Vacuum database:**
   ```sql
   VACUUM ANALYZE;
   ```

2. **Aggressive vacuum:**
   ```sql
   VACUUM FULL ANALYZE;
   -- Warning: Requires table lock
   ```

3. **Increase Docker volume:**
   ```yaml
   # docker-compose.yml
   volumes:
     - ./data/db:/var/lib/postgresql/data
   ```

## Performance Tuning

### Database Optimization

#### PostgreSQL Configuration

**For development (docker-compose.yml):**
```yaml
environment:
  POSTGRES_SHARED_BUFFERS: 256MB
  POSTGRES_WORK_MEM: 16MB
  POSTGRES_MAINTENANCE_WORK_MEM: 128MB
```

**For production:**
```sql
-- Adjust based on available RAM
ALTER SYSTEM SET shared_buffers = '2GB';
ALTER SYSTEM SET effective_cache_size = '6GB';
ALTER SYSTEM SET maintenance_work_mem = '512MB';
ALTER SYSTEM SET work_mem = '32MB';
ALTER SYSTEM SET max_connections = 100;

-- pgvector-specific
ALTER SYSTEM SET max_parallel_workers_per_gather = 4;

SELECT pg_reload_conf();
```

#### Connection Pool Tuning

**Current default: 10 connections**

**Recommended adjustments:**

| Environment | Pool Size | Rationale |
|------------|-----------|-----------|
| Development | 5-10 | Low concurrency |
| Staging | 20-30 | Moderate load testing |
| Production (single app) | 50-100 | High concurrency |
| Production (multi-app) | 20-30 per app | Shared PostgreSQL |

**Configure in code:**
```ocaml
let pool = Database.Pool.create ~max_size:50 db_uri
```

### Ingestion Optimization

#### Batch Size Tuning

**Current implementation:** Sequential move processing

**Optimization:** Batch inserts (planned)
```ocaml
(* Future: Process moves in batches of 100 *)
let rec process_moves_batched moves =
  match List.split_n moves 100 with
  | batch, [] -> insert_positions_batch pool game_id batch
  | batch, rest ->
      let%lwt () = insert_positions_batch pool game_id batch in
      process_moves_batched rest
```

**Expected impact:** 3-5x throughput improvement

#### Player Cache

**Current implementation:** N+1 queries (2 lookups per game)

**Optimization:** Pre-load player cache
```ocaml
(* Load all unique players before processing games *)
let%lwt player_cache =
  games
  |> extract_unique_players
  |> Lwt_list.map_p (fun (name, fide) ->
      let%lwt id = Database.upsert_player pool ~full_name:name ~fide_id:fide in
      Lwt.return (name, id))
  |> Lwt.map (Map.of_alist_exn (module String))
in
(* Use cached IDs during game processing *)
```

**Expected impact:** 30-40% reduction in database round trips

### Vector Index Tuning

#### IVFFLAT Parameters

```sql
-- Small dataset (< 10K embeddings)
CREATE INDEX ... USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 100);

-- Medium dataset (10K-100K embeddings)
CREATE INDEX ... USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 500);

-- Large dataset (100K-1M embeddings)
CREATE INDEX ... USING ivfflat (embedding vector_cosine_ops)
WITH (lists = 1000);
```

#### HNSW Parameters (Better for Production)

```sql
-- Balanced (default)
CREATE INDEX ... USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- High recall (slower build, faster search)
CREATE INDEX ... USING hnsw (embedding vector_cosine_ops)
WITH (m = 32, ef_construction = 128);

-- Fast build (lower recall)
CREATE INDEX ... USING hnsw (embedding vector_cosine_ops)
WITH (m = 8, ef_construction = 32);
```

## Backup & Recovery

### Database Backup

#### Full Backup

```bash
# Daily backup script
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/chessbuddy"

mkdir -p "$BACKUP_DIR"

docker exec chessbuddy-postgres pg_dump -U chess chessbuddy \
  | gzip > "$BACKUP_DIR/chessbuddy_$DATE.sql.gz"

# Keep last 7 days
find "$BACKUP_DIR" -name "chessbuddy_*.sql.gz" -mtime +7 -delete

echo "Backup completed: chessbuddy_$DATE.sql.gz"
```

#### Incremental Backup (WAL Archiving)

**Configure PostgreSQL:**
```sql
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET archive_mode = 'on';
ALTER SYSTEM SET archive_command = 'cp %p /var/lib/postgresql/wal_archive/%f';
SELECT pg_reload_conf();
```

#### Schema-Only Backup

```bash
pg_dump -U chess -h localhost -p 5433 \
  --schema-only chessbuddy > schema_backup.sql
```

### Recovery Procedures

#### Full Database Restore

```bash
# 1. Stop application
docker-compose down

# 2. Drop and recreate database
docker-compose up -d
docker exec -it chessbuddy-postgres psql -U postgres <<EOF
DROP DATABASE IF EXISTS chessbuddy;
CREATE DATABASE chessbuddy;
EOF

# 3. Restore from backup
gunzip -c /backups/chessbuddy/chessbuddy_20241002.sql.gz | \
  docker exec -i chessbuddy-postgres psql -U chess chessbuddy

# 4. Verify
psql "postgresql://chess:chess@localhost:5433/chessbuddy" -c "\dt"

# 5. Restart application
docker-compose up -d
```

#### Point-in-Time Recovery (PITR)

**Prerequisites:**
- WAL archiving enabled
- Base backup + WAL files available

**Procedure:**
```bash
# 1. Restore base backup
gunzip -c base_backup.sql.gz | psql ...

# 2. Configure recovery
cat > /var/lib/postgresql/data/recovery.conf <<EOF
restore_command = 'cp /var/lib/postgresql/wal_archive/%f %p'
recovery_target_time = '2024-10-02 14:30:00'
EOF

# 3. Restart PostgreSQL
docker restart chessbuddy-postgres

# 4. Verify recovery
psql ... -c "SELECT pg_is_in_recovery();"
```

### Batch-Level Recovery

#### Deleting a Batch

```bash
# 1. Get batch ID
dune exec bin/ingest.exe -- batches list --db-uri $DB_URI

# 2. Delete batch and all related data
psql "postgresql://chess:chess@localhost:5433/chessbuddy" <<EOF
BEGIN;

-- Get games in batch
CREATE TEMP TABLE batch_games AS
SELECT game_id FROM games WHERE ingestion_batch = '<batch_uuid>';

-- Delete positions
DELETE FROM games_positions WHERE game_id IN (SELECT game_id FROM batch_games);

-- Delete games
DELETE FROM games WHERE game_id IN (SELECT game_id FROM batch_games);

-- Delete batch
DELETE FROM ingestion_batches WHERE batch_id = '<batch_uuid>';

COMMIT;
EOF
```

#### Re-ingesting After Corruption

```bash
# 1. Delete corrupted batch
# (see above)

# 2. Re-ingest
dune exec bin/ingest.exe -- ingest \
  --db-uri $DB_URI \
  --pgn /path/to/original.pgn \
  --batch-label "re-ingested-$(date +%Y%m%d)"
```

## Maintenance Procedures

### Routine Maintenance

#### Pattern Backfill (when detectors change)

1. **Identify impacted batches:**
   ```sql
   SELECT batch_id, ingested_at
   FROM ingestion_batches
   WHERE ingested_at < '2025-10-01'  -- example cutoff
   ORDER BY ingested_at DESC;
   ```
2. **Re-run ingestion for each PGN** (preferred): keeps deduplication and embeddings aligned.
3. **Or run targeted backfill script** that fetches stored moves and replays detectors without re-ingesting players/games.
4. **Verify counts**:
   ```sql
   SELECT pattern_id, COUNT(*) FROM pattern_detections GROUP BY pattern_id;
   ```

#### Daily Tasks

1. **Monitor disk space**
2. **Check backup completion**
3. **Review error logs**
4. **Verify recent ingestion batches**

```bash
# Daily health check script
#!/bin/bash
echo "=== ChessBuddy Health Check ==="
echo "Date: $(date)"

# Database size
echo -e "\nDatabase Size:"
docker exec chessbuddy-postgres psql -U chess chessbuddy -c \
  "SELECT pg_size_pretty(pg_database_size('chessbuddy'));"

# Recent batches
echo -e "\nRecent Batches:"
dune exec bin/ingest.exe -- batches list --db-uri $DB_URI --limit 5

# Connection count
echo -e "\nActive Connections:"
docker exec chessbuddy-postgres psql -U chess chessbuddy -c \
  "SELECT count(*) FROM pg_stat_activity WHERE datname = 'chessbuddy';"
```

#### Weekly Tasks

1. **VACUUM ANALYZE**
   ```sql
   VACUUM ANALYZE;
   ```

2. **Rebuild statistics**
   ```sql
   ANALYZE;
   ```

3. **Review slow queries**
   ```sql
   SELECT query, calls, total_time, mean_time
   FROM pg_stat_statements
   ORDER BY mean_time DESC
   LIMIT 10;
   ```

4. **Check index usage**
   ```sql
   SELECT
     schemaname, tablename, indexname, idx_scan
   FROM pg_stat_user_indexes
   WHERE idx_scan = 0 AND schemaname = 'public';
   ```

#### Monthly Tasks

1. **Full backup verification** (restore to test environment)
2. **Capacity planning review**
3. **Performance baseline update**
4. **Security audit** (check for exposed credentials)

### Database Maintenance

#### Reindexing

```sql
-- Concurrent reindex (no downtime)
REINDEX INDEX CONCURRENTLY idx_games_dedup;
REINDEX INDEX CONCURRENTLY idx_fens_text;

-- Full reindex (requires downtime)
REINDEX DATABASE chessbuddy;
```

#### Vacuuming Strategy

```sql
-- Regular vacuum (no table lock)
VACUUM ANALYZE games;
VACUUM ANALYZE games_positions;

-- Aggressive vacuum (requires table lock)
-- Run during maintenance window
VACUUM FULL games_positions;
```

## Incident Response

### Severity Levels

| Level | Response Time | Examples |
|-------|--------------|----------|
| **P0 - Critical** | Immediate | Database down, data corruption |
| **P1 - High** | < 1 hour | Ingestion failed, search broken |
| **P2 - Medium** | < 4 hours | Slow queries, high CPU |
| **P3 - Low** | < 1 day | Missing indexes, minor bugs |

### Incident Response Checklist

#### For Critical Issues (P0)

1. ☐ **Assess impact** (users affected, data at risk)
2. ☐ **Stop ingestion** if data corruption suspected
3. ☐ **Take immediate backup**
   ```bash
   pg_dump -U chess -h localhost -p 5433 chessbuddy | \
     gzip > emergency_backup_$(date +%s).sql.gz
   ```
4. ☐ **Check recent changes** (git log, recent ingestions)
5. ☐ **Review logs**
   ```bash
   docker logs chessbuddy-postgres --tail 1000
   ```
6. ☐ **Isolate issue** (single batch? specific query?)
7. ☐ **Implement fix**
8. ☐ **Verify recovery**
9. ☐ **Post-mortem documentation**

#### For High Priority Issues (P1)

1. ☐ **Identify root cause**
2. ☐ **Check if workaround available**
3. ☐ **Implement fix or workaround**
4. ☐ **Monitor for recurrence**
5. ☐ **Document issue and solution**

### Common Emergency Scenarios

#### Scenario: Database Corruption

**Symptoms:**
- Unexpected NULL values
- Constraint violations on valid data
- Checksum errors in logs

**Response:**
```bash
# 1. Stop all writes immediately
docker-compose stop

# 2. Attempt repair
docker exec chessbuddy-postgres psql -U postgres <<EOF
REINDEX DATABASE chessbuddy;
VACUUM FULL;
EOF

# 3. If repair fails, restore from backup
# (see Recovery Procedures)
```

#### Scenario: Out of Disk Space

**Symptoms:**
- "No space left on device"
- Failed writes

**Response:**
```bash
# 1. Check space
docker exec chessbuddy-postgres df -h

# 2. Emergency cleanup
docker exec chessbuddy-postgres psql -U chess chessbuddy <<EOF
-- Delete oldest embeddings (can regenerate)
DELETE FROM fen_embeddings WHERE fen_id IN (
  SELECT fe.fen_id FROM fen_embeddings fe
  LEFT JOIN games_positions gp ON gp.fen_id = fe.fen_id
  WHERE gp.fen_id IS NULL
);
VACUUM FULL;
EOF

# 3. Increase volume size (if using Docker)
# Stop container, modify docker-compose.yml, restart
```

---

## Quick Reference

### Essential Commands

```bash
# Health check
dune exec bin/ingest.exe -- health check --db-uri $DB_URI

# Batch summary
dune exec bin/ingest.exe -- batches show --db-uri $DB_URI --id <UUID>

# Pattern query
 dune exec bin/retrieve.exe -- pattern \
   --db-uri $DB_URI --pattern queenside_majority_attack \
   --success true --min-confidence 0.7 --limit 10

# Database backup
docker exec chessbuddy-postgres pg_dump -U chess chessbuddy | gzip > backup.sql.gz

# Restore
gunzip -c backup.sql.gz | docker exec -i chessbuddy-postgres psql -U chess chessbuddy

# Vacuum
psql $DB_URI -c "VACUUM ANALYZE;"

# Reindex
psql $DB_URI -c "REINDEX DATABASE chessbuddy;"
```

### Useful SQL Queries

```sql
-- Top 10 largest tables
SELECT tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename))
FROM pg_tables WHERE schemaname = 'public' ORDER BY pg_total_relation_size DESC LIMIT 10;

-- Slow queries (requires pg_stat_statements)
SELECT query, calls, mean_time FROM pg_stat_statements ORDER BY mean_time DESC LIMIT 10;

-- Lock contention
SELECT * FROM pg_locks WHERE NOT granted;

-- Index usage
SELECT * FROM pg_stat_user_indexes WHERE idx_scan < 100;
```

---

## See Also

- [Architecture](ARCHITECTURE.md) - System design and data flow
- [Developer Guide](DEVELOPER.md) - Setup and testing
- [Guidelines](GUIDELINES.md) - Coding standards
- [Implementation Plan](IMPLEMENTATION_PLAN.md) - Pattern detection roadmap and milestones
