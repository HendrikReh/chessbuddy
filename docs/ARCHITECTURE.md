# ChessBuddy Architecture

This document provides a comprehensive view of ChessBuddy's system architecture, module organization, data flow, and key design decisions. It serves as the single source of truth for understanding how the system works.

## Table of Contents

- [System Overview](#system-overview)
- [High-Level Architecture](#high-level-architecture)
- [Module Organization](#module-organization)
- [Data Flow](#data-flow)
- [Database Schema](#database-schema)
- [Key Design Decisions](#key-design-decisions)
- [Extension Points](#extension-points)
- [Performance Characteristics](#performance-characteristics)

## System Overview

ChessBuddy is a **hybrid SQL + vector chess retrieval and pattern analysis pipeline** that:

1. **Ingests** PGN chess game archives
2. **Tracks** positions at the move level with accurate FEN notation
3. **Runs** strategic, tactical, and endgame pattern detectors during ingestion
4. **Generates** 768-dimensional embeddings for positions (and 1536-D for text search)
5. **Stores** everything in PostgreSQL with pgvector extension
6. **Enables** semantic search and pattern-filtered retrieval across games, players, and positions

**Technology Stack:**
- **Language:** OCaml 5.1+ with Base standard library
- **Database:** PostgreSQL 16 with pgvector extension
- **Async:** Lwt for cooperative concurrency
- **Database Access:** Caqti 2.x for type-safe queries
- **Testing:** Alcotest-lwt with Docker-based PostgreSQL

## High-Level Architecture

### Component Diagram

```mermaid
flowchart TB
    subgraph CLI["Command Line Interface"]
        ING[Ingest CLI<br/>bin/ingest.exe]
        RET[Retrieve CLI<br/>bin/retrieve.exe]
    end

    subgraph CORE["Core Library (lib/)"]
        PIPE[Ingestion Pipeline<br/>ingestion/ingestion_pipeline.ml]
        PGN[PGN Parser<br/>chess/pgn_source.ml]
        CHESS[Chess Engine<br/>chess/chess_engine.ml]
        FEN[FEN Generator<br/>chess/fen_generator.ml]
        PAT[Pattern Detectors<br/>patterns/*.ml]
        EMB[Position Embedder<br/>embedding/embedder.ml]
        SEARCH[Search Service<br/>search/search_service.ml]
        IDX[Search Indexer<br/>search/search_indexer.ml]
        SEMB[Text Embedder<br/>embedding/search_embedder.ml]
    end

    subgraph DATA["Data Layer"]
        DB[(Database<br/>persistence/database.ml)]
        TYPES[Domain Types<br/>core/types.ml]
    end

    subgraph EXT["External Services"]
        OPENAI[OpenAI API<br/>embedding/openai_client.ml]
        ENV[Configuration<br/>core/env_loader.ml]
    end

    subgraph STORE["Persistent Storage"]
        PG[(PostgreSQL<br/>+ pgvector)]
    end

    ING --> PIPE
    RET --> SEARCH
    PIPE --> PGN
    PIPE --> FEN
    FEN --> CHESS
    PIPE --> PAT
    PAT --> CHESS
    PIPE --> EMB
    PIPE --> IDX
    SEARCH --> IDX
    IDX --> SEMB
    SEMB --> OPENAI
    OPENAI --> ENV
    PIPE --> DB
    PAT --> DB
    SEARCH --> DB
    DB --> TYPES
    DB --> PG
```

### Layer Responsibilities

| Layer | Modules | Responsibility |
|-------|---------|----------------|
| **CLI** | `ingest.ml`, `retrieve.ml`, `ingest_cli.ml`, `retrieve_cli.ml` | Argument parsing, command routing, user interaction |
| **Domain** | `core/types.ml` | Core data structures (Player, Game, Move, Batch) |
| **Pipeline** | `ingestion/ingestion_pipeline.ml` | Orchestration, deduplication, workflow coordination |
| **Parsing** | `chess/pgn_source.ml` | PGN format parsing with annotation preservation |
| **Chess** | `chess/chess_engine.ml` | Board representation, SAN move parsing, FEN generation |
| **Position** | `chess/fen_generator.ml` | FEN string generation via the chess engine |
| **Embeddings** | `embedding/embedder.ml`, `embedding/search_embedder.ml`, `embedding/openai_client.ml` | Vector generation for positions and text |
| **Patterns** | `patterns/pattern_detector.ml`, `patterns/strategic_patterns.ml`, `patterns/tactical_patterns.ml`, `patterns/endgame_patterns.ml` | Strategic/tactical/endgame detection, registry, metadata |
| **Search** | `search/search_service.ml`, `search/search_indexer.ml` | Natural language search over entities |
| **Data Access** | `persistence/database.ml` | SQL query abstraction, connection pooling |
| **Configuration** | `core/env_loader.ml` | Environment variables and .env file handling |

## Module Organization

The codebase is organized into functional subdirectories using Dune's `include_subdirs unqualified`. This provides clean separation while maintaining a single wrapped library:

```
lib/
├── core/          # Domain types and configuration
├── chess/         # Chess-specific logic
├── persistence/   # Database layer
├── embedding/     # Vector embeddings
├── search/        # Semantic search
├── patterns/      # Pattern detector framework and implementations
└── ingestion/     # Data pipeline
```

All modules remain accessible with their original names (e.g., `Types`, `Database`, `Chess_engine`) due to the unqualified include mode. When referencing modules from other libraries or executables, use the wrapped namespace (for example `Chessbuddy.Chess.Chess_engine`).

### Core Domain (`lib/core/types.ml`)

Defines immutable data structures:

```ocaml
module Rating        (* ELO ratings: standard, rapid, blitz *)
module Player        (* Identity + rating history *)
module Game_header   (* PGN metadata: event, players, ECO *)
module Move_feature  (* Move + annotations + FEN positions *)
module Game          (* Header + moves + source PGN *)
module Batch         (* Ingestion batch metadata *)
```

**Characteristics:**
- No business logic
- All types support `[@@deriving show, yojson]`
- Immutable by design (no setters)

### Ingestion Pipeline (`lib/ingestion/ingestion_pipeline.ml`)

**Module Signatures:**
```ocaml
module type EMBEDDER       (* FEN → 768D vector *)
module type TEXT_EMBEDDER  (* Text → 1536D vector *)
module type PGN_SOURCE     (* File → Game stream *)
```

**Core Functions:**
- `ingest_file` - Full pipeline execution
- `process_game` - Single game ingestion
- `process_move` - Position tracking + embedding
- `inspect_file` - Dry-run analysis
- `sync_players_from_pgn` - Player-only extraction

**Workflow:**
1. Compute file checksum → create/retrieve batch
2. Stream games from PGN source
3. Upsert players (white, black)
4. Record game metadata
5. For each move:
   - Generate FEN before/after via chess engine
   - Deduplicate FEN (TWIC 1611 → ~325k unique FENs)
   - Run registered pattern detectors and persist detections
   - Generate embedding if missing or version changed
   - Record position in games_positions table
   - Index for search (if enabled)

### PGN Parser (`lib/chess/pgn_source.ml`)

**Capabilities:**
- Multi-game file support
- UTF-8 sanitization
- Game boundary detection (header vs. move context)
- Annotation preservation:
  - Comments: `{This is brilliant!}`
  - Variations: `(1...e5 2.Nf3)`
  - NAGs: `$1` (good move), `$2` (mistake)

**Output:**
- `Types.Game.t` with structured header and moves
- Fully evaluated FENs generated through the chess engine for both pre- and post-move positions

### Chess Engine (`lib/chess/chess_engine.ml`)

**Purpose:** Lightweight board state tracking and FEN generation without external dependencies.

**Core Modules:**
```ocaml
module Board         (* 8x8 board representation with functional updates *)
module Move_parser   (* SAN move parsing and application *)
module Fen           (* Complete FEN string generation and parsing *)
```

**Capabilities:**
- Immutable board representation with coordinate-based updates
- FEN generation/parsing covering side-to-move, castling rights, en-passant squares, and clock counters
- SAN move parsing with full disambiguation, promotion handling, annotations, and check/mate tracking
- Accurate castling/en-passant logic (including rook/king moves and captures) feeding the ingestion pipeline and pattern detectors

**Implementation Status (v0.0.8):**
- ✅ Integrated with `fen_generator` and ingestion (real FENs captured for every ply)
- ✅ Coordinate-driven castling and en-passant capture verified via unit tests
- ✅ All 60 Alcotest suites passing (16/16 chess engine cases)
- ✅ Benchmarked <1 ms FEN generation and <0.5 ms move application on Apple M2 Pro hardware

See [docs/CHESS_ENGINE_STATUS.md](CHESS_ENGINE_STATUS.md) for historical context and edge-case notes.

### Database Layer (`lib/persistence/database.ml`)

**Custom Caqti Types:**
```ocaml
val uuid : Uuidm.t Caqti_type.t
val date : (int * int * int) Caqti_type.t
val string_array : string array Caqti_type.t
val float_array : float array Caqti_type.t  (* pgvector format *)
```

**Query Organization:**
- Player management: `upsert_player`, `record_rating`, `search_players`
- Batch management: `create_batch`, `list_batches`, `get_batch_summary`
- Game management: `record_game`, `get_game_detail`, `list_games`
- Position management: `upsert_fen`, `record_position`, `get_fen_details`
- Embedding management: `record_embedding`, `find_similar_fens`
- Search: `search_documents`, `upsert_search_document`
- Health: `health_check`, `ensure_search_documents`

### Search Infrastructure

**Three-Layer Architecture:**

1. **search_service.ml** - High-level API
   - Entity type filtering (game, player, fen, batch, embedding)
   - Query validation and normalization
   - Result ranking

2. **search_indexer.ml** - Text processing
   - Entity summarization (game → searchable text)
   - Text sanitization and truncation
   - Embedding orchestration

3. **search_embedder.ml** / **openai_client.ml** - Vector generation
   - OpenAI text-embedding-3-small integration
   - API key management via env vars
   - HTTP error handling

## Data Flow

### Ingestion Flow

```mermaid
sequenceDiagram
    participant CLI as Ingest CLI
    participant Pipe as Pipeline
    participant PGN as PGN Source
    participant CHESS as Chess Engine
    participant FEN as FEN Generator
    participant PAT as Pattern Detectors
    participant DB as Database
    participant EMB as Embedder
    participant IDX as Search Indexer
    participant VEC as pgvector

    CLI->>Pipe: ingest_file(pgn_path, batch_label)

    activate Pipe
    Pipe->>DB: compute_checksum(path)
    Pipe->>DB: create_batch(checksum)
    DB-->>Pipe: batch_id

    loop For each game in PGN
        Pipe->>PGN: fold_games(path, f)
        PGN-->>Pipe: Game { header, moves, source_pgn }

        Pipe->>DB: upsert_player(white_player)
        DB-->>Pipe: white_id
        Pipe->>DB: upsert_player(black_player)
        DB-->>Pipe: black_id

        Pipe->>DB: record_game(white_id, black_id, header)
        DB-->>Pipe: game_id

        Pipe->>IDX: index_game(game_id, game)

        loop For each move
            Pipe->>FEN: generate_fen(ply, side)
            FEN->>CHESS: apply_san(board, san, side)
            CHESS-->>FEN: board, captured, en_passant
            FEN-->>Pipe: fen_before, fen_after

            Pipe->>DB: upsert_fen(fen_after)
            DB-->>Pipe: fen_id (deduplicated)

            Pipe->>PAT: detect_patterns(game_id, move, fen_before, fen_after)
            PAT->>DB: record_pattern_detection(...)

            Pipe->>DB: record_position(game_id, move, fen_id)

            alt Embedding missing or outdated
                Pipe->>EMB: embed(fen_after)
                EMB-->>Pipe: 768D vector
                Pipe->>VEC: record_embedding(fen_id, vector)
            end

            Pipe->>IDX: index_fen(fen_id, fen_text)
        end
    end

    deactivate Pipe
    Pipe-->>CLI: Batch summary (games, positions, fens)
```

### Search Flow

```mermaid
sequenceDiagram
    participant User as User Query
    participant Service as Search Service
    participant Indexer as Search Indexer
    participant Embedder as Text Embedder
    participant DB as Database
    participant VEC as pgvector

    User->>Service: search(query, entity_types, limit)

    activate Service
    Service->>Service: validate_query(query)
    Service->>Service: ensure_entity_filters(entity_types)

    Service->>Indexer: ensure_tables(pool)
    Service->>Embedder: embed(query_text)
    Embedder-->>Service: 1536D vector

    Service->>DB: search_documents(embedding, types, limit)
    DB->>VEC: SELECT ... ORDER BY embedding <=> $1
    VEC-->>DB: Ranked results
    DB-->>Service: search_hit list

    deactivate Service
    Service-->>User: Ranked results with scores
```

### Retrieval Flow

```mermaid
flowchart LR
    CLI[Retrieve CLI] -->|game_id| DB[Database]
    CLI -->|fen_id| DB
    CLI -->|player_name| DB

    DB -->|metadata| Format[Formatter]
    DB -->|embeddings| VEC[pgvector]

    VEC -->|similar_fens| Format
    Format -->|JSON/Text| Output[stdout]
```

## Database Schema

### Core Tables

**players**
- `player_id` (UUID, PK)
- `full_name` (TEXT)
- `full_name_key` (TEXT, normalized for dedup)
- `fide_id` (TEXT, UNIQUE)

**games**
- `game_id` (UUID, PK)
- `white_id`, `black_id` (UUID, FK → players)
- `event`, `site`, `game_date`, `round`, `eco_code`, `opening_name`
- `white_elo`, `black_elo`, `result`, `termination`
- `source_pgn` (TEXT)
- `pgn_hash` (TEXT, for deduplication)
- `ingestion_batch` (UUID, FK → ingestion_batches)
- UNIQUE constraint: `(white_id, black_id, game_date, round, pgn_hash)`

**games_positions**
- `position_id` (UUID, PK)
- `game_id` (UUID, FK → games)
- `ply_number` (INT)
- `fen_id` (UUID, FK → fens)
- `side_to_move`, `san`, `uci`, `fen_before`, `fen_after`
- `clock`, `eval_cp`, `is_capture`, `is_check`, `is_mate`
- `motif_flags` (TEXT[])
- UNIQUE constraint: `(game_id, ply_number)`

**fens**
- `fen_id` (UUID, PK)
- `fen_text` (TEXT, UNIQUE) - Full FEN string
- `side_to_move` (CHAR)
- `castling_rights` (TEXT)
- `en_passant_file` (TEXT)
- `material_signature` (TEXT) - Piece count fingerprint

**fen_embeddings**
- `fen_id` (UUID, PK, FK → fens)
- `embedding` (VECTOR(768)) - Position embedding
- `embedding_version` (TEXT) - Model version for cache invalidation

**ingestion_batches**
- `batch_id` (UUID, PK)
- `source_path` (TEXT)
- `label` (TEXT)
- `checksum` (TEXT, UNIQUE) - SHA256 of PGN file
- `ingested_at` (TIMESTAMPTZ)

**search_documents** (for natural language search)
- `document_id` (UUID, PK)
- `entity_type` (TEXT) - "game", "player", "fen", "batch", "embedding"
- `entity_id` (UUID)
- `content` (TEXT) - Searchable summary
- `embedding` (VECTOR(1536)) - Text embedding
- `model` (TEXT) - Embedding model version
- `created_at`, `updated_at` (TIMESTAMPTZ)
- UNIQUE constraint: `(entity_type, entity_id)`

**pattern_catalog**
- `pattern_id` (TEXT, PK)
- `pattern_name` (TEXT)
- `pattern_type` (TEXT) - `strategic`, `tactical`, `endgame`, `opening_trap`
- `detector_module` (TEXT)
- `description` (TEXT)
- `success_criteria` (JSONB)
- `enabled` (BOOLEAN)
- `created_at` (TIMESTAMPTZ)

**pattern_detections**
- `detection_id` (UUID, PK)
- `game_id` (UUID, FK → games)
- `pattern_id` (TEXT, FK → pattern_catalog)
- `detected_by_color` (TEXT) - `white` | `black`
- `success` (BOOLEAN)
- `confidence` (REAL)
- `start_ply`, `end_ply` (INT)
- `outcome` (TEXT) - `victory`, `draw_advantage`, `draw_neutral`, `defeat`
- `metadata` (JSONB)
- `created_at` (TIMESTAMPTZ)
- UNIQUE constraint: `(game_id, pattern_id, detected_by_color)`

**pattern_validation** (optional human review)
- `validation_id` (UUID, PK)
- `detection_id` (UUID, FK → pattern_detections)
- `manually_verified` (BOOLEAN)
- `verified_by` (TEXT)
- `verified_at` (TIMESTAMPTZ)
- `notes` (TEXT)
- `created_at` (TIMESTAMPTZ)

### Indexes

**Critical for Performance:**
- `fens(fen_text)` - UNIQUE index for deduplication
- `fen_embeddings` using IVFFLAT - Vector similarity search
- `search_documents(entity_type, entity_id)` - Document lookup
- `search_documents` using IVFFLAT - Semantic search
- `games(white_id, black_id, game_date, round, pgn_hash)` - Game dedup
- `pattern_detections(pattern_id, success, confidence)` - Pattern filtering
- GIN index on `pattern_detections.metadata` - Metadata queries

## Key Design Decisions

### 1. Custom Chess Engine Implementation

**Decision:** Build a lightweight chess engine from scratch rather than depend on external libraries.

**Rationale:**
- No suitable OCaml chess libraries available in opam (see `docs/CHESS_LIBRARY_EVALUATION.md`).
- Native implementation keeps dependency footprint small and enables tight integration with detectors.
- Functional approach (immutable board updates) aligns with Base/Lwt idioms.

**Current Status (v0.0.8):**
- ✅ Integrated with `fen_generator` – every ply uses the engine for accurate board state.
- ✅ Full SAN coverage with disambiguation, promotions, annotations, and coordinate-based castling/en-passant tracking.
- ✅ Performance targets met (<1 ms FEN generation, <0.5 ms move application on Apple M2 Pro).
- ✅ Backed by 16 dedicated unit tests plus pattern detector integration tests (all passing).

**Impact:**
- Realistic FEN deduplication (~325k unique positions for TWIC 1611) enabling fine-grained analysis.
- Reliable board snapshots powering pawn-structure heuristics, tactical verifications, and endgame recognizers.

### 2. Two-Tier Embedding Strategy

**Decision:** Use different embedding dimensions for different purposes.

| Purpose | Dimensions | Model | Use Case |
|---------|-----------|-------|----------|
| FEN positions | 768 | Custom engine-derived | Position similarity search |
| Text search | 1536 | text-embedding-3-small | Natural language queries |

**Rationale:**
- Position embeddings need to be fast (high-volume)
- Text embeddings can be slower (query-time only)
- Allows independent optimization of each pathway

### 3. Extensible Pattern Detection Framework

**Decision:** Detect strategic, tactical, and endgame motifs during ingestion via a pluggable architecture.

**Rationale:**
- Users ask contextual questions ("queenside majority attack in King’s Indian") that require strategic understanding beyond raw positions.
- Detectors benefit from accurate board state and metadata already produced during ingestion.

**Implementation:**
- `Pattern_detector` module type defines `detect` + `classify_success` contracts.
- Registry pattern enables dynamic discovery and selective execution.
- Strategic/tactical/endgame detectors reuse pawn-structure and endgame helpers.
- `pattern_detections` table stores confidence, ply range, outcome, and JSON metadata per detection.

**Outcomes:**
- Retrieve CLI exposes advanced filters (confidence, ECO, rating spans, move counts, date/name constraints, output formatting).
- Downstream tooling can aggregate detections by pattern type, opening family, or player.

### 4. Aggressive FEN Deduplication

**Decision:** Store unique FENs in separate table, reference from games_positions.

**Impact:**
- 99.93% deduplication rate (TWIC 1611: 428,853 → 301 unique)
- Massive storage savings on embeddings
- One embedding per unique position (not per move)

**Trade-off:** Extra join in position queries, but acceptable for read patterns.

### 4. Batch-Based Ingestion

**Decision:** Track ingestion runs with checksums to prevent duplicate work.

**Benefits:**
- Idempotent ingestion (safe to re-run)
- Clear audit trail
- Batch-level metrics and rollback capability

**Implementation:**
- SHA256 checksum of PGN file content
- UNIQUE constraint prevents duplicate batches
- ON CONFLICT DO UPDATE pattern updates metadata

### 5. Lwt for Concurrency

**Decision:** Use Lwt instead of OCaml 5 effects for async I/O.

**Rationale:**
- Mature ecosystem (Cohttp-lwt, Caqti-lwt)
- Battle-tested for database-heavy workloads
- Better library support than effects (as of 2024)

**Consequence:** `let%lwt` syntax throughout, explicit bind operators.

### 6. Base Standard Library

**Decision:** Use Jane Street Base instead of OCaml Stdlib.

**Rationale:**
- Consistent API across containers
- Better error messages
- Labeled arguments enforce correctness
- Follows industry best practices

**Convention:** Every module starts with `open! Base`.

## Extension Points

### 1. Embedder Interface

```ocaml
module type EMBEDDER = sig
  val version : string
  val embed : fen:string -> float array Lwt.t
end
```

**Swap implementations:**
- `Embedder.Constant` - Zero vectors (testing)
- `Embedder.Neural` - Trained model (planned)
- Custom implementations for experimentation

### 2. Text Embedder Interface

```ocaml
module type TEXT_EMBEDDER = sig
  val model : string
  val embed : text:string -> (float array, string) Result.t Lwt.t
end
```

**Current:**
- `Search_embedder.Openai` - OpenAI API

**Future:**
- Local models (sentence-transformers)
- Cached embeddings
- Hybrid retrievers

### 3. PGN Source Interface

```ocaml
module type PGN_SOURCE = sig
  val fold_games :
    string -> init:'a -> f:('a -> Types.Game.t -> 'a Lwt.t) -> 'a Lwt.t
end
```

**Current:**
- `Pgn_source.Default` - File-based streaming parser

**Future:**
- HTTP streaming (fetch from chess.com API)
- Database-backed sources
- Filtered sources (rating threshold, opening filter)

### 4. Search Ranking

Currently uses simple cosine similarity. Easy to extend:

```ocaml
(* Current *)
1.0 / (1.0 + distance)

(* Future: Hybrid ranking *)
score = 0.7 * vector_similarity + 0.3 * metadata_boost
```

## Performance Characteristics

### Ingestion (TWIC 1611 Benchmark)

**Input:** 4.2MB, 4,875 games, 428,853 positions (TWIC 1611)
**Hardware:** Apple M2 Pro, 16GB RAM
**Time:** 5:27 minutes

**Throughput:**
- ~15 games/second
- ~1,310 positions/second
- ~6 players/second (with dedup)

**Resulting artefacts:**
- ~325k unique FENs after deduplication (vector embeddings generated once per unique board)
- ~11k pattern detections across strategic/tactical/endgame detectors

**Bottlenecks:**
1. Sequential move processing (`Lwt_list.iter_s`)
2. N+1 player queries (could batch)
3. Embedding generation (network I/O to OpenAI)

**Optimization Opportunities:**
- Batch position inserts (100 at a time)
- Pre-load player cache before game loop
- Local embedding models (eliminate network)
- Parallel detector execution (current implementation runs sequentially)

### Search Performance

**Query Latency (typical):**
- Text embedding: 200-500ms (OpenAI API)
- Vector similarity: <10ms (pgvector IVFFLAT)
- Total: ~250-550ms

**Scalability:**
- Handles 500K+ FEN embeddings efficiently
- Search index rebuild: ~30s per 100K documents
- Recommended max: 10M positions per database

## Deployment Considerations

### Database Sizing

| Component | Size per Game | 10K Games | 100K Games |
|-----------|--------------|-----------|------------|
| Game metadata | ~500 bytes | 5 MB | 50 MB |
| Positions | ~200 bytes/move | 20 MB | 200 MB |
| FEN embeddings | 3 KB/unique | 1 MB | 3 MB |
| Search documents | 2 KB/entity | 20 MB | 200 MB |
| **Total estimate** | | **46 MB** | **453 MB** |

### Connection Pooling

Default: 10 connections per pool

Recommended:
- Development: 5-10
- Production (single app): 20-50
- Production (multiple apps): Coordinate across applications

### Extension Requirements

**PostgreSQL:**
- `uuid-ossp` - UUID generation
- `pgvector` - Vector similarity search
- `pgcrypto` - SHA256 checksums

Verify with:
```sql
SELECT * FROM pg_extension WHERE extname IN ('uuid-ossp', 'vector', 'pgcrypto');
```

---

## See Also

- [Developer Guide](DEVELOPER.md) - Setup, testing, CLI usage
- [Operations Guide](OPERATIONS.md) - Monitoring, troubleshooting, performance tuning
- [Guidelines](GUIDELINES.md) - Coding standards and conventions
- [API Documentation](../lib/) - Module interfaces (.mli files)
- [Release Notes](../RELEASE_NOTES.md) - Version history and migrations
- [Implementation Plan](IMPLEMENTATION_PLAN.md) - Pattern roadmap and next actions
