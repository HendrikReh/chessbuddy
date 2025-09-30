# Release Notes

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