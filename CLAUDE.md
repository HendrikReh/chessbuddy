# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ChessBuddy is a hybrid SQL + vector chess retrieval system with pattern detection, written in OCaml 5.1+. It ingests PGN archives, tracks positions with real FEN notation, detects strategic/tactical/endgame patterns, generates embeddings, and stores data in PostgreSQL with pgvector for semantic search.

**Key capabilities:**
- ✅ PGN ingestion with real FEN generation (custom chess engine)
- ✅ Pattern detection framework (strategic, tactical, endgame)
- ✅ Game retrieval by metadata, patterns, players, openings
- ✅ Vector similarity search for positions
- ✅ Comprehensive CLI tools (ingest, retrieve, benchmark)

## Essential Commands

### Build and Format
```bash
dune build          # Compile all code
dune fmt            # Format OCaml files (ocamlformat >= 0.27.0)
dune clean          # Clean build artifacts
```

### Run Tests
```bash
dune runtest                                 # All tests (60 passing)
CHESSBUDDY_REQUIRE_DB_TESTS=1 dune runtest  # Fail if PostgreSQL unavailable
```

### Database Setup
```bash
docker-compose up -d
psql "postgresql://chess:chess@localhost:5433/chessbuddy" -f sql/schema.sql

# Apply migrations
psql "postgresql://chess:chess@localhost:5433/chessbuddy" -f sql/migrations/001_pattern_framework.sql
```

### Ingestion
```bash
# Ingest PGN file
dune exec bin/ingest.exe -- ingest \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --pgn path/to/games.pgn \
  --batch-label "TWIC 1611"

# List batches
dune exec bin/ingest.exe -- batches list --db-uri <URI>

# Show batch details
dune exec bin/ingest.exe -- batches show --db-uri <URI> --id <UUID>
```

### Retrieval
```bash
# Retrieve game by ID
dune exec bin/retrieve.exe -- game \
  --db-uri <URI> \
  --id <game-uuid>

# Search by player
dune exec bin/retrieve.exe -- player \
  --db-uri <URI> \
  --name "Kasparov"

# Query patterns (NEW in v0.0.8)
dune exec bin/retrieve.exe -- pattern \
  --db-uri <URI> \
  --pattern queenside_majority_attack \
  --detected-by white \
  --success true \
  --min-confidence 0.7 \
  --eco-prefix E6 \
  --opening-contains "King's Indian" \
  --min-white-elo 2500 \
  --min-elo-diff 100 \
  --limit 5 \
  --output json
```

### Benchmarks
```bash
# Build benchmark
dune build benchmark/benchmark.exe

# Run with defaults (1 warmup, 3 runs, 100 samples)
dune exec benchmark/benchmark.exe

# Run with custom configuration
dune exec benchmark/benchmark.exe -- \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --warmup 2 \
  --runs 5 \
  --samples 200
```

**Benchmark coverage:**
- **Ingestion**: Full pipeline (100 games), player upsert, FEN dedup
- **Retrieval**: Game fetch, player search, FEN lookup, vector similarity, batch listing
- **Pattern Detection**: Multi-pattern analysis throughput (target: >100 games/sec)

Results include mean, median, min, max, P50/P95/P99 percentiles, and throughput (ops/sec). See `benchmark/README.md` for details.

## Code Architecture

### Module Structure (lib/)

The codebase uses Dune's `include_subdirs unqualified` for functional organization within a single wrapped library:

#### **`core/`** - Domain types and configuration
- `types.ml` - Domain types (Player, Game, Move_feature, Pattern types)
- `env_loader.ml` - Environment variable configuration

#### **`chess/`** - Chess-specific logic
- `chess_engine.ml` - ✅ Lightweight board representation, SAN parser, FEN generation
  - 8x8 array with functional updates (immutable)
  - Supports castling, promotions, captures, disambiguation, en passant
  - Performance: <1ms FEN generation, <0.5ms move application (Apple M2 Pro)
- `fen_generator.ml` - ✅ FEN notation generator (stateful wrapper around chess_engine)
- `pgn_source.ml` - PGN parser; streams games from files
- `pawn_structure.ml` - Pawn majority/minority analysis for pattern detection

