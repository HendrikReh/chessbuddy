# Developer Guide

## Recent Changes (v0.0.8)

### New Features

**Library modularisation (October 2025):**
- ✅ `lib/` reorganised into functional subdirectories (`core`, `chess`, `persistence`, `embedding`, `search`, `ingestion`)
- ✅ Dune uses `include_subdirs unqualified`, keeping a single wrapped library while exposing modules as `Chessbuddy.<Domain>.<Module>`
- ✅ README and architecture docs updated with the new layout

**Chess Engine Integration:**
- ✅ `Fen_generator` now drives `Chess_engine.Move_parser.apply_san` to emit accurate board-state FENs for every move
- ✅ En passant capture and castling rights tracking fixed as part of the integration
- ✅ `dune runtest` covers the engine + ingestion path end-to-end (all chess engine tests now passing)

**Documentation & Tooling refresh:**
- ✅ README badges bumped to v0.0.8 with the new directory map
- ✅ Release notes capture the modular layout changes
- ✅ Developer guide updated (this document)

### Breaking Changes

None – module names remain unchanged thanks to `include_subdirs unqualified`. Projects depending on `Chessbuddy` should continue to compile without edits.

### Performance Impact

- FEN generation and move application continue to meet targets (<1 ms / <0.5 ms respectively)
- Real board tracking reduces FEN deduplication efficiency (expected compared to placeholder approach)
- Throughput continues to hover around ~15 games/sec on the reference hardware

### Migration Notes

**For developers:**
1. Update any hard-coded filesystem references to point to the new subdirectories (for example `lib/chess/chess_engine.ml`)
2. When adding modules, place them in the appropriate domain folder and let Dune pick them up automatically
3. The chess engine is fully wired into ingestion – run `dune runtest` before pushing to ensure board regressions are caught early

**For users:**
No CLI or schema changes. Binary behaviour remains the same aside from more accurate FEN metadata.

## Module Organization (v0.0.8)

The codebase uses a **functional subdirectory structure** with Dune's `include_subdirs unqualified`:

```
lib/
├── core/          # Domain types (types.ml, env_loader.ml)
├── chess/         # Chess logic (chess_engine.ml, fen_generator.ml, pgn_source.ml)
├── persistence/   # Database (database.ml)
├── embedding/     # Embeddings (embedder.ml, openai_client.ml, search_embedder.ml)
├── search/        # Search (search_service.ml, search_indexer.ml)
└── ingestion/     # Pipeline (ingestion_pipeline.ml)
```

**Key points:**
- All modules remain accessible with original names (e.g., `Types`, `Database`, `Chess_engine`)
- Single wrapped library under `Chessbuddy` namespace
- No circular dependencies due to unqualified include mode
- Clean separation of concerns by domain

## API Documentation

### Module Interfaces (.mli files)

All public modules have comprehensive interface files with OCamldoc-compatible documentation:

| Module | Purpose | Key Types | Status |
|--------|---------|-----------|--------|
| [database.mli](../lib/persistence/database.mli) | PostgreSQL persistence with Caqti 2.x | `Pool.t`, `batch_summary`, `game_detail`, `fen_info` | ✅ Stable |
| [ingestion_pipeline.mli](../lib/ingestion/ingestion_pipeline.mli) | PGN ingestion orchestration | `EMBEDDER`, `PGN_SOURCE`, `inspection_summary` | ✅ Stable |
| [pgn_source.mli](../lib/chess/pgn_source.mli) | Chess game notation parser | `header_map`, `Default` module | ✅ Stable |
| [chess_engine.mli](../lib/chess/chess_engine.mli) | Board state tracking and FEN generation | `Board.t`, `Move_parser`, `Fen` | ✅ Stable |
| [search_service.mli](../lib/search/search_service.mli) | Natural language search | Entity filters, similarity ranking | ✅ Stable |
| [search_indexer.mli](../lib/search/search_indexer.mli) | Text document indexing | `TEXT_EMBEDDER`, entity summarization | ✅ Stable |
| [embedder.mli](../lib/embedding/embedder.mli) | FEN position embedders | `PROVIDER`, `Constant` stub | ✅ Stable |
| [fen_generator.mli](../lib/chess/fen_generator.mli) | Position notation generation | Game-state-aware FEN utilities | ✅ Stable |

