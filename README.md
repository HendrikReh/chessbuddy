# ChessBuddy

[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D%205.1-orange.svg)](https://ocaml.org)
[![Status](https://img.shields.io/badge/Status-Proof%20of%20Concept-yellow.svg)](https://github.com/HendrikReh/chessbuddy)
[![Build Status](https://img.shields.io/github/actions/workflow/status/HendrikReh/chessbuddy/ci.yml?branch=main)](https://github.com/HendrikReh/chessbuddy/actions)
[![License](https://img.shields.io/github/license/HendrikReh/chessbuddy)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/HendrikReh/chessbuddy)
[![Collaboration](https://img.shields.io/badge/Collaboration-Guidelines-blue.svg)](docs/GUIDELINES.md)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg)](https://github.com/HendrikReh/chessbuddy/graphs/commit-activity)

Retrieval system for chess training that combines a relational database (PGN games) with a vector database (FEN embeddings).

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
- **OCaml ingestion service**: Parses PGN files, reconstructs FEN positions, computes engineered features, and stores both relational rows and vector embeddings.
- **Schema definition**: `sql/schema.sql` can be applied to the Postgres instance to bootstrap tables, indexes, and helper views/materialized views for thematic queries.

## Getting started

1. Start the database and apply the schema:

   ```bash
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

The executable streams PGN games, deduplicates FENs, produces embeddings (via a pluggable provider), and persists metadata ready for hybrid SQL + vector search queries.

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

See [docs/DEVELOPER.md](docs/DEVELOPER.md) for information on integration tests with Alcotest.

---

<p align="center">
  <img src="https://img.shields.io/badge/Version-0.1.0-red.svg" alt="Version">
  <img src="https://img.shields.io/badge/Stage-Experimental-orange.svg" alt="Experimental">
  <img src="https://img.shields.io/badge/Made%20with-OCaml-orange.svg" alt="Made with OCaml">
  <img src="https://img.shields.io/github/last-commit/HendrikReh/chessbuddy" alt="Last Commit">
  <img src="https://img.shields.io/github/issues/HendrikReh/chessbuddy" alt="Issues">
  <img src="https://img.shields.io/github/stars/HendrikReh/chessbuddy?style=social" alt="Stars">
</p>