#### **`patterns/`** - Pattern detection framework (NEW in v0.0.8)
- `pattern_detector.ml` - Core interface and registry
  - `PATTERN_DETECTOR` module type
  - `Registry` for dynamic detector management
- `strategic_patterns.ml` - Queenside majority attack, minority attack
- `tactical_patterns.ml` - Greek gift sacrifice (Bxh7+)
- `endgame_patterns.ml` - Lucena position, Philidor position

#### **`persistence/`** - Database layer
- `database.ml` - Caqti queries and PostgreSQL connection pool
  - Player/game/position CRUD operations
  - Pattern detection recording and querying
  - `query_games_with_pattern` for advanced filtering

#### **`embedding/`** - Vector embeddings
- `embedder.ml` - FEN → 768-d vector embedding interface
- `openai_client.ml` - OpenAI API integration
- `search_embedder.ml` - Text embedding for natural language search

#### **`search/`** - Semantic search infrastructure
- `search_indexer.ml` - Text document indexing
- `search_service.ml` - Semantic search with entity filtering

#### **`ingestion/`** - Data pipeline
- `ingestion_pipeline.ml` - Orchestrates parsing, dedup, embedding, persistence, pattern detection

### Data Flow

```
PGN File → pgn_source (parse) → chess_engine (board state) → fen_generator (notation)
    ↓
ingestion_pipeline orchestrates:
    1. Player upsert (dedup by FIDE ID)
    2. Game recording (dedup by PGN hash)
    3. Move-by-move processing:
       - FEN generation (chess_engine)
       - FEN deduplication (99.93% typical)
       - Embedding generation (OpenAI)
       - Position recording
    4. Pattern detection (all registered detectors)
    5. Batch metadata (SHA256 checksum)
```

### Test Structure
```
test/
├── test_database.ml          # Database operations (7 tests)
├── test_vector.ml            # Vector/embedding (6 tests)
├── test_chess_engine.ml      # Chess board and moves (16 tests)
├── test_pattern_detectors.ml # Pattern detection (NEW)
├── test_search_service.ml    # Natural language search (2 tests)
├── test_pgn_source.ml        # PGN parser (2 tests)
├── test_retrieve_cli.ml      # Retrieve CLI validation (9 tests)
├── test_ingest_cli.ml        # Ingest CLI validation (12 tests)
├── test_helpers.ml           # Shared fixtures
└── test_suite.ml             # Alcotest-lwt runner
```

**Test status:** ✅ 60+ tests passing (100% pass rate)

## Critical Code Conventions

### Base Prelude (REQUIRED)

Every OCaml module **must** start with `open! Base`. Only use `Stdlib.<module>` when Base intentionally lacks functionality (e.g., file I/O).

```ocaml
open! Base  (* REQUIRED at top of every .ml file *)

(* Use Base conventions with labeled arguments: *)
List.map ~f:fn list                    (* NOT: List.map fn list *)
String.split ~on:',' str               (* NOT: String.split_on_char *)
Option.map ~f:fn opt                   (* use ~f: label *)
List.fold ~init:acc ~f:fn list         (* use ~init: and ~f: *)
```

### Lwt Async Patterns

```ocaml
let ( let+ ) = Lwt.map
let ( let* ) = Lwt.bind

(* Sequential operations: *)
let%lwt result = async_operation () in
process result

(* Sequential iteration: *)
Lwt_list.iter_s (fun item -> process item) items

(* Parallel iteration (use with caution): *)
Lwt_list.map_p (fun item -> async_process item) items
```

### Caqti Database Queries

```ocaml
(* Custom types for PostgreSQL compatibility *)
let uuid =
  let encode uuid = Ok (Uuidm.to_string uuid) in
  let decode str = match Uuidm.of_string str with
    | Some uuid -> Ok uuid
    | None -> Error ("Invalid UUID: " ^ str)
  in
  Caqti_type.(custom ~encode ~decode string)

(* Define and execute queries *)
let query = Caqti_request.find_opt params result_type "SQL HERE" in
let%lwt res = Database.exec pool query params in
or_fail res
```