### Generating HTML Documentation

```bash
# Install dependencies first
opam install . --deps-only

# Build API docs (requires PostgreSQL libraries available)
dune build @doc

# View generated docs
open _build/default/_doc/_html/chessbuddy/index.html
# Or browse to file:///<project_path>/_build/default/_doc/_html/chessbuddy/index.html
```

**Note:** Documentation generation requires `libpq` (PostgreSQL client library) to be available via `pkg-config`. On macOS with Homebrew:

```bash
brew install libpq
export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"
dune build @doc
```

### Publishing to GitHub Pages

Add this to `.github/workflows/ci.yml` to automatically publish docs:

```yaml
docs:
  name: Build and Deploy Documentation
  runs-on: ubuntu-latest
  needs: build
  if: github.ref == 'refs/heads/main'
  steps:
    - name: Checkout
      uses: actions/checkout@v4

    - name: Set up OCaml
      uses: ocaml/setup-ocaml@v3
      with:
        ocaml-compiler: 5.2.x

    - name: Install dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y libpq-dev
        opam install . --deps-only --yes

    - name: Build documentation
      run: opam exec -- dune build @doc

    - name: Deploy to GitHub Pages
      uses: peaceiris/actions-gh-pages@v3
      with:
        github_token: ${{ secrets.GITHUB_TOKEN }}
        publish_dir: ./_build/default/_doc/_html
        destination_dir: api
```

## Architecture Overview

> **📐 For comprehensive architecture documentation, see [ARCHITECTURE.md](ARCHITECTURE.md)**
>
> This includes: system design, module organization, data flow diagrams, database schema,
> key design decisions, extension points, and performance characteristics.

**Quick Summary:**

Chessbuddy ingests PGN archives, normalizes player and game data, and persists
search-ready artifacts in PostgreSQL with pgvector. The diagram below maps the
primary modules and how data flows between them during a typical ingestion run.

```mermaid
flowchart LR
  CLI["Ingest CLI\n(bin/ingest.exe)"] -->|CLI args| Pipeline
  Pipeline["Ingestion Pipeline\n(lib/ingestion/ingestion_pipeline.ml)"] -->|streams PGN| Pgn
  Pgn["PGN Source\n(lib/chess/pgn_source.ml)"] -->|moves & metadata| Pipeline
  Pipeline -->|players & games| Database
  Pipeline -->|positions| Fen
  Fen["FEN Generator\n(lib/chess/fen_generator.ml)"] -->|FENs| Pipeline
  Pipeline -->|embedding requests| Embedder
  Embedder["Embedder\n(lib/embedding/embedder.ml)"] -->|vectors| Pipeline
  Database["PostgreSQL\n(sql/schema.sql)"] -->|pgvector storage| Vector
  Pipeline -->|batch bookkeeping| Database
  Pipeline -->|position embeddings| Vector
  Vector["pgvector\n(fen_embeddings)"] -->|similarity search| Pipeline
```

- `bin/ingest.exe` reads CLI options, resolves the database URI, and hands the
  PGN source to the pipeline.
- `ingestion_pipeline.ml` coordinates database transactions, deduplication, and
  calls into supporting modules.
- `pgn_source.ml` parses headers and moves, emitting structured games.
- `fen_generator.ml` uses the chess engine to track board state and emit accurate FENs for every move.
- `embedder.ml` converts unique FENs into 768-d vectors for semantic queries.
- `sql/schema.sql` defines relational tables and pgvector-backed similarity
  capabilities.

### Ingestion Sequence

```mermaid
sequenceDiagram
  participant CLI as Ingest CLI
  participant Pipe as Pipeline
  participant PGN as PGN Source
  participant FEN as FEN Generator
  participant EMB as Embedder
  participant DB as PostgreSQL
  participant VEC as pgvector

  CLI->>Pipe: Parse CLI args and batch label
  Pipe->>PGN: Stream PGN headers and moves
  PGN-->>Pipe: Emit structured games
  Pipe->>DB: Upsert players and batches
  Pipe->>DB: Record game metadata
  Pipe->>FEN: Request FEN before/after move
  FEN-->>Pipe: Return placeholder FEN strings
  Pipe->>EMB: Deduplicated FEN needs embedding?
  EMB-->>Pipe: 768-d vector result (async)
  Pipe->>DB: Insert moves, positions, and joins
  Pipe->>VEC: Persist embeddings via pgvector
  DB-->>Pipe: Transaction commit
  Pipe-->>CLI: Report batch summary
```

