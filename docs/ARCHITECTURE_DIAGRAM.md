# ChessBuddy Architecture Diagram

This document contains Mermaid diagrams visualizing the ChessBuddy system architecture and data flows.

---

## System Architecture Overview

```mermaid
graph TB
    subgraph "User Interface Layer"
        CLI[CLI Commands]
        User((User))
    end

    subgraph "Application Layer"
        IngestCLI[Ingest CLI<br/>bin/ingest.exe]
        QueryCLI[Query CLI<br/>bin/query.exe]
        AnalyzeCLI[Analyze CLI<br/>bin/analyze.exe]
        RetrieveCLI[Retrieve CLI<br/>bin/retrieve.exe]
    end

    subgraph "Business Logic Layer"
        PGNParser[PGN Parser<br/>pgn_source.ml]
        ChessEngine[Chess Engine<br/>chess_engine.ml]
        FENGen[FEN Generator<br/>fen_generator.ml]
        PatternDetector[Pattern Detectors<br/>pattern_detector.ml]
        Embedder[Embedder<br/>embedder.ml]
        SearchService[Search Service<br/>search_service.ml]
        IngestionPipeline[Ingestion Pipeline<br/>ingestion_pipeline.ml]
        GameAnalyzer[Game Analyzer<br/>game_analyzer.ml]
    end

    subgraph "Data Access Layer"
        Database[Database Module<br/>database.ml]
        PoolMgr[Connection Pool<br/>Caqti Pool]
    end

    subgraph "Storage Layer"
        PostgreSQL[(PostgreSQL<br/>Relational DB)]
        PgVector[(pgvector<br/>Vector Extension)]
    end

    subgraph "External Data"
        PGNFiles[PGN Files<br/>TWIC Archives]
    end

    User --> CLI
    CLI --> IngestCLI
    CLI --> QueryCLI
    CLI --> AnalyzeCLI
    CLI --> RetrieveCLI

    IngestCLI --> IngestionPipeline
    QueryCLI --> SearchService
    AnalyzeCLI --> GameAnalyzer
    RetrieveCLI --> Database

    IngestionPipeline --> PGNParser
    IngestionPipeline --> ChessEngine
    IngestionPipeline --> FENGen
    IngestionPipeline --> Embedder
    IngestionPipeline --> Database

    GameAnalyzer --> PatternDetector
    GameAnalyzer --> Database

    SearchService --> Database
    SearchService --> Embedder

    PGNParser --> ChessEngine
    ChessEngine --> FENGen

    Database --> PoolMgr
    PoolMgr --> PostgreSQL
    PostgreSQL --> PgVector

    PGNFiles --> PGNParser

    classDef userLayer fill:#e1f5ff,stroke:#0288d1,stroke-width:2px
    classDef appLayer fill:#fff3e0,stroke:#f57c00,stroke-width:2px
    classDef logicLayer fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px
    classDef dataLayer fill:#e8f5e9,stroke:#388e3c,stroke-width:2px
    classDef storageLayer fill:#ffebee,stroke:#c62828,stroke-width:2px
    classDef externalLayer fill:#fafafa,stroke:#616161,stroke-width:2px

    class User,CLI userLayer
    class IngestCLI,QueryCLI,AnalyzeCLI,RetrieveCLI appLayer
    class PGNParser,ChessEngine,FENGen,PatternDetector,Embedder,SearchService,IngestionPipeline,GameAnalyzer logicLayer
    class Database,PoolMgr dataLayer
    class PostgreSQL,PgVector storageLayer
    class PGNFiles externalLayer
```

---

## Ingestion Flow

