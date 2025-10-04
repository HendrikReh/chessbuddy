# Agent Handbook

Guidance for automated contributors working in the ChessBuddy repository (OCaml 5.1+, PostgreSQL 16 + pgvector).

---

## Project Snapshot

- **Core domains**: `lib/core`, `lib/chess`, `lib/persistence`, `lib/embedding`, `lib/search`, `lib/patterns`, `lib/ingestion`
- **Executables**: `bin/ingest.exe` (write-side), `bin/retrieve.exe` (read-side)
- **Database**: `sql/schema.sql` + migrations (notably `sql/migrations/001_pattern_framework.sql` for pattern tables)
- **Docs to consult**: `README.md`, `docs/ARCHITECTURE.md`, `docs/IMPLEMENTATION_PLAN.md`, `docs/OPERATIONS.md`, `docs/DEVELOPER.md`

### Key Modules

| Area | Files |
|------|-------|
| Chess engine & FEN | `lib/chess/chess_engine.ml`, `lib/chess/fen_generator.ml` |
| Pattern detection | `lib/patterns/pattern_detector.mli`, `strategic_patterns.ml`, `tactical_patterns.ml`, `endgame_patterns.ml` |
| Persistence layer | `lib/persistence/database.ml` |
| CLIs | `lib/ingest_cli.ml`, `lib/retrieve_cli.ml` |
| Tests | `test/test_pattern_detectors.ml`, `test/test_retrieve_cli.ml`, `test/test_chess_engine.ml`, etc. |

---

## Essential Commands

```bash
# Prepare toolchain
opam switch create . 5.1.1
opam install . --deps-only

# Database bootstrap (requires Docker)
mkdir -p data/db
docker-compose up -d
psql "postgresql://chess:chess@localhost:5433/chessbuddy" -f sql/schema.sql
psql "postgresql://chess:chess@localhost:5433/chessbuddy" -f sql/migrations/001_pattern_framework.sql

# Build / test / docs
dune build
dune runtest
dune fmt
dune build @doc

# Full ingestion loop
\
dune exec bin/ingest.exe -- ingest \
  --db-uri postgresql://chess:chess@localhost:5433/chessbuddy \
  --pgn data/games/twic1611.pgn \
  --batch-label dev-test

# Pattern query CLI
dune exec bin/retrieve.exe -- pattern --help
```

Pattern CLI examples are in `README.md` and `docs/DEVELOPER.md` – reference them when updating filters or output behaviour.

---

## Coding Standards

- Two-space indentation, hard wrap ≈90 chars
- Start implementation files with `open! Base`
- Modules in `CamelCase`; values/functions/fields in `snake_case`
- Exhaustive pattern matching and explicit `Lwt_result` handling
- Public modules must have `.mli` with OCamldoc comments (`{1 ...}` sections, `{[...]}` examples, `@param` tags)
- Run `dune fmt` before committing
- Database queries belong as top-level values in `database.ml`; use parameterised Caqti requests (never interpolate strings)

### Pattern-Specific Notes

- Detectors should implement `Pattern_detector.PATTERN_DETECTOR` and register via the shared registry
- Persist detections using `Database.record_pattern_detection` (ensures `UNIQUE(game_id, pattern_id, detected_by_color)` is respected)
- JSON metadata must be valid (`Yojson.Safe.t`) and concise – prefer key/value summaries

---

## Testing Expectations

- Use `CHESSBUDDY_REQUIRE_DB_TESTS=1 dune runtest` to enforce database-backed suites locally/CI
- Add new test helpers under `test/` mirroring library structure; register them in `test/test_suite.ml`
- For pattern logic, extend `test/test_pattern_detectors.ml` with labelled PGNs once available (see Implementation Plan §5.1)
- PGN fixtures belong in `test/fixtures/`
- Prefer unit tests for pure logic (pawn structure, heuristics) and integration tests for ingestion/query flows

---

## Documentation Checklist

When altering functionality:

1. Update `README.md` (CLI usage, examples, metrics)
2. Refresh `docs/IMPLEMENTATION_PLAN.md` (milestone status, next actions)
3. Adjust `docs/ARCHITECTURE.md` / `docs/ARCHITECTURE_DIAGRAM.md` if control flow or schema changes
4. Record operational changes in `docs/OPERATIONS.md` (monitoring SQL, backfill procedures)
5. Note release details in `RELEASE_NOTES.md`

Docs already emphasise pattern detection — keep terminology consistent (strategic, tactical, endgame) and avoid regressions to placeholder FEN language.

---

## Commit & PR Guidance

- Commit subjects: `component: imperative action` (e.g., `patterns: tighten queenside detection`)
- Include bodies for rationale, schema/data impact, `Fixes #ID`
- PRs must list verification steps (e.g., `dune build`, `dune runtest`, manual CLI commands)
- Call out migrations/backfills and new env vars (
  e.g., toggling OpenAI embeddings via `CHESSBUDDY_USE_OPENAI_EMBEDDINGS`)

---

## Security & Configuration

- Dev credentials: `postgresql://chess:chess@localhost:5433` (override in production)
- Keep secrets out of VCS (`.env`, CI secrets)
- Provide stubs/mocks for external services (OpenAI) in tests/CI
- Review `docs/OPERATIONS.md` for backup, recovery, and incident procedures

---

## Quick Reference

- **Pattern SQL metrics**: see `docs/OPERATIONS.md` for coverage/confidence queries
- **Pattern CLI**: `dune exec bin/retrieve.exe -- pattern ...`
- **Implementation Plan status**: `docs/IMPLEMENTATION_PLAN.md` (remaining validation tasks)
- **Architecture diagrams**: `docs/ARCHITECTURE_DIAGRAM.md`

Use this handbook alongside repository docs to stay aligned with current behaviour. Update this file when workflows or conventions change.
