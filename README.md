# chessbuddy

Retrieval system for chess training that combines a relational database (PGN games) with a vector database (FEN embeddings).

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
