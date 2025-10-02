# ChessBuddy Performance Benchmarks

Comprehensive benchmark suite for measuring ingestion and retrieval performance.

## Quick Start

```bash
# Build the benchmark
dune build benchmark/benchmark.exe

# Run with defaults
dune exec benchmark/benchmark.exe

# Run with custom configuration
dune exec benchmark/benchmark.exe -- \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --warmup 2 \
  --runs 5 \
  --samples 200
```

## Benchmark Suites

### Ingestion Benchmarks

**1. Full Ingestion Pipeline**
- Measures end-to-end ingestion of 100 games
- Includes: PGN parsing, player upsert, game recording, FEN generation, embedding, position tracking
- Reports: latency distribution (mean, median, min, max, P50, P95, P99), throughput

**2. Player Upsert**
- Benchmarks player insertion and deduplication (1000 players)
- Tests FIDE ID uniqueness constraint and name normalization
- Reports: operations/sec, latency distribution (mean, median, P95, P99)

**3. FEN Deduplication**
- Tests FEN upsert performance (500 unique FENs)
- Compares first insert vs duplicate upsert (ON CONFLICT)
- Reports: deduplication speedup, cache effectiveness

### Retrieval Benchmarks

**Status**: Retrieval benchmarks are not yet implemented in v0.0.5. The focus is currently on ingestion performance measurement. Future versions will add:

- Game retrieval by UUID
- Player search with ILIKE patterns
- FEN lookup by UUID
- Vector similarity search (pgvector)
- Batch listing with pagination

## Configuration Options

| Flag | Default | Description |
|------|---------|-------------|
| `--db-uri` | `postgresql://chess:chess@localhost:5433/chessbuddy` | PostgreSQL connection URI |
| `--pgn` | `data/games/sample.pgn` | PGN file for ingestion (auto-generated if missing) |
| `--warmup` | `1` | Warmup runs (ignored in metrics) |
| `--runs` | `3` | Benchmark runs (averaged) |
| `--samples` | `100` | Number of retrieval samples per benchmark |

## Output Metrics

For each benchmark, reports:
- **Count**: Number of operations
- **Total time**: Cumulative time for all operations
- **Mean**: Average latency per operation
- **Median**: 50th percentile latency
- **Min/Max**: Best and worst case latency
- **P50/P95/P99**: Latency percentiles
- **Throughput**: Operations per second

### Example Output

```
ChessBuddy Performance Benchmark
=================================

Configuration:
  DB URI:           postgresql://chess:chess@localhost:5433/chessbuddy
  PGN Path:         data/games/sample.pgn
  Warmup runs:      2
  Benchmark runs:   5
  Retrieval samples: 200

=== Ingestion Benchmarks ===

Warmup runs (2)...
  Warmup 1/2
  Warmup 2/2

Benchmark runs (5)...
  Run 1/5
  Run 2/5
  Run 3/5
  Run 4/5
  Run 5/5

Full Ingestion (100 games):
  Count:       5
  Total time:  21.34 s
  Mean:        4.27 s
  Median:      4.25 s
  Min:         4.18 s
  Max:         4.39 s
  P50:         4.25 s
  P95:         4.38 s
  P99:         4.39 s
  Throughput:  1.17 /s

=== Player Upsert Benchmark ===

Upserting 1000 players...

Player Upsert:
  Count:       1000
  Total time:  2.34 s
  Mean:        2.34 ms
  Median:      2.28 ms
  Min:         1.89 ms
  Max:         8.45 ms
  P50:         2.28 ms
  P95:         3.12 ms
  P99:         4.56 ms
  Throughput:  427.35 /s

=== FEN Deduplication Benchmark ===

Inserting 500 unique FENs...
Re-upserting same 500 FENs (testing dedup)...

FEN First Insert:
  Count:       500
  Total time:  1.23 s
  Mean:        2.46 ms
  Median:      2.41 ms
  Min:         1.92 ms
  Max:         6.78 ms
  P50:         2.41 ms
  P95:         3.21 ms
  P99:         4.12 ms
  Throughput:  406.50 /s

FEN Duplicate (dedup):
  Count:       500
  Total time:  0.87 s
  Mean:        1.74 ms
  Median:      1.69 ms
  Min:         1.34 ms
  Max:         4.23 ms
  P50:         1.69 ms
  P95:         2.34 ms
  P99:         3.01 ms
  Throughput:  574.71 /s

Deduplication speedup: 1.41x

=== Retrieval Benchmarks ===

Retrieval benchmarks not yet implemented.
Focus on ingestion benchmark for now.

=================================
Total benchmark time: 25.12 s
=================================
```