```mermaid
sequenceDiagram
    actor User
    participant CLI as Ingest CLI
    participant Pipeline as Ingestion Pipeline
    participant PGN as PGN Parser
    participant Chess as Chess Engine
    participant FEN as FEN Generator
    participant Embed as Embedder
    participant DB as Database
    participant PG as PostgreSQL
    participant Vec as pgvector

    User->>CLI: dune exec bin/ingest.exe<br/>--pgn games.pgn
    CLI->>Pipeline: Start ingestion

    Pipeline->>DB: Create batch record
    DB->>PG: INSERT INTO ingestion_batches
    PG-->>DB: batch_id (UUID)
    DB-->>Pipeline: batch_id

    loop For each game in PGN
        Pipeline->>PGN: Parse game
        PGN-->>Pipeline: Game header + moves (SAN)

        Pipeline->>DB: Upsert players
        DB->>PG: INSERT INTO players<br/>ON CONFLICT UPDATE
        PG-->>DB: player_ids
        DB-->>Pipeline: white_id, black_id

        Pipeline->>DB: Record game
        DB->>PG: INSERT INTO games
        PG-->>DB: game_id
        DB-->>Pipeline: game_id

        loop For each move
            Pipeline->>Chess: Apply SAN move
            Chess-->>Pipeline: Board state

            Pipeline->>FEN: Generate FEN
            FEN->>Chess: Get board position
            Chess-->>FEN: Position data
            FEN-->>Pipeline: FEN string

            Pipeline->>DB: Deduplicate FEN
            DB->>PG: INSERT INTO fens<br/>ON CONFLICT DO NOTHING
            PG-->>DB: fen_id
            DB-->>Pipeline: fen_id (existing or new)

            alt FEN is new
                Pipeline->>Embed: Generate embedding
                Embed-->>Pipeline: 768-d vector

                Pipeline->>DB: Store embedding
                DB->>Vec: INSERT INTO fen_embeddings
                Vec-->>DB: OK
            end

            Pipeline->>DB: Record position
            DB->>PG: INSERT INTO games_positions
            PG-->>DB: position_id
        end
    end

    Pipeline->>DB: Finalize batch
    DB->>PG: UPDATE ingestion_batches<br/>SET status = 'completed'
    PG-->>DB: OK

    Pipeline-->>CLI: Ingestion complete<br/>(X games, Y positions, Z unique FENs)
    CLI-->>User: ✅ Success report
```

---

## Pattern Analysis Flow

```mermaid
sequenceDiagram
    actor User
    participant CLI as Analyze CLI
    participant Analyzer as Game Analyzer
    participant Registry as Pattern Registry
    participant Detector as Pattern Detectors
    participant Chess as Chess Engine
    participant DB as Database
    participant PG as PostgreSQL

    User->>CLI: dune exec bin/analyze.exe<br/>--batch-id UUID<br/>--pattern-types tactical
    CLI->>Registry: Get detectors by type
    Registry-->>CLI: [Greek_gift, ...]

    CLI->>DB: Fetch games in batch
    DB->>PG: SELECT FROM games<br/>WHERE batch_id = UUID
    PG-->>DB: game_ids
    DB-->>CLI: game_ids

    loop For each game (parallel)
        CLI->>Analyzer: Analyze game

        Analyzer->>DB: Fetch game details + moves
        DB->>PG: SELECT games_positions<br/>JOIN games
        PG-->>DB: moves with FENs
        DB-->>Analyzer: game_detail

        loop For each pattern detector
            Analyzer->>Detector: detect(moves, result)

            Detector->>Chess: Analyze positions
            Chess-->>Detector: Board states

            Detector-->>Analyzer: detection_result<br/>{detected, confidence, metadata}

            Analyzer->>Detector: classify_success(detection, result)
            Detector-->>Analyzer: (success, outcome)

            alt Pattern detected
                Analyzer->>DB: Record detection
                DB->>PG: INSERT INTO pattern_detections<br/>(pattern_id, confidence, outcome, ...)
                PG-->>DB: detection_id
            end
        end
    end

    CLI-->>User: ✅ Analyzed X games<br/>Y patterns detected
```

---

## Retrieval Flow (Game Query)

```mermaid
sequenceDiagram
    actor User
    participant CLI as Retrieve CLI
    participant DB as Database
    participant PG as PostgreSQL

    User->>CLI: dune exec bin/retrieve.exe<br/>game --id UUID
    CLI->>DB: Get game detail

    DB->>PG: SELECT * FROM games<br/>WHERE game_id = UUID
    PG-->>DB: game record

    DB->>PG: SELECT * FROM players<br/>WHERE player_id IN (white_id, black_id)
    PG-->>DB: player records

    DB->>PG: SELECT * FROM games_positions<br/>WHERE game_id = UUID<br/>ORDER BY ply
    PG-->>DB: move sequence

    DB-->>CLI: game_detail<br/>{header, players, moves}
    CLI-->>User: Game details<br/>(Event, Players, Moves, Result)
```

---

## Search Flow (Pattern Query)

