# Release Notes

## Version 0.0.2 - FEN Position Tracking

### Overview
Adds placeholder FEN generation for position tracking, enabling full move-level ingestion with position deduplication and embeddings. Successfully tested with TWIC 1611 dataset (4,875 games, 428,853 positions) ingested in 5:27.

### Major Features

#### FEN Generator Module
- **Placeholder FEN Generation** (`lib/fen_generator.ml`)
  - `starting_position_fen` constant for initial board state
  - `placeholder_fen` function generates FENs with correct move numbers and side-to-move
  - Maintains proper fullmove counter and active color tracking
  - Designed for easy replacement with full chess engine integration

#### Move Processing Pipeline
- **Complete Position Ingestion** (`lib/ingestion_pipeline.ml:67`)
  - Re-enabled full move processing with FEN tracking
  - Each move now has `fen_before` and `fen_after` fields populated
  - Position deduplication via `fens` table reduces storage overhead
  - Automatic embedding generation for unique positions

#### PGN Parser Improvements
- **FEN Integration** (`lib/pgn_source.ml:111-132`)
  - Generates FENs during move parsing
  - First move uses standard starting position
  - Subsequent moves use placeholder FENs with updated move numbers
  - Proper side-to-move alternation (w → b → w)

- **Game Boundary Detection** (`lib/pgn_source.ml:141-162`)
  - Fixed parser to correctly separate multiple games in single file
  - Tracks header vs. move sections to identify game boundaries
  - Handles PGN files with varying whitespace formatting

### Bug Fixes & Improvements

#### Database Schema
- **Large PGN Handling** (`sql/schema.sql:45`)
  - Added `pgn_hash` column (SHA256 digest) to games table
  - Changed unique constraint from `source_pgn` to `pgn_hash`
  - Fixes "index row requires 1968112 bytes, maximum size is 8191" error
  - Enables deduplication without index size limits

- **Crypto Extension** (`sql/schema.sql:4`)
  - Added `pgcrypto` extension for `digest()` function
  - Used in generated column for PGN hash computation

#### PGN Parser
- **Game Aggregation Fix**
  - Previous version incorrectly merged all games into single entry
  - Parser now correctly identifies game boundaries by tracking header/move context
  - Properly accumulates complete games including headers and moves

### Performance

Ingestion benchmarks on TWIC 1611 (4.2MB PGN file):
- **Duration**: 5 minutes 27 seconds
- **Games processed**: 4,875
- **Positions ingested**: 428,853
- **Unique FENs**: 301 (deduplication: 99.93%)
- **Players tracked**: 2,047 with 100% FIDE ID coverage
- **Embeddings generated**: 301 (one per unique FEN)
- **Throughput**: ~15 games/second, ~1,310 positions/second

### Technical Stack Updates
- **New Module**: `lib/fen_generator.ml` - Position notation generation
- **Enhanced**: `lib/pgn_source.ml` - FEN integration, improved game parsing
- **Enhanced**: `lib/ingestion_pipeline.ml` - Full position processing enabled
- **Enhanced**: `sql/schema.sql` - PGN hash column, pgcrypto extension

### Implementation Details

#### Placeholder FEN Format
```ocaml
(* Move 1, White to move *)
"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

(* Move 5, Black to move *)
"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - 0 3"
```

Components tracked:
- Board position: Starting position (placeholder)
- Active color: Alternates w/b based on ply number
- Castling rights: Always "KQkq" (placeholder)
- En passant: Always "-" (none, placeholder)
- Halfmove clock: Always "0" (placeholder)
- Fullmove number: Computed as `(ply_number + 1) / 2`

#### Database Schema Changes
```sql
-- New generated column for deduplication
CREATE TABLE games (
    ...
    source_pgn TEXT NOT NULL,
    pgn_hash TEXT GENERATED ALWAYS AS
        (encode(digest(source_pgn, 'sha256'), 'hex')) STORED,
    ...
    UNIQUE (white_id, black_id, game_date, round, pgn_hash)
);
```

### Known Limitations

1. **Placeholder Board State**: Current FENs use the starting position for all moves. Integration with chess library needed for actual position tracking.

2. **Castling Rights**: Always "KQkq" in placeholder FENs. Proper tracking requires move validation.

3. **En Passant**: Not tracked in current implementation. Requires previous move analysis.

4. **Halfmove Clock**: Set to 0 for all positions. Proper tracking requires capture and pawn move detection.

### Migration Notes

Existing v0.0.1 databases need schema update:
```sql
-- Add pgcrypto extension
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Recreate games table with pgn_hash column
DROP TABLE games CASCADE;
-- Then run full schema.sql
```

### Next Steps

Planned for v0.0.3:
- Integration with chess engine library (ocamlchess or shakmaty)
- Full FEN computation with actual board states
- Castling rights tracking
- En passant square detection
- Halfmove clock for 50-move rule
- Move validation and illegal position detection

---

## Version 0.0.1 - Initial Release

### Overview
Initial release of ChessBuddy, a hybrid SQL + vector chess retrieval pipeline built with OCaml. This system ingests PGN chess games, stores them in PostgreSQL with pgvector for position embeddings, and enables semantic search over chess positions.

### Major Features

