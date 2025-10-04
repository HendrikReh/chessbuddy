# Implementation Plan: Extensible Pattern Detection System

**Status:** Active – Iteration 3.1
**Last Updated:** 2025-10-04
**Target:** Answer generalized pattern queries such as:
> “List me at least 5 games where **{color}** executes a successful **{strategy_pattern | tactical_pattern}** in **{opening}**. **{color}** should have ≥ **{min_elo}** and the opponent at least **{elo_gap}** points lower.”

---

## 1. Executive Summary

ChessBuddy now ships a full pattern-detection pipeline and query surface:

- **Generalized detectors** for strategic, tactical, and endgame motifs (see §2).
- **Ingestion-time analysis** that records pattern detections, confidence, ply range, and rich metadata (`pattern_detections` table).
- **Retrieve CLI (`pattern` command)** with advanced filters (confidence, ECO/opening, rating spans, move counts, names, dates, JSON/CSV output).
- **Database helpers** (`Database.query_games_with_pattern`) powering application code and tooling.

✅ We can answer both the original King’s Indian queenside attack request and the generalized template above.
⚠️ Remaining work focuses on deeper validation datasets, precision/recall tracking, and operational dashboards (see §5).

---

## 2. Current Capability Matrix

| Area | Status | Notes |
|------|--------|-------|
| Schema & migrations | ✅ Complete | `pattern_detections`, `pattern_catalog`, and indexes live (migration `001_pattern_framework.sql`). |
| Detector framework | ✅ Complete | `Pattern_detector` module type, registry, pawn/endgame helpers implemented. |
| Strategic detectors | ✅ Complete | Queenside majority, minority attack. |
| Tactical detectors | ✅ Complete | Greek gift sacrifice with follow-up validation. |
| Endgame detectors | ✅ Complete | Lucena, Philidor (bridge/blockade recognition). |
| Ingestion integration | ✅ Complete | Pipeline runs all registered detectors and persists results. |
| Query interface | ✅ Complete | Retrieve CLI `pattern` command + DB API support optional filters. |
| CLI output options | ✅ Complete | Table/JSON/CSV, `--output-file`, `--include-metadata`, `--count-only`, `--no-summary`. |
| Documentation | ⚠️ In progress | This plan, README, Architecture, Operations updated in this sweep; pattern-specific cookbook planned. |
| Validation datasets | 🔄 In progress | Need labeled corpus (Kasparov/Kramnik, classic Greek gift, rook endings). |
| Monitoring & dashboards | 🔄 Planned | Materialized view + Grafana panels (success rate, false positives). |

---

## 3. Milestone Status

| Milestone | Scope | Status | Notes |
|-----------|-------|--------|-------|
| **M1** – Schema foundation | SQL migration, indexes, catalog seeding | ✅ Done | Applied via `sql/migrations/001_pattern_framework.sql` and reflected in schema.md. |
| **M2** – Detector framework | Pattern interfaces, pawn structure helpers, detectors | ✅ Done | `lib/patterns/*`, `lib/chess/pawn_structure.ml`, unit tests in `test_pattern_detectors.ml`. |
| **M3** – Ingestion integration | Pipeline wiring, persistence, backfill hooks | ✅ Done | `Ingestion_pipeline` calls registry; detections stored with metadata. |
| **M4** – Query experience | Database query, retrieve CLI enhancements | ✅ Done | `Database.query_games_with_pattern` covers all filters; CLI supports export formats. |
| **M5** – Validation & QA | Accuracy datasets, precision/recall, benchmarks | 🔄 In progress | Harness implemented (`benchmark/benchmark.exe --pattern-samples`); still needs curated PGNs and sustained false-positive review. |
| **M6** – Operations rollout | Monitoring, docs, production checklist | 🔄 Planned | To follow once QA metrics stabilise. |

---

## 4. How the System Answers the Generalized Query

1. **Ingestion** (`bin/ingest.exe`):
   - PGNs parsed → chess engine generates true FENs → detectors run after move import.
   - Each detection records pattern_id, initiating color, success flag, confidence, start/end ply, and metadata JSON.

2. **Persistence** (`pattern_detections`):
   ```text
   detection_id · game_id · pattern_id · detected_by_color · success · confidence
   start_ply · end_ply · outcome · metadata JSONB
   ```

3. **Query path**:
   - `Database.query_games_with_pattern` accepts pattern IDs, optional `detected_by`, min/max confidence, ECO/pattern substring filters, ELO bounds, rating gaps, move-count ranges, date/name/result filters, pagination.
   - Retrieve CLI `pattern` command exposes those options plus output shaping.

