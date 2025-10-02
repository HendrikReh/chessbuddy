# Repository Guidelines

## Project Structure & Module Organization
Core OCaml modules live under `lib/` and are kept small and purpose driven:
- `database.ml` – Caqti-based persistence helpers for PostgreSQL/pgvector
- `ingestion_pipeline.ml` – Orchestrates PGN ingestion, player upserts, and embedding writes
- `pgn_source.ml` – Parses PGN headers and SAN moves into structured records
- `fen_generator.ml` / `.mli` – Placeholder FEN generation utilities
- `embedder.ml`, `search_embedder.ml`, `openai_client.ml` – Embedding providers for positions and search documents
- `search_indexer.ml`, `search_service.ml`, `search_indexer.ml` – Text indexing and query helpers
- `types.ml` – Shared record types

CLI entry points live in `bin/`:
- `ingest.ml` wraps `lib/ingest_cli.ml`
- `retrieve.ml` wraps `lib/retrieve_cli.ml`

Database schema files live in `sql/`, with PGN samples under `data/`. Tests in `test/` mirror the library modules (for example, `test_database.ml`, `test_vector.ml`). Update `lib/dune` and `test/dune` whenever new modules are added.

## Build, Test, and Development Commands
- `opam switch create . 5.1.1` (first setup) then `opam install . --deps-only` – prepare the toolchain
- `dune build` – compile everything; add `@install` to verify installability
- `dune exec bin/ingest.exe -- --help` – inspect ingestion subcommands
- `dune exec bin/retrieve.exe -- --help` – inspect retrieval subcommands
- `dune exec bin/ingest.exe -- --db-uri postgresql://chess:chess@localhost:5433/chessbuddy --pgn data/games/twic1611.pgn --batch-label dev-test` – run a full ingestion
- `dune runtest` – execute Alcotest suites; set `CHESSBUDDY_REQUIRE_DB_TESTS=1` to fail when PostgreSQL is unavailable
- `mkdir -p data/db && docker-compose up -d` followed by `psql postgresql://chess:chess@localhost:5433/chessbuddy -f sql/schema.sql` – bootstrap PostgreSQL with pgvector

## Coding Style & Naming Conventions
- Use two-space indentation and keep lines ≲90 characters
- Modules use `CamelCase`; values, functions, and record fields use `snake_case`
- Every implementation module must `open! Base`; reach for `Stdlib.<module>` only when Base does not provide an equivalent
- Prefer descriptive record fields and exhaustive pattern matches
- Run `dune fmt` (ocamlformat ≥0.27) before committing changes
- Handle `Lwt_result` branches explicitly to surface database errors

## Testing Guidelines
- The test suite uses Alcotest_lwt; start PostgreSQL via Docker before running `dune runtest`
- Reuse `Test_helpers.with_clean_db` to reset schema with `sql/schema.sql`
- Mirror new library behaviour with `test_<behavior>` helpers registered in `test/test_suite.ml`
- Focus coverage on player upserts, batch dedupe, FEN handling, search indexing, and embedding persistence; add fixtures under `test/fixtures/` when needed

## Commit & Pull Request Guidelines
- Use imperative, component-scoped commit subjects (e.g., `database: tighten batch dedupe`)
- Include context, follow-up notes, and `Fixes #123` references in commit bodies when closing issues
- Pull requests should summarise scope, list verification steps (`dune build`, `dune runtest`, manual ingestion commands), and note schema or data impacts

## Security & Configuration Tips
- Development credentials are defined in `docker-compose.yml` (`chess:chess@localhost:5433`); override them via environment variables in production
- Keep secrets (e.g., `OPENAI_API_KEY` for the search indexer) out of version control and document new configuration toggles
- Provide mock or stub implementations for external services so CI can run without network access