### Pattern Detector Interface

```ocaml
(* All pattern detectors must implement this interface *)
module type PATTERN_DETECTOR = sig
  val pattern_id : string
  val pattern_name : string
  val pattern_type : [ `Strategic | `Tactical | `Endgame | `Opening_trap ]

  val detect :
    moves:Types.Move_feature.t list ->
    result:string ->
    detection_result Lwt.t

  val classify_success :
    detection:detection_result ->
    result:string ->
    (bool * success_outcome) Lwt.t
end

(* Register patterns at startup *)
let () =
  Pattern_detector.Registry.register (module Strategic_patterns.Queenside_attack);
  Pattern_detector.Registry.register (module Tactical_patterns.Greek_gift);
  (* ... *)
```

## Database Details

**Connection:** `postgresql://chess:chess@localhost:5433/chessbuddy`

**Key tables:**
- `players` - FIDE IDs, normalized names (unique constraint on `full_name_key`)
- `ingestion_batches` - Batch tracking with SHA256 checksums
- `games` - Game metadata, ECO codes, PGN source (hash-based dedup)
- `games_positions` - Move-by-move positions with SAN/UCI/FEN
- `fens` - Unique FEN positions (99.93% dedup rate typical)
- `fen_embeddings` - 768-dimensional vectors for semantic search
- `pattern_catalog` - Registry of available patterns (strategic/tactical/endgame)
- `pattern_detections` - Pattern occurrences with confidence, color, outcome, metadata
- `pattern_validation` - Manual verification workflow for accuracy tracking

**Extensions required:** `uuid-ossp`, `vector`, `pgcrypto`

**Schema documentation:** See `sql/schema.sql` and `docs/ARCHITECTURE_DIAGRAM.md`

## Pattern Detection System

ChessBuddy includes an extensible pattern detection framework supporting strategic, tactical, and endgame patterns.

### Supported Patterns

| Pattern ID | Type | Description |
|-----------|------|-------------|
| `queenside_majority_attack` | Strategic | Pawn majority on a-c files advanced to create passed pawns |
| `minority_attack` | Strategic | Pawn minority attacking opponent majority |
| `greek_gift_sacrifice` | Tactical | Bxh7+ (or Bxh2+) bishop sacrifice |
| `lucena_position` | Endgame | Rook endgame promotion technique |
| `philidor_position` | Endgame | Rook endgame defensive technique |

### Adding New Patterns

1. **Implement detector module:**
   ```ocaml
   module My_pattern : Pattern_detector.PATTERN_DETECTOR = struct
     let pattern_id = "my_pattern"
     let pattern_name = "My Pattern"
     let pattern_type = `Strategic

     let detect ~moves ~result = (* detection logic *)
     let classify_success ~detection ~result = (* success criteria *)
   end
   ```

2. **Register pattern:**
   ```ocaml
   Pattern_detector.Registry.register (module My_pattern)
   ```

3. **Seed database:**
   ```sql
   INSERT INTO pattern_catalog (pattern_id, pattern_name, pattern_type, detector_module, description)
   VALUES ('my_pattern', 'My Pattern', 'strategic', 'My_patterns.My_pattern', 'Description...');
   ```

4. **Use immediately** - No schema changes required! Queries automatically support new patterns.

### Query Examples

```bash
# King's Indian queenside attack
dune exec bin/retrieve.exe -- pattern \
  --pattern queenside_majority_attack \
  --eco-prefix E6 \
  --opening-contains "King's Indian" \
  --min-white-elo 2500 \
  --min-elo-diff 100 \
  --success true \
  --limit 5

# Any tactical pattern by White, 2600+ ELO
dune exec bin/retrieve.exe -- pattern \
  --detected-by white \
  --min-white-elo 2600 \
  --min-confidence 0.8 \
  --success true \
  --limit 10

# Endgame patterns
dune exec bin/retrieve.exe -- pattern \
  --pattern lucena_position \
  --pattern philidor_position \
  --min-confidence 0.5 \
  --limit 10