The sequence highlights when each module participates, the order of database
writes, and how pgvector storage happens only after deduplicating FENs.

## Code conventions

- All OCaml modules must `open! Base` (or otherwise rely on Base-prefixed modules) so the Jane Street prelude is consistently applied across the codebase. Reach for `Stdlib.<module>` only when Base intentionally omits equivalent functionality (e.g., filename helpers).
- Keep module layout aligned with `lib/` and expose public interfaces through `lib/chessbuddy.ml`.

## CLI Usage

Running `dune exec bin/ingest.exe --` now expects a subcommand. Invoking the binary
without arguments prints the list of available commands, mirroring
`chessbuddy help`.

**Command summary:**
- `chessbuddy ingest --db-uri URI --pgn FILE [--batch-label LABEL] [--dry-run]`
  - Ingest a PGN file. `--dry-run` parses and reports counts without touching
    the database.
- `chessbuddy batches list --db-uri URI [--limit N]`
  - Show recent ingestion batches along with labels and timestamps.
- `chessbuddy batches show --db-uri URI --id UUID`
  - Display batch-level metrics (games, positions, embeddings).
- `chessbuddy players sync --db-uri URI --from-pgn FILE`
  - Upsert unique player identities from a PGN without recording games.
- `chessbuddy health check --db-uri URI`
  - Verify connectivity and required extensions (`vector`, `pgcrypto`,
    `uuid-ossp`).
- `chessbuddy help [COMMAND]`
  - Describe commands and their parameters; equivalent to running with no args.

The retrieval CLI mirrors this structure via `chessbuddy-retrieve`:
- `retrieve similar --db-uri URI --fen FEN [--k N]` – vector similarity lookup.
- `retrieve game --db-uri URI --id UUID [--pgn]` – print stored headers and PGN.
- `retrieve fen --db-uri URI --id UUID` – inspect a FEN record and embedding.
- `retrieve player --db-uri URI --name TEXT [--limit N]` – fuzzy player search.
- `retrieve batch --db-uri URI [--id UUID | --label TEXT] [--limit N]` – summarize recent batches.
- `retrieve export --db-uri URI --id UUID --out FILE [--k N]` – JSON export for downstream tools.

**Embedding configuration:** Set `OPENAI_API_KEY` (or provide `--api-key` when wiring a custom provider) before enabling natural-language search via `--enable-search-index`; the ingest CLI will fail fast if the key is missing.

**Examples:**
```bash
dune exec bin/ingest.exe -- ingest \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --pgn data/games/twic1611.pgn \
  --batch-label dev-test

dune exec bin/ingest.exe -- ingest --dry-run \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --pgn data/games/twic1611.pgn

dune exec bin/ingest.exe -- batches list \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy
```

### CLI modules and tests

Both CLIs expose their Cmdliner wiring through dedicated libraries. `lib/ingest_cli.ml`
compiles to `chessbuddy.ingest_cli`, while `lib/retrieve_cli.ml` exposes
`chessbuddy.retrieve_cli`. The executables re-export `Ingest_cli.run ()` and
`Retrieve_cli.run ()`, and the Alcotest suites import the same modules to
exercise argument parsing without spinning up a database.

When you add or modify subcommands:
- extend the corresponding `*_cli.ml` module so the executable and tests stay in sync;
- update `test/test_ingest_cli.ml` or `test/test_retrieve_cli.ml` with new
  expectations for help text or required flags;
- keep the helper lists (`command_names ()`) in step with the public CLI surface
  to catch forgotten registrations.

`dune runtest` will fail fast if the Cmdliner spec drifts, giving feedback before
running any integration scenarios.

## PostgreSQL Testing

### Database Setup

The project uses PostgreSQL 16 with pgvector extension for hybrid relational + vector storage.

**Connection details:**
- Host: `localhost:5433`
- Database: `chessbuddy`
- User/Password: `chess/chess`
- Connection string: `postgresql://chess:chess@localhost:5433/chessbuddy`

**Starting the database:**

```bash
mkdir -p data/db
docker-compose up -d
psql "postgresql://chess:chess@localhost:5433/chessbuddy" -f sql/schema.sql
```