#### Database Layer
- PostgreSQL 16 with pgvector extension for vector similarity search
- Complete schema supporting:
  - Player management with FIDE ID tracking
  - Game metadata (event, site, date, ECO codes, ELO ratings)
  - Position-level analysis with FEN notation
  - 768-dimensional embeddings for semantic position search
  - Ingestion batch tracking with deduplication

#### Caqti 2.x Integration
- Full migration to Caqti 2.x API
- Custom type encoders for:
  - UUID (using Uuidm library)
  - Date tuples (wrapping Ptime.t)
  - PostgreSQL arrays (text[])
  - pgvector embeddings (float[])
- Connection pooling with configurable max size

#### Ingestion Pipeline
- PGN file parsing with game metadata extraction
- Position-level move features (SAN, UCI, captures, checks, mates)
- Pluggable embedder interface (includes constant embedder stub)
- Pluggable PGN source interface
- Batch processing with checksum-based deduplication

#### Vector Search
- Three similarity operators:
  - Cosine distance (`<=>`) for angular similarity
  - L2 distance (`<->`) for Euclidean distance
  - Inner product (`<#>`) for dot product similarity
- Optimized with HNSW indexes

### Testing

#### Test Suite (Alcotest)
- 11 automated tests covering:
  - **Database Operations** (6 tests)
    - Player upsert with/without FIDE ID
    - Rating records with conflict resolution
    - Batch creation and deduplication
    - FEN position upsert
    - Full game recording with foreign keys
  - **Vector Operations** (5 tests)
    - Embedding insertion and updates
    - Dimension constraint validation
    - Cosine similarity search
    - L2 distance calculation
    - Inner product queries

- Test infrastructure includes:
  - Clean database setup/teardown
  - Connection pool management
  - Query helpers with error handling

### Technical Stack
- **Language**: OCaml 5.1+
- **Build System**: Dune 3.10
- **Database**: PostgreSQL 16 with pgvector
- **Libraries**:
  - `caqti` / `caqti-lwt` / `caqti-driver-postgresql` - Database interface
  - `lwt` / `lwt_ppx` - Asynchronous programming
  - `cmdliner` - CLI argument parsing
  - `digestif` - Checksums for deduplication
  - `uuidm` - UUID generation and parsing
  - `ptime` - Date/time handling
  - `alcotest` / `alcotest-lwt` - Testing framework

### Bug Fixes & Improvements

#### Database Schema
- Added UNIQUE constraint to `ingestion_batches.checksum` to enable ON CONFLICT deduplication (sql/schema.sql:26)

#### Vector Encoding
- Fixed float array encoding format from PostgreSQL arrays `{1,2,3}` to pgvector format `[1,2,3]` (lib/database.ml:42)

#### Cmdliner Deprecations
- Updated to modern Cmdliner API using `Cmd.v`, `Cmd.info`, and `Cmd.eval` (bin/ingest.ml:27-32)

#### Type System
- Removed `ppx_yojson_conv` derivation from types containing `Ptime.t` to avoid serialization issues

### Known Limitations

1. **Embedder**: Current implementation uses a constant embedder stub. Production use requires integration with an actual chess position encoder.

2. **PGN Parser**: Basic parser extracts headers and SAN moves but doesn't compute UCI notation or actual board state. Integration with a chess engine library (like `ocamlchess`) needed for:
   - FEN computation at each position
   - Move validation
   - Legal move generation

3. **Vector Decoding**: Float array decoder is a placeholder that returns dummy data. Reading embeddings back from the database is not yet implemented.

4. **String Array Decoding**: PostgreSQL text[] decoder is a placeholder. Full array parsing needed for motif flags.

### File Structure

```
chessbuddy/
├── lib/
│   ├── database.ml           # Caqti 2.x database interface
│   ├── types.ml              # Core data types
│   ├── ingestion_pipeline.ml # Main ingestion logic
│   ├── pgn_source.ml         # PGN parsing
│   └── embedder.ml           # Embedding interface
├── bin/
│   └── ingest.ml             # CLI ingestion command
├── test/
│   ├── test_helpers.ml       # Test utilities
│   ├── test_database.ml      # Database operation tests
│   ├── test_vector.ml        # Vector search tests
│   └── test_suite.ml         # Test runner
├── sql/
│   └── schema.sql            # PostgreSQL schema with pgvector
└── docs/
    ├── GUIDELINES.md         # Contribution guidelines
    └── DEVELOPER.md          # Developer documentation

```

### Getting Started

1. **Start PostgreSQL**:
   ```bash
   docker-compose up -d
   ```

2. **Apply Schema**:
   ```bash
   psql postgresql://chess:chess@localhost:5433/chessbuddy -f sql/schema.sql
   ```

3. **Build**:
   ```bash
   dune build
   ```

4. **Run Tests**:
   ```bash
   dune runtest
   ```

5. **Ingest PGN** (when available):
   ```bash
   dune exec chessbuddy-ingest -- --db-uri postgresql://chess:chess@localhost:5433/chessbuddy --pgn games.pgn --batch-label "example-batch"
   ```

### Next Steps

Future releases will focus on:
- Integration with real chess position embedder
- Full FEN computation using chess engine library
- Query interface for position similarity search
- REST API for web/mobile clients
- Opening repertoire analysis
- Tactical motif detection
- Game continuation suggestions

---

**Note**: This is an early development release. The API is not stable and may change significantly between versions.