```

## Testing Strategy

Tests use real PostgreSQL (docker-compose). Each test isolates changes via transactions. Tests skip gracefully when DB unavailable unless `CHESSBUDDY_REQUIRE_DB_TESTS=1` is set.

### Adding New Tests

1. Create test module in `test/`
2. Register in `test/dune` and `test/test_suite.ml`
3. Use Alcotest-lwt for async operations
4. Clean up via transaction ROLLBACK or explicit teardown

### Pattern Detector Tests

Pattern detectors should include:
- **Unit tests** for detection logic with known positions
- **Integration tests** with real PGN games
- **Accuracy validation** against manually labeled datasets
- **Performance benchmarks** for throughput

Example:
```ocaml
let test_queenside_attack_kasparov_kramnik () =
  let pgn = (* Kasparov vs Kramnik 1994 *) in
  let%lwt analysis = Game_analyzer.analyze_game ~game_detail in
  match analysis with
  | Ok result ->
      let detected = List.exists result.detections ~f:(fun d ->
        d.pattern_id = "queenside_majority_attack" && d.success
      ) in
      Alcotest.(check bool) "detected queenside attack" true detected
  | Error msg -> Alcotest.fail msg
```

## Chess Engine Implementation

Custom lightweight chess engine (`lib/chess/chess_engine.ml`) provides:

**Features:**
- ✅ Board representation: 8x8 array with functional updates (immutable)
- ✅ SAN move parsing: Castling, promotions, captures, disambiguation, en passant
- ✅ FEN generation: Complete FEN strings with all metadata fields
- ✅ FEN parsing: Bidirectional conversion (FEN ↔ Board state)
- ✅ Performance: <1ms FEN generation, <0.5ms move application (Apple M2 Pro)

**Status:**
- ✅ Fully integrated with ingestion pipeline
- ✅ Powers real FEN generation (99.93% dedup rate)
- ✅ Module interface (`chess_engine.mli`) fully documented
- ✅ Test suite with 16 test cases (all passing)
- ✅ Benchmarked on TWIC 1611 (428K positions)

**Design decisions:**
- **No move legality validation** - Assumes valid PGN from trusted sources (tournaments)
- **Simplified piece finding** - Brute-force 64-square search (sufficient for <100 moves/game)
- **Functional style** - Pure functions, immutable board state

See `docs/CHESS_ENGINE_STATUS.md` for detailed documentation.

## Current System Status

### ✅ Completed Features

1. **PGN Ingestion Pipeline**
   - Real FEN generation via chess engine
   - Player deduplication (FIDE ID)
   - Game deduplication (PGN hash)
   - Position deduplication (99.93% typical)
   - Batch tracking with checksums

2. **Pattern Detection Framework**
   - Extensible detector interface
   - Pattern registry for dynamic management
   - 5 initial patterns (strategic/tactical/endgame)
   - Confidence scoring (0.0-1.0)
   - Success outcome classification

3. **Retrieval System**
   - Game retrieval by ID, player, batch
   - Pattern query with advanced filtering
   - Multiple output formats (table/JSON/CSV)
   - Rich metadata support

4. **Database Schema**
   - 9 tables with proper indexing
   - Vector extension (pgvector)
   - Pattern detection tables
   - Migration framework

### ⚠️ In Progress

1. **Pattern Validation**
   - Curated test datasets needed
   - Precision/recall tracking
   - False positive review workflow

2. **Embeddings**
   - OpenAI integration functional but requires API key
   - Stub embedder for testing

### 📋 Planned

1. **Monitoring & Observability**
   - Materialized views for pattern statistics
   - Grafana dashboards
   - SLO definitions

2. **Advanced Features**
   - Natural language query parsing
   - Pattern trend analysis
   - Opening repertoire analysis

## Performance Reference

**TWIC 1611 Benchmark** (4.2MB, 4,875 games on Apple M2 Pro):
- **Duration:** 5:27 min (~15 games/sec, ~1,310 positions/sec)
- **Positions:** 428,853 → 301 unique FENs (99.93% dedup)
- **Players:** 2,047 with FIDE IDs

**Chess Engine Performance** (Apple M2 Pro):
- **FEN generation:** 0.62ms avg (<1ms target ✅)
- **Move application:** 0.31ms avg (<0.5ms target ✅)
- **Board clone:** ~0.02ms (pure functional copy ✅)

## Documentation Index

**Core documentation:**
- `README.md` - Project overview and quick start
- `ARCHITECTURE.md` - System architecture and design decisions
- `ARCHITECTURE_DIAGRAM.md` - Visual diagrams (Mermaid)
- `DEVELOPER.md` - Setup, development workflow, testing
- `OPERATIONS.md` - Deployment, monitoring, backups, migrations

**Implementation details:**
- `IMPLEMENTATION_PLAN.md` - Pattern detection roadmap (v3.1)
- `CHESS_ENGINE_STATUS.md` - Chess engine implementation status
- `CHESS_LIBRARY_EVALUATION.md` - Library evaluation rationale
- `OCAML_AI_ASSISTANT_GUIDE.md` - OCaml best practices for AI coding assistants

**Guides:**
- `benchmark/README.md` - Benchmark suite documentation
- `sql/schema.sql` - Database schema with inline comments
- `sql/migrations/` - Schema migration scripts

## Key Principles

1. **Functional-first** - Immutable data structures, pure functions where possible
2. **Type-safe** - Leverage OCaml's type system, avoid option/result abuse
3. **Explicit over implicit** - Labeled arguments, clear function signatures
4. **Performance-conscious** - Profile before optimizing, use benchmarks
5. **Test-driven** - Write tests first, maintain >85% coverage
6. **Documentation** - OCamldoc for all public APIs, README for workflows

## Common Workflows

### Ingest → Analyze → Query

```bash
# 1. Ingest PGN
dune exec bin/ingest.exe -- ingest \
  --db-uri $DB_URI \
  --pgn data/twic1611.pgn \
  --batch-label "TWIC 1611"