Persistent storage lives in `data/db/`, so container restarts or image upgrades keep the Postgres instance intact.

### Schema Components

The schema (`sql/schema.sql`) includes:

**Relational tables:**
- `players` - Player information with FIDE IDs and normalized names
- `player_ratings` - Historical ELO ratings (standard, rapid, blitz)
- `ingestion_batches` - Batch metadata with checksums for deduplication
- `games` - Game metadata with ECO codes, openings, results, and SHA256 hash for deduplication
- `games_positions` - Move-by-move position data with SAN/UCI notation and FEN tracking
- `game_themes` - Thematic analysis and motif tags

**Vector tables:**
- `fens` - Unique FEN positions with material signatures
- `fen_embeddings` - 768-dimensional embeddings for semantic search

**Features:**
- Foreign key constraints ensure referential integrity
- Unique constraints on FIDE IDs and normalized player names
- Generated columns for case-insensitive name matching and PGN hash (pgcrypto extension)
- 18 indexes for query optimization including GIN indexes for arrays
- Materialized view for latest player ratings
- pgvector extension for similarity search with IVFFLAT indexes (see `sql/schema.sql`)

### Ingestion Pipeline Notes

- Batch checksums are derived from the PGN file bytes, so updating an existing file produces a new ingestion batch instead of reusing the previous checksum.
- FEN rows now mirror the metadata stored alongside each move: the active color, castling rights, and en-passant square come straight from the generated `fen_after`.
- `Types.Move_feature` carries PGN annotations (comments, variations, and NAGs). They are available to downstream components such as future motif extraction or export tooling.

### Manual Testing

**Test relational operations:**

```bash
psql "postgresql://chess:chess@localhost:5433/chessbuddy" << 'EOF'
-- Insert player
INSERT INTO players (full_name, fide_id)
VALUES ('Magnus Carlsen', '1503014')
RETURNING player_id;

-- Insert rating
INSERT INTO player_ratings (player_id, rating_date, standard_elo, rapid_elo)
SELECT player_id, '2024-01-01', 2830, 2820
FROM players WHERE fide_id = '1503014';

-- Query with joins
SELECT p.full_name, pr.standard_elo
FROM players p
JOIN player_ratings pr ON p.player_id = pr.player_id;
EOF
```

**Test vector operations:**

```bash
psql "postgresql://chess:chess@localhost:5433/chessbuddy" << 'EOF'
-- Insert FEN position
INSERT INTO fens (fen_text, side_to_move, castling_rights, material_signature)
VALUES ('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -', 'w', 'KQkq', 'PPPPPPPPPPPPPPPP')
RETURNING fen_id;

-- Insert 768-dimensional embedding
INSERT INTO fen_embeddings (fen_id, embedding, embedding_version)
SELECT fen_id, array_fill(0.1::float, ARRAY[768])::vector, 'v1'
FROM fens WHERE fen_text LIKE '%rnbqkbnr/pppppppp%';

-- Test cosine similarity search
SELECT f.fen_text,
       fe.embedding <=> array_fill(0.15::float, ARRAY[768])::vector as distance
FROM fens f
JOIN fen_embeddings fe ON f.fen_id = fe.fen_id
ORDER BY distance
LIMIT 5;

-- Test L2 distance
SELECT fe.embedding <-> array_fill(0.2::float, ARRAY[768])::vector as l2_distance
FROM fen_embeddings fe LIMIT 1;

-- Test inner product
SELECT fe.embedding <#> array_fill(0.2::float, ARRAY[768])::vector as neg_inner_prod
FROM fen_embeddings fe LIMIT 1;
EOF
```

**Verify constraints:**

```bash
psql "postgresql://chess:chess@localhost:5433/chessbuddy" << 'EOF'
-- This should fail: wrong vector dimension
INSERT INTO fens (fen_text, side_to_move, castling_rights, material_signature)
VALUES ('test/8/8/8/8/8/8/8 w - -', 'w', '-', 'TEST')
RETURNING fen_id;

INSERT INTO fen_embeddings (fen_id, embedding, embedding_version)
SELECT fen_id, array_fill(0.5::float, ARRAY[512])::vector, 'test'
FROM fens WHERE fen_text LIKE 'test/%';
-- Expected error: "expected 768 dimensions, not 512"
EOF
```