## Performance Baselines

**Expected performance on Apple M2 Pro (16GB RAM):**

| Benchmark | Throughput | Latency (P50) |
|-----------|-----------|---------------|
| Full Ingestion (100 games) | 0.2-0.3 batches/sec | 3-5 s/batch |
| Player Upsert | 300-500 ops/sec | 2-3 ms |
| FEN Deduplication (first) | 300-500 ops/sec | 2-3 ms |
| FEN Deduplication (dupe) | 400-700 ops/sec | 1.5-2.5 ms |

**Note**: Retrieval benchmarks not yet implemented. Values will be added in future releases.

## Interpreting Results

### Good Performance Indicators
- **Consistent latency**: Low variance between runs (P99 < 2x P50)
- **Linear scaling**: Throughput scales with data size
- **Fast duplicates**: Dedup 2-5x faster than first insert
- **Sub-20ms queries**: Most retrieval operations under 20ms

### Performance Issues
- **High P99**: May indicate GC pauses, connection pool exhaustion, or query planning issues
- **Degrading throughput**: Check for table bloat, missing indexes, or vacuum needed
- **Slow similarity search**: IVFFLAT index may need rebuilding or probes tuning

### Optimization Tips

**For slow ingestion:**
```bash
# Check connection pool size
# Default is 10 - increase for high concurrency
export DATABASE_POOL_SIZE=20

# Disable search indexing for faster ingestion
# (can rebuild index later)
```

**For slow retrieval:**
```sql
-- Rebuild IVFFLAT index with more lists
DROP INDEX IF EXISTS fen_embeddings_vector_idx;
CREATE INDEX fen_embeddings_vector_idx ON fen_embeddings
  USING ivfflat (embedding vector_cosine_ops) WITH (lists = 200);

-- Vacuum and analyze
VACUUM ANALYZE;

-- Check for missing indexes
SELECT schemaname, tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public';
```

## Continuous Benchmarking

Add to CI pipeline:

```yaml
# .github/workflows/benchmark.yml
name: Performance Benchmark

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  benchmark:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: pgvector/pgvector:pg16
        env:
          POSTGRES_PASSWORD: chess
          POSTGRES_USER: chess
          POSTGRES_DB: chessbuddy
        ports:
          - 5432:5432

    steps:
      - uses: actions/checkout@v3

      - name: Setup OCaml
        uses: ocaml/setup-ocaml@v2
        with:
          ocaml-compiler: 5.1.1

      - name: Install dependencies
        run: opam install . --deps-only

      - name: Apply schema
        run: psql postgresql://chess:chess@localhost:5432/chessbuddy -f sql/schema.sql

      - name: Run benchmark
        run: |
          dune exec benchmark/benchmark.exe -- \
            --db-uri postgresql://chess:chess@localhost:5432/chessbuddy \
            --runs 3 \
            --samples 50

      - name: Upload results
        uses: actions/upload-artifact@v3
        with:
          name: benchmark-results
          path: benchmark-*.txt
```

## Profiling

For deeper performance analysis:

```bash
# Profile with perf (Linux)
perf record -g dune exec benchmark/benchmark.exe
perf report

# Profile with Instruments (macOS)
instruments -t "Time Profiler" -D benchmark.trace \
  dune exec benchmark/benchmark.exe

# Memory profiling with statmemprof
OCAML_STATMEMPROF_RATE=1000000 \
  dune exec benchmark/benchmark.exe

# Lwt tracing
LWTTRACE=1 dune exec benchmark/benchmark.exe 2> lwt.trace
```

## Troubleshooting

**"No games in database" error:**
```bash
# Run ingestion first to populate database
dune exec bin/ingest.exe -- ingest \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --pgn data/games/sample.pgn \
  --batch-label "benchmark-data"
```

**Connection refused:**
```bash
# Start PostgreSQL
docker-compose up -d

# Verify connection
psql postgresql://chess:chess@localhost:5433/chessbuddy -c "SELECT 1"
```

**Slow benchmarks:**
- Check CPU/memory usage: `htop` or Activity Monitor
- Verify no other processes using database
- Ensure PostgreSQL has sufficient shared_buffers (at least 256MB)
- Check for disk I/O bottlenecks

## See Also

- [ARCHITECTURE.md](../docs/ARCHITECTURE.md) - System performance characteristics
- [OPERATIONS.md](../docs/OPERATIONS.md) - Performance tuning guide
- [DEVELOPER.md](../docs/DEVELOPER.md) - Local development setup
