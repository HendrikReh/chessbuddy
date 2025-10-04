# Implementation Plan: Extensible Pattern Detection System

**Status:** Active Development
**Last Updated:** 2025-10-04
**Target:** Enable generalized pattern detection and complex filtering
**Document Version:** 3.0

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Implementation Roadmap](#implementation-roadmap)
4. [Pattern Detector Examples](#pattern-detector-examples)
5. [Adding New Patterns](#adding-new-patterns)
6. [Migration Strategy](#migration-strategy)
7. [Technical Reference](#technical-reference)
8. [Success Criteria](#success-criteria)
9. [References](#references)
10. [Changelog](#changelog)

---

## Executive Summary

### Generalized Query Template

**Before (Specific):**
> "List me at least 5 games where White executes a successful queenside majority attack in the King's Indian Defence."

**After (Generalized):**
> "List me at least 5 games where **{color}** executes a successful **{pattern}** in **{opening}**. {color} should have at least **{min_elo}** ELO rating, and opponent at least **{elo_difference}** ELO points lower."

### Supported Patterns

| Pattern ID | Name | Type | Description |
|-----------|------|------|-------------|
| `queenside_majority_attack` | Queenside Majority Attack | Strategic | Pawn majority on a-c files advanced to create passed pawns |
| `minority_attack` | Minority Attack | Strategic | Pawn minority attacking opponent majority to create weaknesses |
| `greek_gift_sacrifice` | Greek Gift Sacrifice | Tactical | Bxh7+ (or Bxh2+) bishop sacrifice to expose king |
| `lucena_position` | Lucena Position | Endgame | Rook endgame technique to promote pawn with building-the-bridge |
| `philidor_position` | Philidor Position | Endgame | Rook endgame defensive technique, rook on 6th rank |
| _(extensible)_ | _(user-defined)_ | _(any)_ | _(custom detectors via PATTERN_DETECTOR interface)_ |

### Example Queries

```bash
# Query 1: Queenside attack in King's Indian
dune exec bin/query.exe -- query \
  --pattern "queenside_majority_attack" \
  --opening "King's Indian" \
  --min-white-elo 2500 \
  --rating-difference 100 \
  --color white \
  --success-only \
  --limit 5

# Query 2: Any tactical pattern by White, 2600+ ELO
dune exec bin/query.exe -- query \
  --pattern-type tactical \
  --min-white-elo 2600 \
  --rating-difference 150 \
  --color white \
  --success-only \
  --limit 10

# Query 3: Greek Gift sacrifice in Sicilian Defense
dune exec bin/query.exe -- query \
  --pattern "greek_gift_sacrifice" \
  --opening "Sicilian" \
  --min-white-elo 2400 \
  --color white \
  --min-confidence 0.8 \
  --success-only \
  --limit 5

# Query 4: Endgame patterns (Lucena OR Philidor)
dune exec bin/query.exe -- query \
  --pattern "lucena_position,philidor_position" \
  --min-white-elo 2600 \
  --limit 10
```

### Current System Capabilities ✅

**Available:**
1. ✅ **ECO Opening Filter** - Schema has `eco_code` and `opening_name` fields
2. ✅ **ELO Rating Filter** - `white_elo` and `black_elo` columns with indexes
3. ✅ **Real FEN Generation** - Chess engine (v0.0.8) generates accurate positions
4. ✅ **Move Tracking** - All moves stored with SAN, FEN before/after, motifs
5. ✅ **Game Metadata** - Players, ratings, dates, results fully tracked
6. ✅ **Position Analysis** - Board state accessible via FEN parser

### Missing Capabilities ❌

**Critical Gaps:**
1. ❌ **Pattern Detection Framework** - No extensible pattern classifier architecture
2. ❌ **Pattern Registry** - No central registry of available patterns
3. ❌ **Pattern Analysis Pipeline** - No batch processing infrastructure
4. ❌ **Success Criteria System** - No pluggable success classifiers per pattern
5. ❌ **Pattern Indexing** - No materialized views for strategic/tactical themes

### Capability Assessment

**Can we answer the generalized query?** ⚠️ **Partially - with 7-week implementation**

**What we have:**
- Schema supports ECO filtering (`idx_games_eco_date`)
- ELO filtering ready (`idx_games_white_elo`, `idx_games_black_elo`)
- Position data available (FEN, board state, move sequences)

**What we need:**
- **Pattern Detection Framework** - Extensible architecture for unlimited patterns
- **Pattern Registry** - Catalog of strategic/tactical/endgame patterns
- **Pattern Analyzers** - Pluggable detectors (pawn structure, sacrifices, endgame motifs)
- **Success Classifiers** - Pattern-specific criteria (material gain, positional advantage)
- **Query Builder** - Pattern-aware SQL generation
- **Performance Optimization** - Parallel pattern scanning, caching

---

## Architecture Overview

### Key Design Principles

1. **Single Schema, Unlimited Patterns** - No schema changes required to add new patterns
2. **Pluggable Detectors** - Module type interface for pattern detection
3. **Dynamic Registry** - Runtime pattern registration and discovery
4. **Flexible Querying** - Filter by pattern ID, type, color, confidence
5. **Observable System** - Validation workflow, confidence scoring, metadata tracking

### Database Schema Evolution

#### Before: game_themes (Single-Pattern)
```sql
CREATE TABLE game_themes (
  game_id UUID PRIMARY KEY,
  queenside_majority_success BOOLEAN,  -- Hardcoded for one pattern
  motifs JSONB
);
```
**Problem:** Adding new patterns requires schema changes (new columns per pattern)

#### After: pattern_detections (Multi-Pattern)
```sql
CREATE TABLE pattern_detections (
  detection_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  game_id UUID NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
  pattern_id TEXT NOT NULL,              -- Extensible: any pattern
  detected_by_color TEXT NOT NULL CHECK (detected_by_color IN ('white', 'black')),
  success BOOLEAN NOT NULL,
  confidence REAL NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
  start_ply INT,
  end_ply INT,
  outcome TEXT CHECK (outcome IN ('victory', 'draw_advantage', 'draw_neutral', 'defeat')),
  metadata JSONB NOT NULL DEFAULT '{}',  -- Pattern-specific details
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (game_id, pattern_id, detected_by_color)
);

CREATE TABLE pattern_catalog (
  pattern_id TEXT PRIMARY KEY,
  pattern_name TEXT NOT NULL,
  pattern_type TEXT NOT NULL CHECK (pattern_type IN ('strategic', 'tactical', 'endgame', 'opening_trap')),
  description TEXT,
  detector_module TEXT NOT NULL,         -- OCaml module path
  success_criteria JSONB,
  enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Benefits:**
- ✅ One table for ALL patterns (no schema changes per pattern)
- ✅ Supports multiple patterns per game
- ✅ Both colors can execute patterns
- ✅ JSONB metadata for pattern-specific data
- ✅ Pattern catalog for dynamic discovery

### Pattern Detector Interface

```ocaml
(* lib/patterns/pattern_detector.ml *)
open! Base

type detection_result = {
  detected : bool;
  confidence : float;  (** 0.0-1.0 confidence score *)
  initiating_color : Chess_engine.color option;
  start_ply : int option;
  end_ply : int option;
  metadata : (string * Yojson.Safe.t) list;
}

type success_outcome =
  | Victory        (** Initiator won the game *)
  | DrawAdvantage  (** Draw from winning position - partial success *)
  | DrawNeutral    (** Equal endgame, pattern neutralized *)
  | Defeat         (** Pattern failed, lost game *)

module type PATTERN_DETECTOR = sig
  val pattern_id : string
  val pattern_name : string
  val pattern_type : [ `Strategic | `Tactical | `Endgame | `Opening_trap ]

  val detect :
    moves:Types.Move_feature.t list ->
    result:string ->
    detection_result Lwt.t

  val classify_success :
    detection:detection_result ->
    result:string ->
    (bool * success_outcome) Lwt.t
end

module Registry : sig
  val register : (module PATTERN_DETECTOR) -> unit
  val get_detector : string -> (module PATTERN_DETECTOR) option
  val list_patterns :
    ?pattern_type:[ `Strategic | `Tactical | `Endgame | `Opening_trap ] ->
    unit ->
    (module PATTERN_DETECTOR) list
  val pattern_ids : unit -> string list
end
```

---

## Implementation Roadmap

### Timeline Overview

| Milestone | Duration | Status |
|-----------|----------|--------|
| M1: Database Schema Enhancement | Week 1 | ⏳ Pending |
| M2: Pattern Detection Framework | Week 2-3 | ⏳ Pending |
| M3: Game Analysis Pipeline | Week 4 | ⏳ Pending |
| M4: Query Interface | Week 5 | ⏳ Pending |
| M5: Validation & Testing | Week 6 | ⏳ Pending |
| M6: Production Deployment | Week 7 | ⏳ Pending |

**Total Estimated Time:** 7 weeks (1-2 developers)

---

### Milestone 1: Database Schema Enhancement (Week 1)

**Goal:** Extend schema to support generalized pattern detection

#### Task 1.1: ECO Code Indexing
```sql
-- Add ECO-specific indexes for opening filtering
CREATE INDEX IF NOT EXISTS idx_games_eco_kings_indian
ON games (eco_code)
WHERE eco_code LIKE 'E6%' OR eco_code LIKE 'E7%'
   OR eco_code LIKE 'E8%' OR eco_code LIKE 'E9%';

-- Add composite index for rating + opening queries
CREATE INDEX IF NOT EXISTS idx_games_eco_white_elo
ON games (eco_code, white_elo DESC NULLS LAST, black_elo DESC NULLS LAST);
```

#### Task 1.2: Pattern Detection Tables
```sql
-- Rename existing table
ALTER TABLE game_themes RENAME TO game_patterns_legacy;

-- Generalized pattern tracking
CREATE TABLE IF NOT EXISTS pattern_detections (
  detection_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  game_id UUID NOT NULL REFERENCES games(game_id) ON DELETE CASCADE,
  pattern_id TEXT NOT NULL,
  detected_by_color TEXT NOT NULL CHECK (detected_by_color IN ('white', 'black')),
  success BOOLEAN NOT NULL,
  confidence REAL NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
  start_ply INT,
  end_ply INT,
  outcome TEXT CHECK (outcome IN ('victory', 'draw_advantage', 'draw_neutral', 'defeat')),
  metadata JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (game_id, pattern_id, detected_by_color)
);

CREATE INDEX IF NOT EXISTS idx_pattern_detections_game ON pattern_detections (game_id);
CREATE INDEX IF NOT EXISTS idx_pattern_detections_pattern ON pattern_detections (pattern_id, success);
CREATE INDEX IF NOT EXISTS idx_pattern_detections_color ON pattern_detections (detected_by_color, success);
CREATE INDEX IF NOT EXISTS idx_pattern_detections_confidence ON pattern_detections (confidence DESC);
CREATE INDEX IF NOT EXISTS idx_pattern_detections_metadata ON pattern_detections USING gin (metadata);

-- Pattern catalog
CREATE TABLE IF NOT EXISTS pattern_catalog (
  pattern_id TEXT PRIMARY KEY,
  pattern_name TEXT NOT NULL,
  pattern_type TEXT NOT NULL CHECK (pattern_type IN ('strategic', 'tactical', 'endgame', 'opening_trap')),
  description TEXT,
  detector_module TEXT NOT NULL,
  success_criteria JSONB,
  enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Seed initial patterns
INSERT INTO pattern_catalog (pattern_id, pattern_name, pattern_type, detector_module, description) VALUES
  ('queenside_majority_attack', 'Queenside Majority Attack', 'strategic',
   'Strategic_patterns.Queenside_attack',
   'Pawn majority on queenside (a-c files) advanced to create passed pawns or material gain'),
  ('minority_attack', 'Minority Attack', 'strategic',
   'Strategic_patterns.Minority_attack',
   'Pawn minority attacking opponent pawn majority to create weaknesses'),
  ('greek_gift_sacrifice', 'Greek Gift Sacrifice', 'tactical',
   'Tactical_patterns.Greek_gift',
   'Bxh7+ (or Bxh2+) bishop sacrifice to expose king'),
  ('lucena_position', 'Lucena Position', 'endgame',
   'Endgame_patterns.Lucena',
   'Rook endgame technique to promote pawn with rook behind'),
  ('philidor_position', 'Philidor Position', 'endgame',
   'Endgame_patterns.Philidor',
   'Rook endgame defensive technique, rook on 6th rank')
ON CONFLICT (pattern_id) DO NOTHING;

-- Pattern validation (for accuracy monitoring)
CREATE TABLE IF NOT EXISTS pattern_validation (
  validation_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  detection_id UUID NOT NULL REFERENCES pattern_detections(detection_id) ON DELETE CASCADE,
  manually_verified BOOLEAN,
  verified_by TEXT,
  verified_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pattern_validation_detection ON pattern_validation (detection_id);
CREATE INDEX IF NOT EXISTS idx_pattern_validation_unverified
ON pattern_validation (manually_verified, created_at DESC)
WHERE manually_verified IS NULL OR manually_verified = false;
```

#### Task 1.3: Database Query Functions
```ocaml
(* lib/persistence/database.mli - Add new query functions *)

val query_games_by_opening_and_rating :
  Pool.t ->
  eco_prefix:string ->
  min_white_elo:int ->
  max_elo_difference:int ->
  limit:int ->
  (game_overview list, Caqti_error.t) Result.t Lwt.t

val query_games_by_pattern :
  Pool.t ->
  pattern_ids:string list ->
  pattern_type:[ `Strategic | `Tactical | `Endgame | `Opening_trap ] option ->
  detected_by_color:Chess_engine.color option ->
  success:bool ->
  min_confidence:float option ->
  limit:int ->
  (Uuidm.t list, Caqti_error.t) Result.t Lwt.t

val record_pattern_detection :
  Pool.t ->
  game_id:Uuidm.t ->
  pattern_id:string ->
  detected_by_color:Chess_engine.color ->
  success:bool ->
  confidence:float ->
  start_ply:int option ->
  end_ply:int option ->
  outcome:string ->
  metadata:(string * Yojson.Safe.t) list ->
  (unit, Caqti_error.t) Result.t Lwt.t
```

**Deliverables:**
- [ ] SQL migration script (`sql/migrations/001_pattern_framework.sql`)
- [ ] Database module updates (`lib/persistence/database.ml`)
- [ ] Unit tests for new query functions
- [ ] Migration verification script
- [ ] Pattern catalog seeded with 5 initial patterns

---

### Milestone 2: Pattern Detection Framework (Week 2-3)

**Goal:** Build extensible architecture for strategic, tactical, and endgame pattern detection

#### Task 2.1: Pattern Detector Core Interface
```ocaml
(* lib/patterns/pattern_detector.ml - Core framework *)
open! Base

type detection_result = {
  detected : bool;
  confidence : float;
  initiating_color : Chess_engine.color option;
  start_ply : int option;
  end_ply : int option;
  metadata : (string * Yojson.Safe.t) list;
}

type success_outcome =
  | Victory
  | DrawAdvantage
  | DrawNeutral
  | Defeat

module type PATTERN_DETECTOR = sig
  val pattern_id : string
  val pattern_name : string
  val pattern_type : [ `Strategic | `Tactical | `Endgame | `Opening_trap ]

  val detect :
    moves:Types.Move_feature.t list ->
    result:string ->
    detection_result Lwt.t

  val classify_success :
    detection:detection_result ->
    result:string ->
    (bool * success_outcome) Lwt.t
end

module Registry : sig
  val register : (module PATTERN_DETECTOR) -> unit
  val get_detector : string -> (module PATTERN_DETECTOR) option
  val list_patterns :
    ?pattern_type:[ `Strategic | `Tactical | `Endgame | `Opening_trap ] ->
    unit ->
    (module PATTERN_DETECTOR) list
  val pattern_ids : unit -> string list
end
```

#### Task 2.2: Example Pattern Implementations

See [Pattern Detector Examples](#pattern-detector-examples) section below for detailed implementations.

#### Task 2.3: Chess Engine Integration
```ocaml
(* lib/chess/chess_engine.ml - Add analysis helpers *)

val get_pawn_positions : Board.t -> color -> (int * int) list
val count_pawns_in_zone : Board.t -> color -> files:int list -> int
val evaluate_material : Board.t -> int
val get_piece_positions : Board.t -> piece -> color -> (int * int) list
```

**Deliverables:**
- [ ] `lib/patterns/pattern_detector.ml[i]` - Core pattern framework and registry
- [ ] `lib/patterns/strategic_patterns.ml[i]` - Strategic pattern detectors
- [ ] `lib/patterns/tactical_patterns.ml[i]` - Tactical pattern detectors
- [ ] `lib/patterns/endgame_patterns.ml[i]` - Endgame pattern detectors
- [ ] `lib/chess/pawn_structure.ml[i]` - Pawn analysis helpers
- [ ] `lib/chess/endgame_recognizer.ml[i]` - Endgame position recognition
- [ ] Chess engine material/position query helpers
- [ ] Test suite with known games for each pattern type
- [ ] Benchmark: analyze 1000 games with all detectors in <15 seconds

---

### Milestone 3: Game Analysis Pipeline (Week 4)

**Goal:** Batch process games to populate `pattern_detections` table with all registered patterns

#### Task 3.1: Multi-Pattern Analysis Worker
```ocaml
(* lib/analysis/game_analyzer.ml *)
open! Base

type pattern_detection_result = {
  pattern_id : string;
  detected_by_color : Chess_engine.color;
  success : bool;
  confidence : float;
  start_ply : int option;
  end_ply : int option;
  outcome : Pattern_detector.success_outcome;
  metadata : (string * Yojson.Safe.t) list;
}

type analysis_result = {
  game_id : Uuidm.t;
  detections : pattern_detection_result list;
}

val analyze_game :
  game_detail:Database.game_detail ->
  patterns:(module Pattern_detector.PATTERN_DETECTOR) list ->
  (analysis_result, string) Result.t Lwt.t

val analyze_game_with_registry :
  game_detail:Database.game_detail ->
  ?pattern_types:[ `Strategic | `Tactical | `Endgame | `Opening_trap ] list ->
  unit ->
  (analysis_result, string) Result.t Lwt.t

val batch_analyze_games :
  Database.Pool.t ->
  game_ids:Uuidm.t list ->
  parallelism:int ->
  ?pattern_types:[ `Strategic | `Tactical | `Endgame | `Opening_trap ] list ->
  unit ->
  (int, string) Result.t Lwt.t

val analyze_new_games_only :
  Database.Pool.t ->
  since:Ptime.t ->
  parallelism:int ->
  ?pattern_types:[ `Strategic | `Tactical | `Endgame | `Opening_trap ] list ->
  unit ->
  (int, string) Result.t Lwt.t
```

#### Task 3.2: Pattern Detection Persistence
```ocaml
(* lib/persistence/database.ml *)

let record_pattern_detection =
  let open Caqti_request.Infix in
  (pattern_detection_type ->. Caqti_type.unit)
  @:- {sql|
    INSERT INTO pattern_detections (
      game_id, pattern_id, detected_by_color, success, confidence,
      start_ply, end_ply, outcome, metadata
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb)
    ON CONFLICT (game_id, pattern_id, detected_by_color)
    DO UPDATE SET
      success = EXCLUDED.success,
      confidence = EXCLUDED.confidence,
      start_ply = EXCLUDED.start_ply,
      end_ply = EXCLUDED.end_ply,
      outcome = EXCLUDED.outcome,
      metadata = EXCLUDED.metadata
  |sql}

val record_pattern_detections :
  Pool.t ->
  detections:Game_analyzer.pattern_detection_result list ->
  (unit, Caqti_error.t) Result.t Lwt.t
```

#### Task 3.3: CLI Command - Analyze Patterns
```ocaml
(* lib/analysis/analyze_cli.ml *)

let analyze_cmd =
  let doc = "Analyze games for patterns and populate pattern_detections table" in
  let batch_id_opt =
    let doc = "Batch ID to analyze (optional, analyzes all if omitted)" in
    Arg.(value & opt (some string) None & info ["batch-id"] ~doc)
  in
  let parallelism =
    let doc = "Number of concurrent analysis workers (default: 4)" in
    Arg.(value & opt int 4 & info ["parallelism"; "j"] ~doc)
  in
  let pattern_types_opt =
    let doc = "Pattern types to detect (strategic,tactical,endgame,opening_trap). Default: all" in
    Arg.(value & opt (some string) None & info ["pattern-types"] ~doc)
  in
  let list_patterns =
    let doc = "List all registered patterns and exit" in
    Arg.(value & flag & info ["list-patterns"] ~doc)
  in
  Cmd.v (Cmd.info "analyze" ~doc)
    Term.(const run_analyze $ db_uri $ batch_id_opt $ parallelism $
          pattern_types_opt $ list_patterns)

let run_analyze db_uri batch_id_opt parallelism pattern_types_opt list_patterns =
  (* Register all patterns first *)
  Strategic_patterns.register_all_patterns ();
  Tactical_patterns.register_all_patterns ();
  Endgame_patterns.register_all_patterns ();

  if list_patterns then
    (* List registered patterns *)
    Pattern_detector.Registry.pattern_ids ()
    |> List.iter (fun pattern_id ->
        match Pattern_detector.Registry.get_detector pattern_id with
        | Some (module P) ->
            Printf.printf "  • %s (%s) - %s\n"
              P.pattern_id
              (match P.pattern_type with
               | `Strategic -> "strategic"
               | `Tactical -> "tactical"
               | `Endgame -> "endgame"
               | `Opening_trap -> "opening_trap")
              P.pattern_name
        | None -> ())
  else
    (* Run analysis *)
    let%lwt pool = Database.Pool.create db_uri |> Database.or_fail in
    let%lwt result = Game_analyzer.batch_analyze_games pool
      ~game_ids ~parallelism ?pattern_types () in
    match result with
    | Ok count -> Printf.printf "✅ Successfully analyzed %d games\n" count
    | Error msg -> Printf.eprintf "❌ Analysis failed: %s\n" msg

(* bin/analyze.ml *)
let () = exit (Cmdliner.Cmd.eval Analyze_cli.analyze_cmd)
```

**Example Usage:**
```bash
# Analyze all games with all patterns
dune exec bin/analyze.exe -- analyze \
  --db-uri $DB_URI \
  --batch-id UUID \
  --parallelism 8

# Analyze specific pattern types
dune exec bin/analyze.exe -- analyze \
  --db-uri $DB_URI \
  --pattern-types tactical,endgame \
  --parallelism 8

# List registered patterns
dune exec bin/analyze.exe -- analyze --list-patterns
```

**Deliverables:**
- [ ] `lib/analysis/game_analyzer.ml[i]` - Multi-pattern analysis worker
- [ ] `lib/analysis/analyze_cli.ml` - CLI interface with pattern filtering
- [ ] `bin/analyze.ml` - Executable entry point
- [ ] Progress reporting (X/Y games analyzed, ETA)
- [ ] Error handling for malformed FENs
- [ ] Performance: 100+ games/second on TWIC dataset

---

### Milestone 4: Complex Query Interface (Week 5)

**Goal:** Expose user-friendly query API for generalized pattern queries

#### Task 4.1: Query Builder Module
```ocaml
(* lib/queries/pattern_query.ml *)
open! Base

type opening_filter = {
  eco_codes : string list;
  eco_range : (string * string) option;
  opening_names : string list;
}

type rating_filter = {
  min_white_elo : int option;
  max_white_elo : int option;
  min_black_elo : int option;
  max_black_elo : int option;
  min_rating_difference : int option;
  max_rating_difference : int option;
}

type pattern_filter = {
  pattern_ids : string list;
  pattern_types : [ `Strategic | `Tactical | `Endgame | `Opening_trap ] list option;
  detected_by_color : Chess_engine.color option;
  success_required : bool;
  min_confidence : float option;
}

type query = {
  opening : opening_filter option;
  rating : rating_filter option;
  patterns : pattern_filter option;
  limit : int;
  offset : int;
}

val build_sql : query -> string * Caqti_type.t list
val execute :
  Database.Pool.t ->
  query ->
  (Database.game_overview list, Caqti_error.t) Result.t Lwt.t

(* Helper constructors *)
val kings_indian_defense : opening_filter
val rating_advantage : white_min:int -> difference:int -> rating_filter
val any_pattern : pattern_ids:string list -> success:bool -> pattern_filter
val pattern_by_type :
  pattern_type:[ `Strategic | `Tactical | `Endgame | `Opening_trap ] ->
  success:bool ->
  pattern_filter
```

#### Task 4.2: Predefined Query Templates
```ocaml
(* lib/queries/templates.ml *)

let queenside_attack_kid : Pattern_query.query =
  {
    opening = Some {
      eco_codes = [];
      eco_range = Some ("E60", "E99");
      opening_names = ["King's Indian"];
    };
    rating = Some {
      min_white_elo = Some 2500;
      max_white_elo = None;
      min_black_elo = None;
      max_black_elo = None;
      min_rating_difference = Some 100;
      max_rating_difference = None;
    };
    patterns = Some {
      pattern_ids = ["queenside_majority_attack"];
      pattern_types = None;
      detected_by_color = Some Chess_engine.White;
      success_required = true;
      min_confidence = Some 0.7;
    };
    limit = 5;
    offset = 0;
  }

let greek_gift_sicilian : Pattern_query.query = (* ... *)
let tactical_patterns_elite : Pattern_query.query = (* ... *)
let lucena_endgames : Pattern_query.query = (* ... *)
```

#### Task 4.3: CLI Query Command
```ocaml
(* lib/queries/query_cli.ml *)

let pattern_query_cmd =
  let doc = "Query games by patterns, openings, and ratings" in
  let patterns =
    let doc = "Pattern IDs (comma-separated)" in
    Arg.(value & opt (some string) None & info ["patterns"] ~doc)
  in
  let pattern_type =
    let doc = "Pattern type (strategic, tactical, endgame, opening_trap)" in
    Arg.(value & opt (some string) None & info ["pattern-type"] ~doc)
  in
  let color =
    let doc = "Pattern initiator color (white or black)" in
    Arg.(value & opt (some string) None & info ["color"] ~doc)
  in
  let min_confidence =
    let doc = "Minimum confidence score (0.0-1.0)" in
    Arg.(value & opt (some float) None & info ["min-confidence"] ~doc)
  in
  (* ... additional args ... *)
  Cmd.v (Cmd.info "query" ~doc) Term.(const run_query $ (* ... *))

(* bin/query.ml *)
let () = exit (Cmdliner.Cmd.eval Query_cli.pattern_query_cmd)
```

**Example Usage:**
```bash
# Queenside attack in King's Indian
dune exec bin/query.exe -- query \
  --opening "King's Indian" \
  --min-white-elo 2500 \
  --rating-difference 100 \
  --patterns queenside_majority_attack \
  --color white \
  --success-only \
  --limit 5

# Any tactical pattern by White, 2600+ ELO
dune exec bin/query.exe -- query \
  --min-white-elo 2600 \
  --rating-difference 150 \
  --pattern-type tactical \
  --color white \
  --success-only \
  --limit 10
```

**Deliverables:**
- [ ] `lib/queries/pattern_query.ml[i]` - Generalized query builder
- [ ] `lib/queries/templates.ml` - Predefined query examples (4+ patterns)
- [ ] `lib/queries/query_cli.ml` - CLI interface with pattern support
- [ ] `lib/chess/eco_matcher.ml[i]` - Fuzzy ECO matching (optional)
- [ ] `bin/query.ml` - Executable entry point
- [ ] Integration tests with TWIC data (multiple pattern types)
- [ ] Performance: <100ms for multi-pattern filtered queries

---

### Milestone 5: Validation & Testing (Week 6)

**Goal:** Verify accuracy and performance with real-world data

#### Task 5.1: Test Dataset Curation
```bash
# Download known games with verified patterns
mkdir -p data/validation/
curl -o data/validation/kid_queenside.pgn \
  "https://www.pgnmentor.com/files/KingsIndian.zip"
```

#### Task 5.2: Accuracy Testing
```ocaml
(* test/test_pattern_detectors.ml *)

let test_queenside_attack_kasparov_kramnik () =
  let pgn = (* Kasparov vs Kramnik 1994 *) in
  let%lwt analysis = Game_analyzer.analyze_game ~game_detail in
  match analysis with
  | Ok result ->
      let detected = List.exists result.detections ~f:(fun d ->
        d.pattern_id = "queenside_majority_attack" && d.success
      ) in
      Alcotest.(check bool) "detected queenside attack" true detected
  | Error msg -> Alcotest.fail msg

let test_greek_gift_detection () = (* ... *)
let test_lucena_position () = (* ... *)
```

#### Task 5.3: Performance Benchmarking
```ocaml
(* benchmark/pattern_analysis.ml *)

let benchmark_multi_pattern_detection () =
  let games = load_twic_games ~count:1000 in
  let start_time = Unix.gettimeofday () in
  let%lwt results = Lwt_list.map_p (fun game ->
    Game_analyzer.analyze_game_with_registry ~game_detail:game ()
  ) games in
  let end_time = Unix.gettimeofday () in
  let duration = end_time -. start_time in
  let games_per_sec = Float.of_int (List.length games) /. duration in
  Printf.printf "Analyzed %d games in %.2f seconds\n"
    (List.length games) duration;
  Printf.printf "Throughput: %.1f games/second\n" games_per_sec;
  Alcotest.(check bool) "meets performance target" true (games_per_sec > 100.0)
```

**Deliverables:**
- [ ] Test dataset with 25+ annotated games (all pattern types)
- [ ] Accuracy tests (precision/recall per pattern)
- [ ] Performance benchmarks
- [ ] False positive analysis
- [ ] Pattern detection algorithm documentation

---

### Milestone 6: Production Deployment (Week 7)

**Goal:** Deploy to production with monitoring and documentation

#### Task 6.1: Documentation
```markdown
<!-- docs/PATTERN_QUERIES.md -->
# Pattern Query Guide

## Supported Patterns

### Strategic Patterns
- Queenside Majority Attack
- Minority Attack

### Tactical Patterns
- Greek Gift Sacrifice (Bxh7+)

### Endgame Patterns
- Lucena Position
- Philidor Position

## Query Examples

See CLI examples in [Implementation Plan](IMPLEMENTATION_PLAN.md)

## Adding New Patterns

See [Adding New Patterns](#adding-new-patterns) section
```

#### Task 6.2: Migration & Backfill
```bash
# Step 1: Run schema migration
psql $DB_URI -f sql/migrations/001_pattern_framework.sql

# Step 2: Analyze existing games (batched)
for batch_id in $(psql $DB_URI -t -c "SELECT batch_id FROM ingestion_batches"); do
  dune exec bin/analyze.exe -- analyze \
    --db-uri $DB_URI \
    --batch-id $batch_id \
    --parallelism 8
done

# Step 3: Verify results
psql $DB_URI -c "
  SELECT pattern_id, COUNT(*) AS detections
  FROM pattern_detections
  WHERE success = true
  GROUP BY pattern_id
  ORDER BY COUNT(*) DESC;
"
```

#### Task 6.3: Monitoring & Metrics
```sql
-- Pattern detection statistics
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_pattern_statistics AS
SELECT
  pc.pattern_id,
  pc.pattern_name,
  pc.pattern_type,
  COUNT(*) AS total_detections,
  COUNT(*) FILTER (WHERE pd.success = true) AS successful_detections,
  AVG(pd.confidence) AS avg_confidence,
  COUNT(DISTINCT pd.game_id) AS games_with_pattern
FROM pattern_catalog pc
LEFT JOIN pattern_detections pd ON pc.pattern_id = pd.pattern_id
GROUP BY pc.pattern_id, pc.pattern_name, pc.pattern_type;

-- Performance monitoring
CREATE INDEX IF NOT EXISTS idx_pattern_detections_created
ON pattern_detections (created_at DESC);
```

**Deliverables:**
- [ ] `docs/PATTERN_QUERIES.md` - User guide
- [ ] Migration playbook
- [ ] Monitoring dashboard queries
- [ ] Performance SLOs documented
- [ ] Backfill script for existing data

---

## Pattern Detector Examples

### Example 1: Queenside Majority Attack (Strategic)

```ocaml
(* lib/patterns/strategic_patterns.ml *)
open! Base

module Queenside_attack : Pattern_detector.PATTERN_DETECTOR = struct
  let pattern_id = "queenside_majority_attack"
  let pattern_name = "Queenside Majority Attack"
  let pattern_type = `Strategic

  type attack_phase =
    | Setup | Advancing | Breakthrough | Success | Stalled

  let detect ~moves ~result =
    (* Analyze pawn structure at each position *)
    let%lwt pawn_analysis = Pawn_structure.analyze_queenside_majority moves in
    match pawn_analysis with
    | None -> Lwt.return {
        Pattern_detector.detected = false;
        confidence = 0.0;
        initiating_color = None;
        start_ply = None;
        end_ply = None;
        metadata = [];
      }
    | Some attack ->
        let confidence = calculate_confidence attack in
        Lwt.return {
          detected = true;
          confidence;
          initiating_color = Some attack.color;
          start_ply = Some attack.start_ply;
          end_ply = Some attack.end_ply;
          metadata = [
            ("passed_pawn_created", `Bool attack.passed_pawn);
            ("material_gained", `Int attack.material_gain);
            ("max_advancement", `Int attack.max_rank);
          ];
        }

  let classify_success ~detection ~result =
    match detection.initiating_color, result with
    | Some Chess_engine.White, "1-0" ->
        Lwt.return (true, Pattern_detector.Victory)
    | Some Chess_engine.Black, "0-1" ->
        Lwt.return (true, Pattern_detector.Victory)
    | Some color, "1/2-1/2" when detection.confidence > 0.7 ->
        (* Draw from advantage - partial success *)
        Lwt.return (true, Pattern_detector.DrawAdvantage)
    | _ ->
        Lwt.return (false, Pattern_detector.Defeat)
end
```

### Example 2: Greek Gift Sacrifice (Tactical)

```ocaml
(* lib/patterns/tactical_patterns.ml *)
open! Base

module Greek_gift : Pattern_detector.PATTERN_DETECTOR = struct
  let pattern_id = "greek_gift_sacrifice"
  let pattern_name = "Greek Gift Sacrifice"
  let pattern_type = `Tactical

  let detect ~moves ~result =
    (* Look for Bxh7+ or Bxh2+ in move sequence *)
    let sacrifice_moves = List.filter moves ~f:(fun move ->
      String.is_substring move.san ~substring:"Bxh7+" ||
      String.is_substring move.san ~substring:"Bxh2+"
    ) in

    match sacrifice_moves with
    | [] -> Lwt.return {
        Pattern_detector.detected = false;
        confidence = 0.0;
        initiating_color = None;
        start_ply = None;
        end_ply = None;
        metadata = [];
      }
    | sacrifice :: _ ->
        (* Verify follow-up attack (Ng5, Qh5, etc.) *)
        let%lwt attack_successful = verify_king_attack moves sacrifice in
        let confidence = if attack_successful then 0.9 else 0.6 in
        Lwt.return {
          detected = true;
          confidence;
          initiating_color = Some (if sacrifice.ply mod 2 = 1 then White else Black);
          start_ply = Some sacrifice.ply;
          end_ply = Some (sacrifice.ply + 10);
          metadata = [
            ("sacrifice_move", `String sacrifice.san);
            ("attack_sustained", `Bool attack_successful);
          ];
        }

  let classify_success ~detection ~result =
    match detection.initiating_color, result with
    | Some Chess_engine.White, "1-0" ->
        Lwt.return (true, Pattern_detector.Victory)
    | Some Chess_engine.Black, "0-1" ->
        Lwt.return (true, Pattern_detector.Victory)
    | _ ->
        Lwt.return (false, Pattern_detector.Defeat)
end
```

### Example 3: Lucena Position (Endgame)

```ocaml
(* lib/patterns/endgame_patterns.ml *)
open! Base

module Lucena : Pattern_detector.PATTERN_DETECTOR = struct
  let pattern_id = "lucena_position"
  let pattern_name = "Lucena Position"
  let pattern_type = `Endgame

  let detect ~moves ~result =
    (* Check for characteristic rook endgame structure *)
    let endgame_positions = List.drop_while moves ~f:(fun m ->
      not (is_rook_endgame m.fen_before)
    ) in

    match Endgame_recognizer.find_lucena endgame_positions with
    | None -> Lwt.return {
        Pattern_detector.detected = false;
        confidence = 0.0;
        initiating_color = None;
        start_ply = None;
        end_ply = None;
        metadata = [];
      }
    | Some lucena_pos ->
        Lwt.return {
          detected = true;
          confidence = 0.95;
          initiating_color = Some lucena_pos.winning_side;
          start_ply = Some lucena_pos.ply;
          end_ply = Some (lucena_pos.ply + 15);
          metadata = [
            ("pawn_file", `String (file_to_string lucena_pos.pawn_file));
            ("building_bridge", `Bool lucena_pos.bridge_technique_used);
          ];
        }

  let classify_success ~detection ~result =
    match detection.initiating_color, result with
    | Some Chess_engine.White, "1-0" ->
        Lwt.return (true, Pattern_detector.Victory)
    | Some Chess_engine.Black, "0-1" ->
        Lwt.return (true, Pattern_detector.Victory)
    | Some _, "1/2-1/2" ->
        Lwt.return (false, Pattern_detector.DrawNeutral)
    | _ ->
        Lwt.return (false, Pattern_detector.Defeat)
end

(* Pattern registration *)
let register_all_patterns () =
  Pattern_detector.Registry.register (module Lucena);
  Pattern_detector.Registry.register (module Philidor)
```

---

## Adding New Patterns

### Step-by-Step Guide

#### Step 1: Implement Detector Module

```ocaml
(* lib/patterns/endgame/rook_vs_pawn.ml *)

module Rook_vs_pawn : Pattern_detector.PATTERN_DETECTOR = struct
  let pattern_id = "rook_vs_pawn_endgame"
  let pattern_name = "Rook vs Pawn Endgame"
  let pattern_type = `Endgame

  let detect ~moves ~result =
    (* Look for endgame with rook vs pawn material *)
    let%lwt endgame_phase = find_endgame moves in
    match endgame_phase with
    | Some (ply, material) when is_rook_vs_pawn material ->
        Lwt.return {
          Pattern_detector.detected = true;
          confidence = 0.9;
          initiating_color = Some (side_with_rook material);
          start_ply = Some ply;
          end_ply = None;
          metadata = [("position_type", `String "rook_vs_pawn")];
        }
    | _ -> Lwt.return { detected = false; confidence = 0.0; (* ... *) }

  let classify_success ~detection ~result =
    match detection.initiating_color, result with
    | Some White, "1-0" -> Lwt.return (true, Victory)
    | Some Black, "0-1" -> Lwt.return (true, Victory)
    | _ -> Lwt.return (false, Defeat)
end
```

#### Step 2: Register Pattern

```ocaml
(* lib/patterns/patterns.ml - startup registration *)

let () =
  Strategic_patterns.register_all_patterns ();
  Tactical_patterns.register_all_patterns ();
  Endgame_patterns.register_all_patterns ();
  (* New pattern *)
  Pattern_detector.Registry.register (module Endgame_patterns.Rook_vs_pawn)
```

#### Step 3: Seed Database

```sql
INSERT INTO pattern_catalog (pattern_id, pattern_name, pattern_type, detector_module, description)
VALUES ('rook_vs_pawn_endgame', 'Rook vs Pawn Endgame', 'endgame',
        'Endgame_patterns.Rook_vs_pawn',
        'Rook versus lone pawn endgame technique');
```

#### Step 4: Use Immediately

```bash
# Analyze all games for new pattern
dune exec bin/analyze.exe -- analyze \
  --patterns "rook_vs_pawn_endgame"

# Query games with pattern
dune exec bin/query.exe -- query \
  --pattern "rook_vs_pawn_endgame" \
  --success-only \
  --limit 10
```

**No schema changes required!** ✅

---

## Migration Strategy

### Phase 1: Schema Migration (Zero-Downtime)

```sql
-- Step 1: Rename existing table
ALTER TABLE game_themes RENAME TO game_patterns_legacy;

-- Step 2: Create new schema
CREATE TABLE pattern_detections (...);
CREATE TABLE pattern_catalog (...);
CREATE TABLE pattern_validation (...);

-- Step 3: Migrate existing data
INSERT INTO pattern_detections (game_id, pattern_id, success, confidence, detected_by_color)
SELECT
  game_id,
  'queenside_majority_attack',
  queenside_majority_success,
  1.0,
  'white'  -- Assume white for legacy data
FROM game_patterns_legacy
WHERE queenside_majority_success = true;
```

### Phase 2: Code Migration

1. Implement `Pattern_detector` interface
2. Migrate `Strategic_patterns.Queenside_attack` to new interface
3. Register in `Pattern_detector.Registry`
4. Update query builders to use `pattern_detections` table

### Phase 3: Backfill Analysis

```bash
# Re-analyze all games with new framework
dune exec bin/analyze.exe -- analyze \
  --db-uri $DB_URI \
  --parallelism 16
```

### Phase 4: Drop Legacy

```sql
DROP TABLE game_patterns_legacy;
```

---

## Technical Reference

### ECO Code Mapping - King's Indian Defence

```ocaml
let kid_eco_codes = [
  "E60"; (* King's Indian Defense *)
  "E61"; (* King's Indian Defense, 3.Nc3 *)
  "E62"; (* King's Indian, Fianchetto Variation *)
  (* ... E63-E98 ... *)
  "E99"; (* King's Indian, Orthodox, Aronin-Taimanov, Main *)
]
```

### SQL Query Examples

```sql
-- Example 1: Queenside attack in King's Indian
SELECT
  g.game_id,
  p_white.full_name AS white_player,
  p_black.full_name AS black_player,
  g.white_elo,
  g.black_elo,
  g.eco_code,
  g.result,
  pd.confidence,
  pd.outcome
FROM games g
INNER JOIN players p_white ON g.white_id = p_white.player_id
INNER JOIN players p_black ON g.black_id = p_black.player_id
INNER JOIN pattern_detections pd ON g.game_id = pd.game_id
WHERE
  g.eco_code BETWEEN 'E60' AND 'E99'
  AND g.white_elo >= 2500
  AND (g.white_elo - g.black_elo) >= 100
  AND pd.pattern_id = 'queenside_majority_attack'
  AND pd.detected_by_color = 'white'
  AND pd.success = true
  AND pd.confidence >= 0.7
ORDER BY pd.confidence DESC, g.game_date DESC
LIMIT 5;

-- Example 2: Any tactical pattern by White, 2600+ ELO
SELECT
  g.game_id,
  pd.pattern_id,
  pc.pattern_name,
  pd.confidence
FROM games g
INNER JOIN pattern_detections pd ON g.game_id = pd.game_id
INNER JOIN pattern_catalog pc ON pd.pattern_id = pc.pattern_id
WHERE
  g.white_elo >= 2600
  AND (g.white_elo - g.black_elo) >= 150
  AND pc.pattern_type = 'tactical'
  AND pd.detected_by_color = 'white'
  AND pd.success = true
  AND pd.confidence >= 0.8
ORDER BY pd.confidence DESC
LIMIT 10;

-- Example 3: Games with multiple patterns
SELECT
  g.game_id,
  ARRAY_AGG(pd.pattern_id) AS patterns_detected,
  ARRAY_AGG(pd.confidence) AS confidences
FROM games g
INNER JOIN pattern_detections pd ON g.game_id = pd.game_id
WHERE
  pd.success = true
  AND pd.confidence >= 0.7
GROUP BY g.game_id
HAVING COUNT(DISTINCT pd.pattern_id) >= 2
LIMIT 5;

-- Example 4: Pattern frequency by opening
SELECT
  SUBSTRING(g.eco_code FROM 1 FOR 1) AS eco_category,
  pd.pattern_id,
  pc.pattern_name,
  COUNT(*) AS frequency,
  AVG(pd.confidence) AS avg_confidence,
  SUM(CASE WHEN pd.success THEN 1 ELSE 0 END)::float / COUNT(*) AS success_rate
FROM games g
INNER JOIN pattern_detections pd ON g.game_id = pd.game_id
INNER JOIN pattern_catalog pc ON pd.pattern_id = pc.pattern_id
WHERE g.eco_code IS NOT NULL
GROUP BY eco_category, pd.pattern_id, pc.pattern_name
ORDER BY frequency DESC
LIMIT 20;
```

---

## Success Criteria

### Functional Requirements ✅

- [ ] Query: "King's Indian + 2500 ELO + queenside attack" returns ≥5 games
- [ ] Query: "Sicilian + 2400 ELO + Greek Gift" returns ≥5 games
- [ ] Query: "Any tactical pattern by White, 2600+ ELO" returns ≥10 games
- [ ] Pattern detection accuracy: >90% precision, >85% recall
- [ ] False positive rate: <5% on validation dataset
- [ ] Supports ECO filtering (E60-E99 for KID)
- [ ] ELO filtering with min/max thresholds
- [ ] Rating difference filtering (White - Black)
- [ ] Confidence filtering (min threshold)
- [ ] Color filtering (white/black/either)

### Performance Requirements ⚡

- [ ] Pattern analysis: >100 games/second (all detectors)
- [ ] Pattern query execution: <100ms
- [ ] Batch backfill: 10K games in <15 minutes
- [ ] Memory usage: <2GB for analysis pipeline

### Quality Requirements 📊

- [ ] Test coverage: >85% for pattern detection code
- [ ] Documentation: Pattern query guide + API docs
- [ ] Monitoring: Dashboard for analysis lag and accuracy
- [ ] CI/CD: Automated tests for pattern detection

---

## Benefits of Generalization

### 1. Extensibility
- ✅ Add new patterns: implement module + register (no schema changes)
- ✅ Supports unlimited pattern types
- ✅ Pattern-specific metadata via JSONB

### 2. Flexibility
- ✅ Query by single pattern, multiple patterns, or pattern type
- ✅ Filter by color, confidence, success
- ✅ Combine with opening/rating filters

### 3. Maintainability
- ✅ Single codebase for all pattern detection
- ✅ Consistent interface across patterns
- ✅ Centralized registry and catalog

### 4. Performance
- ✅ Analyze all patterns in parallel per game
- ✅ Incremental analysis (only new games)
- ✅ Indexed queries for fast filtering

### 5. Observability
- ✅ Pattern validation workflow
- ✅ Confidence scoring for accuracy tracking
- ✅ Pattern-specific metadata for debugging

---

## References

### Chess Theory
- **Chess Strategy:** *My System* by Aron Nimzowitsch (pawn majority theory)
- **King's Indian Defense:** *The King's Indian* by Viktor Bologan
- **Pattern Recognition:** ChessBase pattern search algorithms

### Technical Documentation
- **ChessBuddy Architecture:** [docs/ARCHITECTURE.md](ARCHITECTURE.md)
- **Chess Engine Status:** [docs/CHESS_ENGINE_STATUS.md](CHESS_ENGINE_STATUS.md)
- **Chess Library Evaluation:** [docs/CHESS_LIBRARY_EVALUATION.md](CHESS_LIBRARY_EVALUATION.md)
- **AI Assistant Guide:** [docs/OCAML_AI_ASSISTANT_GUIDE.md](OCAML_AI_ASSISTANT_GUIDE.md)
- **Database Schema:** [sql/schema.sql](../sql/schema.sql)
- **Developer Guide:** [docs/DEVELOPER.md](DEVELOPER.md)

### External Resources
- **PostgreSQL Performance:** [PostgreSQL Query Performance Tuning](https://wiki.postgresql.org/wiki/Performance_Optimization)
- **pgvector Documentation:** [pgvector GitHub](https://github.com/pgvector/pgvector)
- **Caqti Documentation:** [ocaml-caqti](https://paurkedal.github.io/ocaml-caqti/)
- **OCaml Lwt Guide:** [Lwt Manual](https://ocsigen.org/lwt/latest/manual/manual)

---

## Changelog

### v3.0 (2025-10-04) - Merged Generalization Summary
**Merged `IMPLEMENTATION_PLAN.md` and `GENERALIZATION_SUMMARY.md` into single document**

**Structure improvements:**
- Added table of contents
- Architecture overview section with design principles
- Pattern detector examples section with 3 complete implementations
- "Adding New Patterns" step-by-step guide
- Migration strategy section
- Benefits of generalization section
- Clearer SQL query examples (4 comprehensive examples)

**Content consolidation:**
- Integrated generalization rationale throughout document
- Moved example detector implementations from summary to dedicated section
- Consolidated CLI usage examples
- Unified technical reference sections

### v2.2 (2025-10-04) - Generalized Pattern Detection Framework
**Major architectural shift:** Single-pattern → extensible multi-pattern system

**Database schema changes:**
- Replaced `game_themes` table with generalized `pattern_detections` table
- Added `pattern_catalog` table for pattern registry
- Single schema supports unlimited pattern types without schema changes
- Added `pattern_validation` table for accuracy monitoring

**Pattern detector framework:**
- Created `PATTERN_DETECTOR` module type interface
- Pattern registry for dynamic detector registration
- Support for strategic, tactical, endgame, and opening trap patterns
- Pluggable success classifiers per pattern
- Confidence scoring (0.0-1.0) with metadata

**Example implementations:**
- `Queenside_attack` (strategic pattern)
- `Greek_gift` (tactical pattern - Bxh7+ sacrifice)
- `Lucena` (endgame pattern - rook endgame technique)

**Query interface updates:**
- Renamed `strategic_query.ml` → `pattern_query.ml`
- Support filtering by `pattern_ids`, `pattern_types`, `detected_by_color`
- Added `min_confidence` threshold filtering
- CLI supports `--patterns`, `--pattern-type`, `--color` arguments

**Analysis pipeline:**
- Multi-pattern analysis worker runs all registered detectors
- Optional `pattern_types` filter for selective analysis
- Batch processing with parallelism support
- `--list-patterns` CLI flag to show all registered patterns

### v2.1 (2025-10-04) - Enhanced Suggestions
- Added `pattern_validation` table for accuracy monitoring
- Added confidence scoring (0.0-1.0)
- Added `success_outcome` type for draw handling
- Added `analyze_new_games_only` for incremental analysis
- Added `eco_range` support for simpler ECO filtering
- Optimized SQL query to use BETWEEN for ECO codes

### v2.0 (2025-10-04) - Initial Strategic Query Plan
- Complete 7-week implementation roadmap
- 6 milestones with detailed task breakdowns
- Pattern detection algorithm specifications
- Query builder and CLI interface design
- Validation strategy and success criteria

---

**Document Version:** 3.0
**Authors:** ChessBuddy Development Team
**Last Updated:** 2025-10-04
**Review Date:** 2025-10-04