## Automated Testing with Alcotest

Set `CHESSBUDDY_REQUIRE_DB_TESTS=1` locally when you want the suite to fail fast if the PostgreSQL container is missing. CI leaves this unset so tests fall back to skipping when the database is unavailable.

### Recommendation: Yes, Add Integration Tests

**Why Alcotest:**
- Lightweight and idiomatic for OCaml
- Good integration with Lwt for async database operations
- Clear test output and assertions
- Supports test fixtures and setup/teardown

**What to test:**

1. **Database module tests** (`lib/persistence/database.ml`):
   - Player upsert with/without FIDE ID
   - Name normalization and conflict resolution
   - Rating history insertion
   - Batch creation and deduplication
   - Game recording with foreign keys
   - Position and FEN upsert

2. **Vector operations**:
   - Embedding insertion with dimension validation
   - Similarity search operators (cosine, L2, inner product)
   - Vector constraint enforcement

3. **Integration tests**:
   - Full ingestion pipeline with test PGN files
   - Transaction rollback on errors
   - Concurrent insertions via connection pool

### Setup Example

**Add to `dune-project` dependencies:**

```ocaml
(package
 (name chessbuddy)
 (depends
  ...
  (alcotest :with-test)
  (alcotest-lwt :with-test)))
```

**Test structure:**

```
test/
├── dune                    # Test build configuration
├── test_suite.ml           # Test runner with Alcotest-lwt
├── test_helpers.ml         # Shared fixtures and utilities
├── test_database.ml        # Database module tests
├── test_vector.ml          # Vector operations tests
└── fixtures/               # (planned) Test data
    └── sample.pgn          # (planned) Sample PGN files
```

**Test database strategy:**

```ocaml
(* Use docker-compose with test database *)
let test_uri = "postgresql://chess:chess@localhost:5433/chessbuddy_test"

(* Setup: create test DB, apply schema *)
let setup () =
  let%lwt () = run_command "psql ... -c 'CREATE DATABASE chessbuddy_test'" in
  run_command "psql ... -f sql/schema.sql"

(* Teardown: drop test DB *)
let teardown () =
  run_command "psql ... -c 'DROP DATABASE chessbuddy_test'"

(* Or use transactions with ROLLBACK for isolation *)
let with_transaction pool test =
  Pool.use pool (fun conn ->
    let%lwt () = Db.exec "BEGIN" in
    let%lwt result = test conn in
    let%lwt () = Db.exec "ROLLBACK" in
    Lwt.return result)
```

**Example test case:**

```ocaml
let test_upsert_player () =
  Alcotest_lwt.test_case "upsert player with FIDE ID" `Quick (fun _switch () ->
    let pool = Database.Pool.create test_uri in
    let%lwt player_id =
      Database.upsert_player pool
        ~full_name:"Test Player"
        ~fide_id:(Some "123456")
    in
    let%lwt player_id2 =
      Database.upsert_player pool
        ~full_name:"Test Player Modified"
        ~fide_id:(Some "123456")
    in
    Alcotest.(check string) "same UUID"
      (Uuidm.to_string player_id)
      (Uuidm.to_string player_id2);
    Lwt.return ())
```

**Run tests:**

```bash
# With test database
docker-compose up -d
dune runtest

# Or with CI
dune build @runtest
```

### Benefits of Automated Tests

1. **Catch regressions** early when modifying `database.ml` queries
2. **Validate schema** constraints and indexes
3. **Document behavior** with executable examples
4. **CI integration** for pull request validation
5. **Confidence in refactoring** connection pool and query logic

### CI Integration

Add to `.github/workflows/ci.yml`:

```yaml
- name: Start PostgreSQL
  run: docker-compose up -d

- name: Wait for DB
  run: sleep 5

- name: Apply schema
  run: psql "$CONNECTION_STRING" -f sql/schema.sql

- name: Run tests
  run: dune runtest