```mermaid
sequenceDiagram
    actor User
    participant CLI as Query CLI
    participant Search as Search Service
    participant Query as Query Builder
    participant DB as Database
    participant PG as PostgreSQL

    User->>CLI: dune exec bin/query.exe<br/>--pattern "queenside_majority_attack"<br/>--opening "King's Indian"<br/>--min-white-elo 2500<br/>--success-only

    CLI->>Query: Build query
    Query-->>CLI: SQL + params

    CLI->>DB: Execute pattern query

    DB->>PG: SELECT g.*, pd.*<br/>FROM games g<br/>JOIN pattern_detections pd<br/>JOIN pattern_catalog pc<br/>WHERE eco_code BETWEEN 'E60' AND 'E99'<br/>AND white_elo >= 2500<br/>AND pd.pattern_id = '...'<br/>AND pd.success = true

    PG-->>DB: matching game records
    DB-->>CLI: game_overviews

    CLI-->>User: Found X games:<br/>1. Player1 vs Player2 (E97 1-0)<br/>2. Player3 vs Player4 (E92 1-0)<br/>...
```

---

## Semantic Search Flow (Vector Similarity)

```mermaid
sequenceDiagram
    actor User
    participant CLI as Query CLI
    participant Search as Search Service
    participant Embed as Embedder
    participant DB as Database
    participant Vec as pgvector
    participant PG as PostgreSQL

    User->>CLI: Search similar positions<br/>to FEN string

    CLI->>Search: Find similar positions

    Search->>Embed: Generate query embedding
    Embed-->>Search: query_vector (768-d)

    Search->>DB: Vector similarity search

    DB->>Vec: SELECT fen_id, fens.fen_string,<br/>embedding <=> query_vector AS distance<br/>FROM fen_embeddings<br/>JOIN fens<br/>ORDER BY distance<br/>LIMIT 10

    Vec-->>DB: similar FENs with distances

    DB->>PG: SELECT games_positions.*<br/>FROM games_positions<br/>WHERE fen_id IN (...)

    PG-->>DB: positions using similar FENs
    DB-->>Search: similar_positions

    Search-->>CLI: Ranked results
    CLI-->>User: Top 10 similar positions:<br/>1. Game X, Move 15 (distance: 0.12)<br/>2. Game Y, Move 23 (distance: 0.18)<br/>...
```

---

## Database Schema Overview

```mermaid
erDiagram
    PLAYERS ||--o{ GAMES : "plays as white"
    PLAYERS ||--o{ GAMES : "plays as black"
    INGESTION_BATCHES ||--o{ GAMES : contains
    GAMES ||--o{ GAMES_POSITIONS : "has moves"
    GAMES ||--o{ PATTERN_DETECTIONS : "has patterns"
    FENS ||--o{ GAMES_POSITIONS : "appears in"
    FENS ||--o| FEN_EMBEDDINGS : "has embedding"
    PATTERN_CATALOG ||--o{ PATTERN_DETECTIONS : "defines"
    PATTERN_DETECTIONS ||--o{ PATTERN_VALIDATION : "validated by"

    PLAYERS {
        uuid player_id PK
        text full_name
        text full_name_key
        int fide_id
        timestamptz created_at
    }

    INGESTION_BATCHES {
        uuid batch_id PK
        text label
        text pgn_source
        bytea pgn_sha256
        text status
        timestamptz started_at
        timestamptz completed_at
    }

    GAMES {
        uuid game_id PK
        uuid batch_id FK
        uuid white_id FK
        uuid black_id FK
        text event
        text site
        date game_date
        int round_num
        text result
        text eco_code
        text opening_name
        int white_elo
        int black_elo
        bytea pgn_hash
    }

    GAMES_POSITIONS {
        uuid position_id PK
        uuid game_id FK
        uuid fen_id FK
        int ply
        text san
        text uci
        text fen_before
        text fen_after
        jsonb annotations
    }

    FENS {
        uuid fen_id PK
        text fen_string
        text side_to_move
        text castling_rights
        text en_passant_square
        int halfmove_clock
        int fullmove_number
        text material_signature
    }

    FEN_EMBEDDINGS {
        uuid fen_id PK_FK
        vector embedding
        timestamptz created_at
    }

    PATTERN_CATALOG {
        text pattern_id PK
        text pattern_name
        text pattern_type
        text description
        text detector_module
        jsonb success_criteria
        bool enabled
    }

    PATTERN_DETECTIONS {
        uuid detection_id PK
        uuid game_id FK
        text pattern_id FK
        text detected_by_color
        bool success
        real confidence
        int start_ply
        int end_ply
        text outcome
        jsonb metadata
    }

    PATTERN_VALIDATION {
        uuid validation_id PK
        uuid detection_id FK
        bool manually_verified
        text verified_by
        timestamptz verified_at
        text notes
    }
```