# 2. Patterns are detected automatically during ingestion

# 3. Query patterns
dune exec bin/retrieve.exe -- pattern \
  --db-uri $DB_URI \
  --pattern queenside_majority_attack \
  --success true \
  --limit 10
```

### Add New Pattern

```bash
# 1. Implement detector in lib/patterns/
# 2. Register in pattern registry
# 3. Seed database
psql $DB_URI -c "INSERT INTO pattern_catalog ..."

# 4. Re-analyze existing games (optional)
dune exec bin/ingest.exe -- analyze \
  --db-uri $DB_URI \
  --batch-id <UUID> \
  --parallelism 8
```

### Debug Pattern Detection

```bash
# Run with verbose output
dune exec bin/retrieve.exe -- pattern \
  --db-uri $DB_URI \
  --pattern <pattern-id> \
  --include-metadata \
  --output json > debug.json

# Inspect metadata for detection details
```

## Environment Variables

```bash
# Database connection (optional, can use CLI flags)
export CHESSBUDDY_DB_URI="postgresql://chess:chess@localhost:5433/chessbuddy"

# OpenAI API key (required for embeddings)
export OPENAI_API_KEY="sk-..."

# Test database requirement
export CHESSBUDDY_REQUIRE_DB_TESTS=1  # Fail tests if DB unavailable
```

## Troubleshooting

### PostgreSQL Connection Issues
```bash
# Check if PostgreSQL is running
docker-compose ps

# Check logs
docker-compose logs postgres

# Restart container
docker-compose restart postgres
```

### Build Failures
```bash
# Clean build
dune clean && dune build

# Check opam dependencies
opam list --installed

# Update dependencies
opam update && opam upgrade
```

### Test Failures
```bash
# Run single test suite
dune runtest --only test_chess_engine

# Run with verbose output
CHESSBUDDY_REQUIRE_DB_TESTS=1 dune runtest -f
```

---

**Last Updated:** 2025-10-04 (v0.0.8 release)
**Maintained by:** ChessBuddy Development Team