```

## Current Test Status (v0.0.5)

### Test Suite: ✅ 46 / 54 Tests Passing (85%)

**Database Operations (7 tests):**
- ✅ Player upsert with FIDE ID
- ✅ Player upsert without FIDE ID (name-based)
- ✅ Rating record insertion with conflict resolution
- ✅ Batch creation and deduplication
- ✅ FEN position upsert and deduplication
- ✅ Full game recording with foreign key constraints
- ✅ Position motifs recording

**Vector Operations (6 tests):**
- ✅ Embedding insertion with dimension validation
- ✅ Embedding updates (last write wins)
- ✅ Dimension constraint enforcement (768D required)
- ✅ Cosine similarity search (<=>)
- ✅ L2 distance calculation (<->)
- ✅ Inner product calculation
- ✅ Embedding version lookup

**PGN Source (2 tests):**
- ✅ Unicode preservation in sanitization
- ✅ Malformed UTF-8 sequence handling

**Search Service (2 tests):**
- ✅ Entity filter validation and normalization
- ✅ Natural language ranking with stub embeddings

**Chess Engine (16 tests - 8 passing, 8 failing):**
- ✅ Initial board setup validation
- ✅ FEN generation for starting position
- ✅ FEN board serialization format
- ✅ FEN board parsing (bidirectional)
- ❌ FEN parsing and generation round-trip (board update bug)
- ✅ Castling rights encoding
- ✅ Square notation conversion (algebraic ↔ indices)
- ❌ Board set and get operations (index issue)
- ✅ Piece-to-FEN character conversion
- ❌ Pawn move application (board state bug)
- ❌ Piece move application (disambiguation bug)
- ✅ Castling move handling
- ❌ Capture detection (piece tracking bug)
- ❌ Promotion handling (board update bug)
- ❌ Move disambiguation (piece search bug)
- ❌ Full game sequence (cascading failures)

**Retrieve CLI (9 tests):**
- ✅ Root help text
- ✅ Search command argument validation
- ✅ Similar command requirements
- ✅ Game metadata fetch requirements
- ✅ Games pagination help
- ✅ Games command db-uri requirement
- ✅ Command registry stays in sync

**Ingest CLI (12 tests):**
- ✅ Help flows
- ✅ Batch management validation
- ✅ Player sync argument requirements
- ✅ Health check command wiring

### Known Issues

**Chess Engine Move Application (8 failures):**
- Board state not updating correctly after moves
- Captured piece detection failing
- Source square finding issues in disambiguation
- FEN round-trip not preserving board state

These are implementation bugs in `lib/chess/chess_engine.ml:388-500` that need to be fixed before integration with the ingestion pipeline.

**Run tests:**

```bash
docker-compose up -d
psql "postgresql://chess:chess@localhost:5433/chessbuddy" -f sql/schema.sql
dune runtest
```

**Focus on natural language search only:**

```bash
CHESSBUDDY_REQUIRE_DB_TESTS=1 dune runtest --only-test "Search Service"
```

**Test files:**
- `test/test_database.ml` - Database module tests with Alcotest (7 tests)
- `test/test_vector.ml` - Vector search and embedding tests (6 tests)
- `test/test_pgn_source.ml` - PGN parser UTF-8 handling (2 tests)
- `test/test_chess_engine.ml` - Board state and move validation (16 tests, 8 passing)
- `test/test_search_service.ml` - Natural language search coverage with stub embedder (2 tests)
- `test/test_retrieve_cli.ml` - Retrieve CLI argument validations (9 tests)
- `test/test_ingest_cli.ml` - Ingest CLI argument validations (12 tests)
- `test/test_suite.ml` - Test runner with Alcotest-lwt
- `test/test_helpers.ml` - Shared fixtures and utilities

## Ingestion Pipeline (v0.0.2)

### Move Processing Re-enabled

In v0.0.2, full move processing was re-enabled after implementing placeholder FEN generation. The ingestion pipeline now processes every position in every game.

**Previous behavior (v0.0.1):**

```ocaml
(* Move processing was disabled *)
(* let%lwt _game_id = record_game pool ~batch_id ~white_id ~black_id ~game in *)
let _ = embedder in (* Suppress unused warning *)
Lwt.return_unit
```

**Current behavior (v0.0.2):**

```ocaml
let%lwt game_id = record_game pool ~batch_id ~white_id ~black_id ~game in
Lwt_list.iter_s (fun move -> process_move pool ~game_id ~embedder ~move) game.moves
```

**Position processing workflow:**

1. **FEN deduplication** - Each position's `fen_after` is checked against `fens` table
2. **Position recording** - Move details stored in `games_positions` with reference to FEN
3. **Embedding generation** - Unique FENs get 768-dimensional embeddings via pluggable embedder
4. **Storage** - Embeddings stored in `fen_embeddings` with version tracking

**Benefits:**
- Complete position-level analysis across all games
- 99.93% FEN deduplication (TWIC 1611: 428,853 positions → 301 unique FENs)
- Semantic search capabilities via vector embeddings
- Move-by-move game reconstruction

### PGN Parser Improvements

#### Game Boundary Detection Fix

The PGN parser had a critical bug in v0.0.1 that merged all games into a single entry. This was fixed in v0.0.2 by tracking whether the parser is currently processing headers or moves.

**The bug:**

```ocaml
(* v0.0.1: Split on empty lines, causing games to merge *)
let rec accumulate acc current = function
  | [] -> List.rev (current :: acc)
  | line :: rest ->
      if String.trim line = "" then accumulate (current :: acc) "" rest
      else accumulate acc (current ^ "\n" ^ line) rest