4. **Generalized Example**:
   ```bash
   dune exec bin/retrieve.exe -- pattern \
     --db-uri $DB_URI \
     --pattern queenside_majority_attack \
     --detected-by white \
     --success true \
     --eco-prefix E6 \
     --opening-contains "King's Indian" \
     --min-white-elo 2500 \
     --min-elo-diff 100 \
     --min-confidence 0.7 \
     --limit 5 \
     --output json --include-metadata
   ```

5. **General Template Support**: Swap pattern ID(s) and opening strings, adjust `--detected-by`, min/max ELO, or extend with `--pattern` list for multiple motifs.

---

## 5. Next Actions

### 5.1 Validation & Quality (Milestone 5)
- **Curate labelled PGNs** for each detector (queenside breakthroughs, classic Greek gift games, Lucena/Philidor endgames) under `data/validation/`.
- **Automate precision/recall checks** in `test/test_pattern_detectors.ml` using labelled truth sets; target ≥90% precision, ≥85% recall per pattern.
- **Benchmark throughput** with `dune exec benchmark/benchmark.exe -- --pattern-samples 50` (target ≥100 detections/sec on Apple M2 Pro); capture runs in `benchmark/README.md` for regression tracking.
- **False-positive triage** via `pattern_validation` table (manual review workflow).

### 5.2 Operationalisation (Milestone 6)
- **Dashboard queries**: materialized view summarising detections by pattern/result/confidence; feed Grafana panels.
- **Alerting**: define SLOs (e.g., pattern success rate <70% triggers review).
- **Runbooks**: extend `docs/OPERATIONS.md` with pattern-analysis troubleshooting and backfill guidance.
- **Backfill script**: sample `dune exec bin/ingest.exe -- analyze` helper for reprocessing historical batches.

---

## 6. Interfaces & Key Modules

| File | Purpose |
|------|---------|
| `lib/patterns/pattern_detector.mli` | Detector interface & registry. |
| `lib/patterns/strategic_patterns.ml` | Queenside majority, minority attack detectors. |
| `lib/patterns/tactical_patterns.ml` | Greek gift pattern detection. |
| `lib/patterns/endgame_patterns.ml` | Lucena, Philidor detectors. |
| `lib/chess/pawn_structure.ml` | Pawn-count utilities for majority detection. |
| `lib/persistence/database.ml` | `record_pattern_detection`, `query_games_with_pattern`. |
| `lib/retrieve_cli.ml` | `pattern` command with filters/output modes. |
| `test/test_pattern_detectors.ml` | Unit + integration coverage for detectors. |

---

## 7. Query Cheat Sheet

| Scenario | Example |
|----------|---------|
| King’s Indian queenside attack | `--pattern queenside_majority_attack --eco-prefix E6 --opening-contains "King's Indian" --min-white-elo 2500 --min-elo-diff 100 --success true --min-confidence 0.7 --limit 5` |
| Tactical motifs by Black | `--pattern greek_gift_sacrifice --detected-by black --min-confidence 0.6 --result 0-1 --limit 10` |
| Endgame themes | `--pattern lucena_position --pattern philidor_position --min-confidence 0.5 --min-move-count 60` |
| Batch statistics only | Add `--count-only --no-summary` for scripts. |
| Export for tooling | `--output json --output-file results.json --include-metadata` or `--output csv` for spreadsheets. |

---

## 8. References & Related Docs

- [Architecture](ARCHITECTURE.md): System overview and module map.
- [Architecture Diagram](ARCHITECTURE_DIAGRAM.md): Sequence & deployment diagrams updated with pattern pipeline.
- [Developer Guide](DEVELOPER.md): Setup, database prep, testing flags.
- [Operations Guide](OPERATIONS.md): Backups, migrations, pattern backfills.
- [OCaml AI Assistant Guide](OCAML_AI_ASSISTANT_GUIDE.md): Best practices for automated contributors.
- [Release Notes](../RELEASE_NOTES.md): Version history (0.0.8 includes detector framework).
- [SQL Schema](../sql/schema.sql): Tables, indexes, migrations.

---

## 9. Changelog

### v3.1 (2025-10-04)
- Condensed plan to reflect completed milestones and remaining validation/operations work.
- Documented generalized query flow, CLI options, and module map.
- Added next-action checklist for validation datasets and monitoring.

### v3.0 (2025-10-04)
- Major rewrite to unify generalisation summary with implementation plan. (Superseded by v3.1.)

---

**Owners:** ChessBuddy Development Team
**Review Cadence:** Monthly or after major detector additions