---

## Data Flow Summary

```mermaid
graph LR
    subgraph "Input"
        PGN[PGN Files<br/>Chess Games]
    end

    subgraph "Processing"
        Parse[Parse PGN<br/>Extract Moves]
        Engine[Chess Engine<br/>Board State]
        FEN[FEN Generator<br/>Position Notation]
        Embed[Embedder<br/>Vector Generation]
        Detect[Pattern Detector<br/>Strategic Analysis]
    end

    subgraph "Storage"
        Games[(Games Table<br/>Metadata)]
        Positions[(Positions Table<br/>Moves)]
        FENs[(FENs Table<br/>Unique Positions)]
        Vectors[(Embeddings Table<br/>768-d Vectors)]
        Patterns[(Pattern Detections<br/>Strategic Themes)]
    end

    subgraph "Output"
        Retrieve[Game Retrieval<br/>By ID/Player]
        Search[Semantic Search<br/>Similar Positions]
        Query[Pattern Query<br/>Strategic Filtering]
    end

    PGN --> Parse
    Parse --> Engine
    Engine --> FEN
    FEN --> Embed
    Parse --> Games
    Engine --> Positions
    FEN --> FENs
    Embed --> Vectors

    Games --> Detect
    Positions --> Detect
    Detect --> Patterns

    Games --> Retrieve
    Positions --> Retrieve
    Vectors --> Search
    Patterns --> Query
    Games --> Query

    classDef input fill:#e3f2fd,stroke:#1976d2
    classDef process fill:#f3e5f5,stroke:#7b1fa2
    classDef storage fill:#ffebee,stroke:#c62828
    classDef output fill:#e8f5e9,stroke:#388e3c

    class PGN input
    class Parse,Engine,FEN,Embed,Detect process
    class Games,Positions,FENs,Vectors,Patterns storage
    class Retrieve,Search,Query output
```

---

## Component Responsibilities

| Component | Purpose | Key Functions |
|-----------|---------|---------------|
| **PGN Parser** | Parse chess game files | Extract headers, moves, annotations |
| **Chess Engine** | Board state management | Apply moves, validate positions, generate FENs |
| **FEN Generator** | Position notation | Convert board state to FEN strings |
| **Embedder** | Vector generation | Transform FENs to 768-d embeddings |
| **Pattern Detector** | Strategic analysis | Detect queenside attack, Greek gift, endgames |
| **Game Analyzer** | Batch pattern detection | Run all detectors on games |
| **Search Service** | Semantic search | Find similar positions via vector similarity |
| **Database Module** | Data persistence | CRUD operations, query execution |
| **PostgreSQL** | Relational storage | Games, players, moves, metadata |
| **pgvector** | Vector storage | Efficient similarity search on embeddings |

---

## Technology Stack

```mermaid
graph TB
    subgraph "Programming Language"
        OCaml[OCaml 5.1+<br/>Functional Programming]
    end

    subgraph "Libraries"
        Base[Jane Street Base<br/>Standard Library]
        Lwt[Lwt<br/>Async Concurrency]
        Caqti[Caqti<br/>Database Interface]
        Cmdliner[Cmdliner<br/>CLI Framework]
    end

    subgraph "Database"
        PG[PostgreSQL 14+<br/>Relational DB]
        PgVec[pgvector Extension<br/>Vector Similarity]
    end

    subgraph "Build Tools"
        Dune[Dune 3.10+<br/>Build System]
        Opam[Opam<br/>Package Manager]
    end

    OCaml --> Base
    OCaml --> Lwt
    OCaml --> Caqti
    OCaml --> Cmdliner
    Caqti --> PG
    PG --> PgVec
    OCaml --> Dune
    Dune --> Opam

    classDef lang fill:#ff6b6b,stroke:#c92a2a
    classDef lib fill:#4ecdc4,stroke:#0d7377
    classDef db fill:#ffe66d,stroke:#ffa94d
    classDef build fill:#95e1d3,stroke:#38ada9

    class OCaml lang
    class Base,Lwt,Caqti,Cmdliner lib
    class PG,PgVec db
    class Dune,Opam build
```

---

**Document Version:** 1.0
**Created:** 2025-10-04
**Last Updated:** 2025-10-04