```

Result: 4,875 games → **1 giant game** with 4.2MB of moves

**The fix:**

```ocaml
(* v0.0.2: Track header vs. move context *)
let rec accumulate acc current in_moves = function
  | [] -> List.rev (if current = "" then acc else current :: acc)
  | line :: rest ->
      let trimmed = String.trim line in
      if trimmed = "" then
        accumulate acc current in_moves rest
      else if String.length trimmed > 0 && trimmed.[0] = '[' then
        (* Header line *)
        if current <> "" && in_moves then
          (* New game starting - save current and start new *)
          accumulate (current :: acc) line false rest
        else
          (* Continue current game headers *)
          accumulate acc (current ^ "\n" ^ line) false rest
      else
        (* Move line *)
        accumulate acc (current ^ "\n" ^ line) true rest
```

**Key insight:** When we see a header line (`[Tag "Value"]`) after processing moves (`in_moves = true`), we know a new game is starting.

**Validation:**

```bash
# Before fix (v0.0.1)
psql chessbuddy -c "SELECT COUNT(*) FROM games;"
# Result: 1

# After fix (v0.0.2)
psql chessbuddy -c "SELECT COUNT(*) FROM games;"
# Result: 4,875
```

## FEN Generator Module (v0.0.8)

### Overview

The FEN generator (`lib/chess/fen_generator.ml`) now maintains a full game state backed by the custom chess engine. Each call to `apply_move` feeds SAN moves through `Chess_engine.Move_parser`, updates castling rights/en-passant metadata, and returns an updated `game_state`. `to_fen` then emits the fully accurate FEN string for the current position.

**Module interface (excerpt):**

```ocaml
type game_state = {
  board : Chess_engine.Board.t;
  castling_rights : Chess_engine.castling_rights;
  en_passant_square : string option;
  halfmove_clock : int;
  fullmove_number : int;
}

val initial_state : game_state
val apply_move : game_state -> san:string -> side_to_move:Chess_engine.color ->
  (game_state, string) Result.t
val to_fen : game_state -> side_to_move:Chess_engine.color -> string
```

`placeholder_fen` still exists for backwards compatibility but now logs a warning; new code should rely on `apply_move`/`to_fen`.

**Integration:**

`lib/chess/pgn_source.ml` seeds a fresh `game_state` per game, calls `apply_move` for each SAN token, and records both `fen_before` and `fen_after` from `to_fen`. Failures fall back to the previous state with a warning so ingestion stays resilient to malformed PGNs.

**Benefits:**
- Accurate board positions (pieces, castling rights, en passant targets)
- Half-move clock maintained for the fifty-move rule
- Full-move number derived from tracked ply count

## Performance Metrics (v0.0.2)

Ingestion benchmarks on TWIC 1611 (4.2MB PGN, 4,875 games):

- **Duration**: 5 minutes 27 seconds
- **Throughput**: ~15 games/sec, ~1,310 positions/sec
- **Positions ingested**: 428,853 move-level entries
- **Unique FENs**: 301 (deduplication: 99.93%)
- **Players tracked**: 2,047 with 100% FIDE ID coverage
- **Embeddings generated**: 301 (one per unique FEN)

**Database growth:**
- Games table: 4,875 rows
- Players table: 2,047 rows
- games_positions table: 428,853 rows
- fens table: 301 rows
- fen_embeddings table: 301 rows
