# ChessBuddy

[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D%205.1-orange.svg)](https://ocaml.org)
[![Version](https://img.shields.io/badge/Version-0.0.9-blue.svg)](RELEASE_NOTES.md)
[![Status](https://img.shields.io/badge/Status-Proof%20of%20Concept-yellow.svg)](https://github.com/HendrikReh/chessbuddy)
[![Build Status](https://img.shields.io/github/actions/workflow/status/HendrikReh/chessbuddy/ci.yml?branch=main)](https://github.com/HendrikReh/chessbuddy/actions)
[![License](https://img.shields.io/github/license/HendrikReh/chessbuddy)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/HendrikReh/chessbuddy)
[![Collaboration](https://img.shields.io/badge/Collaboration-Guidelines-blue.svg)](docs/GUIDELINES.md)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg)](https://github.com/HendrikReh/chessbuddy/graphs/commit-activity)

Retrieval system for chess training that combines a relational database (PGN games) with a vector database (FEN embeddings). Features position-level ingestion with true FEN tracking, automatic deduplication, semantic search, and an extensible pattern-detection pipeline for strategic, tactical, and endgame motifs.

<p align="center">
  <a href="#components">Components</a> •
  <a href="#getting-started">Getting Started</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Dependencies-Lwt%20%7C%20Postgresql%20%7C%20pgvector-blue.svg" alt="Dependencies">
  <img src="https://img.shields.io/badge/Platform-Linux%20%7C%20macOS-lightgrey.svg" alt="Platform">
  <img src="https://img.shields.io/badge/Database-PostgreSQL%2016-336791.svg" alt="PostgreSQL">
  <img src="https://img.shields.io/badge/Chess-PGN%20Ingestion-8B4513.svg" alt="Chess PGN">
</p>

## Components

- **PostgreSQL + pgvector**: Stores players, games, moves, and embeddings. Launch via `docker-compose up -d`.
- **OCaml ingestion service**: Streams PGNs, preserves comments/variations/NAGs per move, generates fully evaluated FENs via the embedded chess engine, and persists relational rows plus embeddings.
- **FEN Generator**: Drives the chess engine to emit accurate board state FEN strings while keeping side-to-move, castling rights, and en-passant squares aligned with the recorded move metadata.
- **Pattern detectors**: Strategic, tactical, and endgame analysers that run during ingestion and populate the `pattern_detections` table with confidence, ply range, initiating colour, and metadata.
- **Schema definition**: `sql/schema.sql` plus migrations bootstrap relational tables, vector indexes, and the pattern framework (`pattern_detections`, `pattern_catalog`).

### Code organisation

`lib/` is split into subdirectories grouped by responsibility and exposed through a single wrapped library via Dune’s `include_subdirs` support:

```text
lib/
  core/          – shared types, environment loaders, helpers
  chess/         – chess engine, FEN generator, PGN parser
  persistence/   – database access layer
  embedding/     – OpenAI client and embedding providers
  search/        – semantic search service and indexer
  ingestion/     – ingestion pipeline orchestration
```

Dune keeps the modules wrapped under the `Chessbuddy` namespace (for example `Chessbuddy.Core.Types`, `Chessbuddy.Search.Search_service`). CLI utilities (`ingest_cli.ml`, `retrieve_cli.ml`) stay at the root so the executables and tests can reuse the same modules.

## Performance (Apple M2 Pro 16GB)

Benchmarked on [TWIC 1611](https://theweekinchess.com/twic) (4.2MB, 4,875 games):

- **Ingestion**: 5:27 minutes (~15 games/sec, ~1,310 positions/sec)
- **Positions tracked**: 428,853 move-level entries (accurate FEN snapshots for every ply)
- **Unique FENs**: ~325k (post-dedup) with vector embeddings
- **Players**: 2,047 with 100% FIDE ID coverage
- **Detections**: 11,400 strategic/tactical/endgame pattern rows across the dataset

**Run performance benchmarks:**
```bash
dune exec benchmark/benchmark.exe -- \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --warmup 2 \
  --runs 5 \
  --samples 200
```

See [benchmark/README.md](benchmark/README.md) for detailed benchmark documentation, configuration options, and performance baselines.

## Getting started

1. Start the database and apply the schema:

   ```bash
   mkdir -p data/db
   docker-compose up -d
   psql "postgresql://chess:chess@localhost:5433/chessbuddy" -f sql/schema.sql
   ```

2. Install dependencies (requires OCaml 5.x):

   ```bash
   opam switch create . 5.1.1
   opam install . --deps-only
   dune build
   ```

3. Run ingestion:

```bash
   dune exec bin/ingest.exe -- \
     --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
     --pgn path/to/games.pgn \
     --batch-label "mega-2024"
```

Set `OPENAI_API_KEY` before using `--enable-search-index`; the ingest CLI will abort early if the key is missing.

The executable streams PGN games, generates true FENs for each position, deduplicates positions, runs all registered pattern detectors, produces embeddings (via a pluggable provider), and persists metadata ready for hybrid SQL + vector search queries.

4. Inspect batches:

   ```bash
   dune exec bin/ingest.exe -- batches list \
     --db-uri postgresql://chess:chess@localhost:5433/chessbuddy

   dune exec bin/ingest.exe -- batches show \
     --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
     --id <BATCH_ID>
   ```

   Each ingestion run records a row in `ingestion_batches` with two identifiers:
   - **Batch label** – human-friendly string you supply via `--batch-label` to tag the run (for example `dev-test`). Labels make logs easier to scan but are not required to be unique.
   - **Batch ID** – UUID primary key generated by PostgreSQL. This value links games, positions, and embeddings to the batch and is what CLI subcommands and SQL joins should use.

   Use the label for readability in dashboards or manual ops, and reach for the UUID when scripting, joining tables, or calling `batches show`.

Checksums are computed from the PGN file contents, so re-ingesting an updated file properly records a new batch. Each stored move retains pre/post comments, side-variations, and NAGs, exposing richer annotations alongside the main line.

## Documentation

### API Reference

All public modules have comprehensive `.mli` interface files with OCamldoc-compatible documentation:

- **[Core Types](lib/core/types.mli)** - Domain models shared across services
- **[Database](lib/persistence/database.mli)** - PostgreSQL persistence layer with Caqti 2.x
- **[Ingestion Pipeline](lib/ingestion/ingestion_pipeline.mli)** - PGN processing and batch management
- **[PGN Source](lib/chess/pgn_source.mli)** - Parser for chess game notation
- **[Chess Engine](lib/chess/chess_engine.mli)** - Lightweight board state tracking and FEN generation
- **[Search Service](lib/search/search_service.mli)** - Natural language semantic search
- **[Search Indexer](lib/search/search_indexer.mli)** - Text document indexing for semantic search
- **[Embedder](lib/embedding/embedder.mli)** - FEN position embedders
- **[FEN Generator](lib/chess/fen_generator.mli)** - Position notation utilities

**Generate HTML documentation:**
```bash
# Requires dependencies installed (opam install . --deps-only)
dune build @doc
# View at: _build/default/_doc/_html/chessbuddy/index.html
```

### Developer Guides

- **[Architecture](docs/ARCHITECTURE.md)** - System design, data flow, module organization, and key decisions
- **[Developer Guide](docs/DEVELOPER.md)** - Setup, testing, CLI usage
- **[Operations Guide](docs/OPERATIONS.md)** - Monitoring, troubleshooting, pattern reanalysis, performance tuning, and disaster recovery
- **[Contribution Guidelines](docs/GUIDELINES.md)** - Coding standards, commit conventions, and workflow
- **[Chess Engine Status](docs/CHESS_ENGINE_STATUS.md)** - Implementation status and testing results
- **[Implementation Plan](docs/IMPLEMENTATION_PLAN.md)** - Development roadmap and progress tracking

## Development guidelines

- All OCaml modules must `open! Base` (or rely on the Base namespace) and only fall back to `Stdlib.<module>` when Base intentionally lacks an equivalent. This keeps the codebase consistent with Jane Street idioms and avoids mixing prelude semantics.
- Run `dune fmt` before submitting patches, and keep module structure aligned with the library layout in `lib/`.
- CLI wiring lives in reusable libraries (`lib/retrieve_cli.ml`, `lib/ingest_cli.ml`) that back both the executables and Alcotest suites. When adding subcommands, update the shared module first and extend the tests under `test/` so parsing behaviour stays covered without hitting a live database.

## Retrieval CLI

Use the `chessbuddy-retrieve` executable for read-side workflows:

- `retrieve similar --db-uri URI --fen FEN --k N` – compute pgvector similarity from a stored FEN embedding.
- `retrieve game --db-uri URI --id UUID [--pgn]` – print game metadata and optionally full PGN.
- `retrieve fen --db-uri URI --id UUID` – inspect a stored FEN with usage counts and embedding info.
- `retrieve player --db-uri URI --name TEXT [--limit N]` – search players by name fragment.
- `retrieve batch --db-uri URI [--id UUID | --label TEXT] [--limit N]` – summarize ingestion batches.
- `retrieve export --db-uri URI --id UUID --out FILE [--k N]` – export a FEN plus optional nearest neighbours to JSON.
- `retrieve pattern --db-uri URI --pattern ID [--detected-by COLOR] [--success BOOL] [--min-confidence F] [--max-confidence F] [--eco-prefix E] [--opening-contains TEXT] [--min-white-elo N] [--max-white-elo N] [--min-black-elo N] [--max-black-elo N] [--min-elo-diff N] [--min/--max-move-count N] [--start-date YYYY-MM-DD] [--end-date YYYY-MM-DD] [--white-name-contains TEXT] [--black-name-contains TEXT] [--result RESULT] [--output {table|json|csv}] [--output-file PATH] [--include-metadata] [--count-only] [--no-summary]` – filter games by detected strategic/tactical/endgame patterns with rich output options.

**Note**: Version 0.0.8 introduces the integrated pattern-detection framework alongside the custom chess engine and benchmarking tools.

## Pattern Query Examples

```bash
# King’s Indian queenside majority attack (original request)
dune exec bin/retrieve.exe -- pattern \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --pattern queenside_majority_attack \
  --detected-by white \
  --success true \
  --eco-prefix E6 \
  --opening-contains "King's Indian" \
  --min-white-elo 2500 \
  --min-elo-diff 100 \
  --min-confidence 0.7 \
  --limit 5 \
  --output table

# Tactical motifs by Black with high confidence
dune exec bin/retrieve.exe -- pattern \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --pattern greek_gift_sacrifice \
  --detected-by black \
  --success true \
  --min-confidence 0.8 \
  --output json --include-metadata

# Endgame study export to CSV
dune exec bin/retrieve.exe -- pattern \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --pattern lucena_position --pattern philidor_position \
  --min-move-count 60 \
  --output csv --output-file endgames.csv
```

---

## Testing

### Manual PostgreSQL Testing

Verify relational and vector database functionality:

```bash
# Test relational operations
psql "postgresql://chess:chess@localhost:5433/chessbuddy" << 'EOF'
INSERT INTO players (full_name, fide_id) VALUES ('Test Player', '123456') RETURNING player_id;
SELECT * FROM players;
EOF

# Test vector operations (pgvector)
psql "postgresql://chess:chess@localhost:5433/chessbuddy" << 'EOF'
INSERT INTO fens (fen_text, side_to_move, castling_rights, material_signature)
VALUES ('test/fen/8/8/8/8/8/8 w - -', 'w', '-', 'TEST') RETURNING fen_id;

INSERT INTO fen_embeddings (fen_id, embedding, embedding_version)
SELECT fen_id, array_fill(0.1::float, ARRAY[768])::vector, 'test-v1'
FROM fens WHERE fen_text = 'test/fen/8/8/8/8/8/8 w - -';

-- Similarity search using cosine distance
SELECT embedding <=> array_fill(0.2::float, ARRAY[768])::vector as distance
FROM fen_embeddings LIMIT 1;
EOF
```

### Automated Testing

Set `CHESSBUDDY_REQUIRE_DB_TESTS=1` to force database-backed tests to run; otherwise they quietly skip when PostgreSQL is unavailable (useful in CI). See [docs/DEVELOPER.md](docs/DEVELOPER.md) for more details.

`dune runtest` now exercises CLI argument parsing alongside database scenarios. The ingest and retrieve command trees are validated via `test/test_ingest_cli.ml` and `test/test_retrieve_cli.ml`, so regressions in Cmdliner wiring are caught without needing Postgres.

**Natural language search tests** live in `test/test_search_service.ml`. They rely on the same PostgreSQL setup and schema as the other integration suites, but use a stub embedder so no network calls are issued. To focus on these cases:

```bash
docker-compose up -d
psql "postgresql://chess:chess@localhost:5433/chessbuddy" -f sql/schema.sql
CHESSBUDDY_REQUIRE_DB_TESTS=1 dune runtest --only-test "Search Service"
```

Dropping the `--only-test` flag runs the full battery, including the new search coverage.

---

