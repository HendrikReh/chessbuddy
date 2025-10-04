# OCaml Best Practices for AI Coding Assistants

**Purpose:** This guide instructs AI coding assistants on how to work with OCaml 5.1+ projects, synthesizing patterns from the ChessBuddy codebase and industry best practices.

**Target Audience:** AI assistants (Claude Code, GitHub Copilot, etc.) working on OCaml projects that use Jane Street Base, Lwt async, Caqti database integration, and modern tooling.

---

## Table of Contents

1. [Project Structure and Organization](#1-project-structure-and-organization)
2. [Choice of Frameworks, Libraries, and Tooling](#2-choice-of-frameworks-libraries-and-tooling)
3. [Coding Standards and Idiomatic Style](#3-coding-standards-and-idiomatic-style)
4. [Test Setup and Methodology](#4-test-setup-and-methodology)
5. [Documentation Layout and Style](#5-documentation-layout-and-style)
6. [Interface Design and Module Usage](#6-interface-design-and-module-usage)
7. [Build and Dependency Management](#7-build-and-dependency-management)
8. [Security Considerations and Safe Coding Practices](#8-security-considerations-and-safe-coding-practices)

---

## 1. Project Structure and Organization

### Standard Directory Layout

```
project/
├── lib/                       # Core library modules
│   ├── core/                  # Domain types and configuration (optional subdirs)
│   │   ├── types.ml[i]       # Central domain types (ALWAYS FIRST)
│   │   └── env_loader.ml[i]  # Environment configuration
│   ├── persistence/           # Database layer (optional subdirs)
│   │   └── database.ml[i]    # Caqti queries and pool management
│   ├── <feature>/             # Feature-specific modules (optional subdirs)
│   │   ├── <feature>.ml[i]   # Business logic
│   │   └── <feature>_cli.ml  # CLI command definitions (testable)
│   └── dune                   # Library build configuration
├── bin/                       # Executable entry points
│   ├── <app>.ml              # Thin wrapper (3-10 lines)
│   └── dune                   # Executable build config
├── test/                      # Test suite
│   ├── test_suite.ml         # Main Alcotest runner
│   ├── test_helpers.ml       # Shared test utilities
│   ├── test_<module>.ml      # Per-module test suites
│   └── dune                   # Test build config
├── docs/                      # Documentation
│   ├── ARCHITECTURE.md       # System design and decisions
│   ├── DEVELOPER.md          # Setup and development guide
│   ├── GUIDELINES.md         # Coding standards
│   └── OPERATIONS.md         # Deployment and monitoring (if applicable)
├── sql/                       # Database schema (if applicable)
│   └── schema.sql            # PostgreSQL DDL
├── data/                      # Sample data and fixtures (optional)
├── dune-project              # Project metadata
├── .ocamlformat              # Code formatter config
├── .gitignore                # Git ignore rules
├── CLAUDE.md                 # AI assistant instructions (RECOMMENDED)
└── README.md                 # User-facing documentation
```

### Key Organizational Principles

**1. Types-First Pattern**
- Create `lib/types.ml` (or `lib/core/types.ml`) as the **first module**
- Contains ALL domain types with **zero business logic**
- Only dependencies: standard types (Uuidm, Ptime)
- Prevents circular dependencies

```ocaml
(* lib/types.ml - ALWAYS FIRST MODULE *)
open! Base

module Rating = struct
  type t = {
    standard : int option; [@default None]
    rapid : int option; [@default None]
    blitz : int option; [@default None]
  }
  [@@deriving show, yojson]
end

module Player = struct
  type t = {
    player_id : Uuidm.t option; [@default None]
    full_name : string;
    fide_id : string option; [@default None]
    rating : Rating.t;
  }
  [@@deriving show, yojson]
end
```

**2. Subdirectory Organization (Dune 3.10+)**

Use `include_subdirs unqualified` for functional organization while maintaining flat namespace:

```lisp
(* lib/dune *)
(include_subdirs unqualified)

(library
 (name myproject)
 (public_name myproject.core)
 (modules (:standard \ Feature_cli))
 (libraries base lwt lwt.unix))
```

**Benefits:**
- Clean separation: `lib/core/`, `lib/persistence/`, `lib/search/`
- Modules remain accessible with original names (Types, Database, etc.)
- Single wrapped library under namespace
- No circular dependencies

**3. CLI Logic in Libraries**

CLI command definitions belong in `lib/<feature>_cli.ml` (testable), executables are thin wrappers:

```ocaml
(* lib/ingest_cli.ml - Testable CLI logic *)
open! Base

let run_ingest ~db_uri ~input =
  (* Business logic here *)
  Ok "result"

let ingest_cmd =
  let open Cmdliner in
  (* Define command using Cmdliner *)
  Cmd.v (Cmd.info "ingest") Term.(const run_ingest $ db_uri_arg $ input_arg)

(* bin/main.ml - Thin wrapper *)
open! Base

let () = exit (Cmdliner.Cmd.eval Ingest_cli.ingest_cmd)
```

**4. Dependency Ordering**

Files must be dependency-ordered (enforced by dune):

```
lib/
├── types.ml          # 1. No dependencies
├── database.ml       # 2. Depends on: types
├── embedder.ml       # 3. Depends on: types
├── pipeline.ml       # 4. Depends on: types, database, embedder
└── feature_cli.ml    # 5. Depends on: types, database, pipeline
```

---

## 2. Choice of Frameworks, Libraries, and Tooling

### Mandatory Stack

**OCaml Version:** ≥ 5.1 (modern features, effect handlers)

**Standard Library:** Jane Street Base (NOT Stdlib)
```ocaml
(* REQUIRED at top of EVERY .ml file *)
open! Base
```

**Build System:** Dune 3.10+
```bash
dune build          # Compile
dune fmt            # Format code
dune runtest        # Run tests
dune clean          # Clean artifacts
```

**Code Formatter:** OCamlformat ≥ 0.27.0
```
(* .ocamlformat *)
version=0.27.0
profile=default
```

### Recommended Libraries by Use Case

**Async Programming:**
- **Lwt** + **lwt_ppx** (cooperative concurrency)
- Define bind operators in every Lwt module:
  ```ocaml
  let ( let* ) = Lwt.bind    (* Sequential *)
  let ( let+ ) = Lwt.map     (* Map *)
  let ( and+ ) = Lwt.both    (* Parallel *)
  ```

**Database Integration:**
- **Caqti 2.x** (type-safe SQL queries)
- **Caqti_lwt** + **Caqti_lwt_unix** (async support)
- Define custom types for PostgreSQL:
  ```ocaml
  let uuid =
    let encode uuid = Ok (Uuidm.to_string uuid) in
    let decode str = match Uuidm.of_string str with
      | Some uuid -> Ok uuid
      | None -> Error ("Invalid UUID: " ^ str)
    in
    Caqti_type.(custom ~encode ~decode string)
  ```

**Testing:**
- **Alcotest** + **Alcotest-lwt** (lightweight, expressive)
- Mark test-only dependencies: `(alcotest :with-test)`

**CLI Applications:**
- **Cmdliner** (declarative argument parsing)
- Custom converters for type safety:
  ```ocaml
  let uri_conv : Uri.t Arg.conv =
    let parse s = try Ok (Uri.of_string s) with exn -> Error (`Msg "invalid URI") in
    let print fmt uri = Fmt.pp_print_string fmt (Uri.to_string uri) in
    Arg.conv ~docv:"URI" (parse, print)
  ```

**Serialization:**
- **ppx_yojson_conv** (JSON)
- **ppx_deriving.show** (debugging)
- Add to dune preprocess: `(pps lwt_ppx ppx_deriving.show ppx_yojson_conv)`

**Utility Libraries:**
- **Uuidm** (UUID generation and parsing)
- **Ptime** (date/time handling)
- **Uri** (URI parsing)

### When to Use Stdlib

Only use `Stdlib` when Base intentionally lacks functionality:
- File I/O: `Stdlib.open_in`, `Stdlib.close_out`
- Format printing: `Stdlib.Format` (alias as `Fmt`)
- System calls: `Stdlib.Sys.getenv_opt`
- **ALWAYS qualify:** `Stdlib.<module>`

```ocaml
open! Base
module Fmt = Stdlib.Format

let read_file path =
  let ic = Stdlib.open_in path in
  Exn.protect ~finally:(fun () -> Stdlib.close_in_noerr ic) ~f:(fun () ->
    let content = Stdlib.In_channel.input_all ic in
    String.split ~on:'\n' content  (* Base.String *)
  )
```

---

## 3. Coding Standards and Idiomatic Style

### Base Standard Library Discipline

**Rule #1: Every module starts with `open! Base`**

```ocaml
(* CORRECT *)
open! Base

let process_list items =
  List.map ~f:(fun x -> x + 1) items

(* INCORRECT - Do not omit open! Base *)
let process_list items =
  List.map (fun x -> x + 1) items  (* Missing ~f: label *)
```

### Labeled Arguments (MANDATORY)

Base enforces labeled arguments for clarity:

```ocaml
(* CORRECT - Use labels *)
List.map ~f:fn list
String.split ~on:',' str
Option.value ~default:0 opt
List.fold ~init:0 ~f:(+) list
Hashtbl.set table ~key:"foo" ~data:42

(* INCORRECT - Positional arguments *)
List.map fn list          (* Compile error with Base *)
String.split ',' str      (* Wrong API *)
```

### Naming Conventions

**Modules:** `CamelCase`
```ocaml
module Database = struct ... end
module SearchService = struct ... end
```

**Functions/Values:** `snake_case`
```ocaml
let upsert_player pool ~full_name = ...
let create_embedding ~fen = ...
```

**Record Fields:** `snake_case`
```ocaml
type player = {
  player_id : Uuidm.t;
  full_name : string;
  fide_id : string option;
}
```

**Constructors:** `Capitalized`
```ocaml
type color = White | Black
type square = Empty | Piece of piece
```

**Type Parameters:** `'a`, `'b`, `'key`, `'value`
```ocaml
type 'a option = None | Some of 'a
val map : 'a list -> f:('a -> 'b) -> 'b list
```

### Formatting and Style

**Indentation:** 2 spaces (ocamlformat default)

**Line Length:** ~90 characters (soft limit)

**Comments:**
```ocaml
(** Public API documentation (OCamldoc format) *)
let public_function x = x

(* Internal implementation notes *)
let helper x =
  (* Inline explanation for complex logic *)
  x + 1
```

**Pattern Matching:**
```ocaml
(* Prefer exhaustive matches *)
let process_option opt =
  match opt with
  | None -> "empty"
  | Some value -> "present: " ^ value

(* Use when for guards *)
let categorize_age age =
  match age with
  | n when n < 18 -> "minor"
  | n when n < 65 -> "adult"
  | _ -> "senior"
```

**Error Handling:**
```ocaml
(* Use Result.t for recoverable errors *)
type error =
  | Invalid_input of string
  | Database_error of string
  | Not_found

let validate_age age =
  if age < 0 then Error (Invalid_input "age cannot be negative")
  else if age > 150 then Error (Invalid_input "age exceeds maximum")
  else Ok age

(* Use exceptions for programming errors *)
let get_item arr index =
  if index < 0 || index >= Array.length arr then
    failwith "index out of bounds"
  else arr.(index)
```

### Lwt Async Patterns

**Define bind operators in every Lwt module:**
```ocaml
let ( let* ) = Lwt.bind    (* Sequential: let* x = ... in *)
let ( let+ ) = Lwt.map     (* Map: let+ x = ... in *)
let ( and+ ) = Lwt.both    (* Parallel: let+ x = ... and+ y = ... in *)
```

**Sequential operations:**
```ocaml
let process_game pool game =
  let* player_id = upsert_player pool ~name:game.white in
  let* game_id = record_game pool ~player_id ~game in
  let* () = process_moves pool game_id game.moves in
  Lwt.return game_id
```

**Parallel operations:**
```ocaml
let fetch_both pool id1 id2 =
  let+ result1 = fetch_data pool id1
  and+ result2 = fetch_data pool id2 in
  (result1, result2)
```

**Sequential iteration:**
```ocaml
(* Use Lwt_list.iter_s for order-dependent iteration *)
let process_moves pool game_id moves =
  Lwt_list.iter_s (fun move ->
    let* () = record_move pool game_id move in
    Lwt.return_unit
  ) moves

(* Use Lwt_list.iter_p for independent parallel iteration *)
let fetch_all_players pool ids =
  Lwt_list.map_p (fun id -> fetch_player pool id) ids
```

### Derivers and PPX

**Recommended derivers:**
```ocaml
type player = {
  full_name : string;
  fide_id : string option; [@default None]
}
[@@deriving show, yojson, eq, compare]
```

- `show` - Pretty-printing for debugging
- `yojson` - JSON serialization/deserialization
- `eq` - Structural equality
- `compare` - Ordering (for Map/Set)

**Use `[@default ...]` for optional fields:**
```ocaml
type config = {
  max_size : int; [@default 10]
  timeout_ms : int; [@default 5000]
}
[@@deriving yojson]
```

---

## 4. Test Setup and Methodology

### Test Infrastructure

**Main Test Runner (test/test_suite.ml):**
```ocaml
open! Base

let () =
  Lwt_main.run @@
  Alcotest_lwt.run "Project Test Suite" [
    ("Database Operations", Test_database.tests);
    ("Business Logic", Test_feature.tests);
    ("CLI Arguments", Test_feature_cli.tests);
  ]
```

**Shared Test Helpers (test/test_helpers.ml):**
```ocaml
open! Base
module Fmt = Stdlib.Format

let ( let* ) = Lwt.bind

(** Environment-based configuration *)
let test_db_uri =
  Stdlib.Sys.getenv_opt "PROJECT_TEST_DB_URI"
  |> Option.value ~default:"postgresql://test:test@localhost:5432/testdb"

let require_db_tests =
  match Stdlib.Sys.getenv_opt "PROJECT_REQUIRE_DB_TESTS" with
  | Some v -> String.lowercase v = "1" || String.lowercase v = "true"
  | None -> false

(** Graceful test skipping *)
exception Skip_db_tests of string

let raise_or_skip err =
  let msg = Fmt.asprintf "%a" Caqti_error.pp err in
  if require_db_tests then
    Alcotest.failf "Database error: %s" msg
  else (
    Fmt.printf "⚠️  Skipping database tests: %s@." msg;
    raise (Skip_db_tests msg))

(** Database cleanup for test isolation *)
let cleanup_test_data pool =
  (* DELETE FROM tables in dependency order *)
  Lwt.return_unit

(** Test fixtures *)
let sample_player = Types.Player.{
  player_id = None;
  full_name = "Magnus Carlsen";
  fide_id = Some "1503014";
}
```

### Test Module Structure

**Per-Module Tests (test/test_<module>.ml):**
```ocaml
open! Base

let ( let* ) = Lwt.bind

let test_feature_behavior () =
  let* result = Feature.process ~input:"test" in
  match result with
  | Ok output ->
      Alcotest.(check string) "output matches" "expected" output;
      Lwt.return_unit
  | Error msg ->
      Alcotest.fail msg

let test_database_integration () =
  try
    let pool = Test_helpers.create_test_pool () in
    let* () = Feature.store pool "data" in
    (* Assertions using Alcotest.check *)
    Alcotest.(check bool) "data stored" true true;
    Test_helpers.cleanup_test_data pool
  with Test_helpers.Skip_db_tests msg ->
    Stdlib.Printf.printf "Skipped: %s\n" msg;
    Lwt.return_unit

let tests = [
  Alcotest_lwt.test_case "feature behavior" `Quick test_feature_behavior;
  Alcotest_lwt.test_case "database integration" `Quick test_database_integration;
]
```

### Environment-Based Test Configuration

**Behavior:**
- Default: Tests run if database available, skip gracefully if not
- `PROJECT_REQUIRE_DB_TESTS=1`: Tests MUST run, fail if database unavailable
- `PROJECT_TEST_DB_URI`: Override default database connection

**Usage:**
```bash
# Run tests (skip if DB unavailable)
dune runtest

# Require database tests (fail if unavailable)
PROJECT_REQUIRE_DB_TESTS=1 dune runtest

# Use custom database
PROJECT_TEST_DB_URI=postgresql://localhost/mydb dune runtest
```

**CI Configuration:**
```yaml
# .github/workflows/ci.yml
- name: Run tests
  env:
    PROJECT_REQUIRE_DB_TESTS: "1"  # Fail if DB unavailable in CI
  run: dune runtest
```

### Test Isolation

**Pattern: Clean database state per test**
```ocaml
let with_clean_db f =
  try
    let pool = create_test_pool () in
    (* Apply schema *)
    let schema_sql = Stdlib.In_channel.read_all "sql/schema.sql" in
    let%lwt () = exec_sql pool schema_sql in
    (* Run test *)
    let%lwt result = f pool in
    (* Cleanup *)
    let%lwt () = cleanup_test_data pool in
    Lwt.return result
  with Skip_db_tests msg ->
    Stdlib.Printf.printf "Skipped: %s\n" msg;
    Lwt.return_unit
```

### Alcotest Best Practices

**Define custom testable types:**
```ocaml
let uuid_testable : Uuidm.t Alcotest.testable =
  Alcotest.testable Uuidm.pp Uuidm.equal

let player_testable : Types.Player.t Alcotest.testable =
  Alcotest.testable Types.Player.pp Types.Player.equal
```

**Use typed check functions:**
```ocaml
Alcotest.(check uuid_testable) "same player ID" expected actual
Alcotest.(check (option string)) "fide_id present" (Some "1503014") player.fide_id
Alcotest.(check bool) "is_empty" true (List.is_empty results)
Alcotest.(check int) "count" 42 (List.length items)
```

**Mark test speed:**
```ocaml
let tests = [
  Alcotest_lwt.test_case "fast unit test" `Quick test_fast;
  Alcotest_lwt.test_case "slow integration test" `Slow test_slow;
]
```

---

## 5. Documentation Layout and Style

### Essential Documentation Files

**README.md** (User-facing)
- Project overview (1-2 paragraphs)
- Quick start (installation, basic usage)
- Key features
- Testing instructions
- Deployment guide (if applicable)

**docs/ARCHITECTURE.md** (Developer deep-dive)
- System overview diagram
- Component responsibilities
- Data flow diagrams
- Key design decisions with rationale
- Performance characteristics
- Trade-offs and alternatives considered

**docs/DEVELOPER.md** (Setup and workflow)
- Environment setup (OCaml, opam, dependencies)
- Build commands
- Running tests
- Database setup (if applicable)
- Debugging tips
- Common development tasks

**docs/GUIDELINES.md** (Coding standards)
- Style rules
- Naming conventions
- Commit message format
- Code review checklist
- Module organization guidelines

**docs/OPERATIONS.md** (Operational runbooks)
- Deployment procedures (manual steps, CI/CD workflows)
- Environment matrix (dev/stage/prod) with required secrets and feature toggles
- Monitoring/alerting references and escalation paths
- Backup/restore playbooks and data retention policies
- Incident response templates and postmortem checklist

**CLAUDE.md** (AI Assistant Instructions) - RECOMMENDED
```markdown
# CLAUDE.md

## Project Overview
Brief description, tech stack, purpose

## Essential Commands
```bash
dune build          # Compile
dune runtest        # Test
dune fmt            # Format
```

## Critical Code Conventions
- Every module: `open! Base`
- All public modules: `.mli` files
- Database queries: top-level values
- Tests: Alcotest-lwt with env config

## Database Details
Connection: postgresql://...
Key tables: players, games, positions

## Testing Strategy
PostgreSQL via Docker, graceful skip on unavailable

## Current Limitations
- Feature X: placeholder implementation
- Module Y: pending integration
```

### OCamldoc Interface Documentation

**Structure Template (.mli files):**
```ocaml
(** Module one-line synopsis

    Extended description explaining purpose, design decisions, and usage patterns.

    Example:
    {[
      let pool = Database.create_pool "postgresql://..." in
      let%lwt player_id = Database.upsert_player pool
        ~full_name:"Carlsen" ~fide_id:(Some "1503014") in
      (* ... *)
    ]}

    Performance:
    - Query execution: <10ms typical, <50ms p99
    - Connection pool: 10 max, 1 min idle

    @see <https://github.com/paurkedal/ocaml-caqti> Caqti documentation
*)

(** {1 Type Definitions} *)

type t
(** Opaque connection pool handle

    Created via {!create_pool}. Thread-safe, manages PostgreSQL connections. *)

type config = {
  max_size : int;
  timeout_ms : int;
}
(** Configuration record for connection pool

    @param max_size Maximum concurrent connections
    @param timeout_ms Connection acquisition timeout *)

(** {1 Core Functions} *)

val create_pool : string -> t
(** Create connection pool from URI

    @param uri PostgreSQL connection string (e.g., "postgresql://user:pass@host/db")
    @raise Failure if URI is malformed or connection fails

    Pool configuration:
    - Max size: 10 connections
    - Min idle: 1 connection
    - Acquire timeout: 30 seconds *)

val upsert_player :
  t ->
  full_name:string ->
  fide_id:string option ->
  (Uuidm.t, Caqti_error.t) Result.t Lwt.t
(** Insert or update player by FIDE ID

    @param pool Connection pool
    @param full_name Player full name
    @param fide_id Optional FIDE ID (unique constraint)
    @return Player UUID or database error

    Behavior:
    - If FIDE ID exists: updates name, returns existing UUID
    - If FIDE ID is None: inserts new player, returns new UUID
    - Concurrent safety: ON CONFLICT DO UPDATE ensures idempotency *)

(** {1 Module Signatures} *)

module type PROVIDER = sig
  val version : string
  val compute : input:string -> float array Lwt.t
end
(** Extension interface for pluggable providers *)
```

**Documentation Guidelines:**
1. Structured sections: `{1 ...}`, `{2 ...}`, `{3 ...}` for hierarchy
2. Code examples: `{[ code here ]}` for executable snippets
3. Parameter docs: `@param name Description` for every argument
4. Return docs: `@return Description` for complex return types
5. Exception docs: `@raise Exception when` for all failure modes
6. Performance notes: Typical latency, memory usage, concurrency behavior
7. External links: `@see <url> Description` for specs, RFCs, dependencies

---

## 6. Interface Design and Module Usage

### Rule: All Public Modules Must Have .mli Files

**Benefits:**
- API documentation via OCamldoc
- Encapsulation (hide implementation details)
- Compile-time contract enforcement
- Better error messages on signature violations

**Example:**
```ocaml
(* database.mli - Public interface *)
type t
val create_pool : string -> t
val upsert_player : t -> full_name:string -> fide_id:string option -> (Uuidm.t, Caqti_error.t) Result.t Lwt.t

(* database.ml - Implementation can have private helpers *)
type t = (module Caqti_lwt.CONNECTION) Caqti_lwt.Pool.t

let create_pool uri = (* ... *)
let upsert_player pool ~full_name ~fide_id = (* ... *)

(* Private helper not in .mli *)
let internal_helper x = x + 1
```

### Module Signatures for Extensibility

**Pattern: Define module types for swappable implementations**

```ocaml
(** Interface for embedding providers *)
module type EMBEDDER = sig
  val version : string
  (** Embedding model version identifier *)

  val embed : fen:string -> float array Lwt.t
  (** Generate 768-dimensional embedding from FEN position *)
end

(** Constant embedder for testing *)
module Constant : EMBEDDER = struct
  let version = "test-v1"
  let embed ~fen:_ = Lwt.return (Array.create ~len:768 0.0)
end

(** Neural network embedder (production) *)
module Neural : EMBEDDER = struct
  let version = "neural-v1"
  let embed ~fen = (* actual API call *)
end
```

**Benefits:**
- Test with stub implementations (Constant returns zeros)
- Swap implementations without changing call sites
- Clear contracts via explicit signatures

### Functor-Based Composition

**When to use functors: Cross-cutting concerns (caching, logging, etc.)**

```ocaml
(* Problem: Want caching layer over any embedder *)
module Cached (E : EMBEDDER) : EMBEDDER = struct
  let version = "cached-" ^ E.version

  let cache = Hashtbl.create (module String)

  let embed ~fen =
    match Hashtbl.find cache fen with
    | Some result -> Lwt.return result
    | None ->
        let%lwt result = E.embed ~fen in
        Hashtbl.set cache ~key:fen ~data:result;
        Lwt.return result
end

(* Usage: Compose at module level *)
module CachedNeural = Cached(Neural)
```

### Newtype Pattern (Type Safety)

**Problem: Prevent mixing up similar primitive types**

```ocaml
(* BAD - String/UUID soup *)
let record_game ~white_id ~black_id ~game_id = (* ... *)
(* Easy to mix: record_game ~white_id:game_id ~black_id:white_id *)

(* GOOD - Newtypes with phantom types *)
module Player_id : sig
  type t = private Uuidm.t
  val of_uuid : Uuidm.t -> t
  val to_uuid : t -> Uuidm.t
end = struct
  type t = Uuidm.t
  let of_uuid x = x
  let to_uuid x = x
end

module Game_id : sig
  type t = private Uuidm.t
  val of_uuid : Uuidm.t -> t
  val to_uuid : t -> Uuidm.t
end = struct
  type t = Uuidm.t
  let of_uuid x = x
  let to_uuid x = x
end

(* Now type-safe *)
let record_game ~white_id:(_ : Player_id.t) ~game_id:(_ : Game_id.t) = (* ... *)
(* record_game ~white_id:game_id  (* Compile error! *) *)
```

---

## 7. Build and Dependency Management

### Dune & Opam Workflow

```
(lang dune 3.10)
(version 0.0.1)
(name myproject)
(generate_opam_files true)

(package
 (name myproject)
 (synopsis "Short one-line description")
 (description "Detailed multi-line description if needed")
 (depends
  (ocaml (>= 5.1))
  dune
  base
  stdio
  lwt
  lwt_ppx
  (alcotest :with-test)
  (alcotest-lwt :with-test)
  (ocamlformat (>= 0.27.0))))
```

**Best Practices:**
- Pin OCaml version ≥ 5.1 for modern features
- Use `generate_opam_files true` - maintain dune-project, not .opam files
- Mark test-only dependencies with `:with-test`
- Include ocamlformat version for team consistency

### Library Configuration (lib/dune)

**Single Library with Subdirectories:**
```lisp
(include_subdirs unqualified)

(library
 (name myproject)
 (public_name myproject.core)
 (modules (:standard \ Feature_cli))  ; Exclude CLI modules
 (preprocess
  (pps lwt_ppx ppx_deriving.show ppx_yojson_conv))
 (libraries
  base
  lwt
  lwt.unix
  caqti
  caqti-lwt
  caqti-lwt.unix
  uuidm
  ptime))
```

**Separate CLI Library (for testability):**
```lisp
(library
 (name myproject_feature_cli)
 (public_name myproject.feature_cli)
 (wrapped false)              ; Allow Test_feature_cli to import
 (modules feature_cli)
 (libraries base myproject.core cmdliner))
```

### Executable Configuration (bin/dune)

```lisp
(executable
 (name main)
 (public_name myproject)
 (modules main)
 (libraries myproject.core myproject.feature_cli stdio))
```

**Pattern: Thin executable that delegates to library**
```ocaml
(* bin/main.ml *)
open! Base
let () = exit (Cmdliner.Cmd.eval Feature_cli.main_cmd)
```

### Test Configuration (test/dune)

```lisp
(test
 (name test_suite)
 (modules test_suite test_helpers test_database test_feature)
 (libraries
  myproject.core
  myproject.feature_cli  ; CLI testing
  alcotest
  alcotest-lwt
  lwt
  lwt.unix)
 (preprocess (pps lwt_ppx)))
```

### Dependency Management Workflow

```bash
# Initialize opam switch for project
opam switch create . 5.1.0
eval $(opam env)

# Install dependencies from dune-project
opam install . --deps-only --with-test

# Add new dependency (edit dune-project, then regenerate .opam)
dune build
opam install <new-dep>

# Update dependencies
opam update
opam upgrade
```

### .gitignore

```
_build/
*.install
*.merlin
.env
*.secret
credentials.json
.ocamlformat-ignore
```

---

## 8. Security Considerations and Safe Coding Practices

### Environment Configuration Pattern

**Principle: Separate public config from secrets**

```ocaml
(* lib/env_loader.ml - .env file parser *)
open! Base

(** Read key=value pairs from .env file *)
let read_env_file path =
  if Stdlib.Sys.file_exists path then
    let ic = Stdlib.open_in path in
    Exn.protect ~finally:(fun () -> Stdlib.close_in_noerr ic) ~f:(fun () ->
      let rec collect acc =
        match Stdlib.input_line ic with
        | line when String.is_prefix (String.strip line) ~prefix:"#" ->
            collect acc  (* Skip comments *)
        | line -> (
            match String.lsplit2 line ~on:'=' with
            | Some (key, value) ->
                collect ((String.strip key, String.strip value) :: acc)
            | None -> collect acc)
        | exception End_of_file -> List.rev acc
      in
      collect []
    )
  else []

(** Lookup: env var first, .env file second *)
let lookup ?(path = ".env") key =
  match Stdlib.Sys.getenv_opt key with
  | Some value -> Some value  (* Environment takes precedence *)
  | None ->
      read_env_file path
      |> List.find_map ~f:(fun (k, v) ->
           if String.equal k key then Some v else None)
```

**Usage:**
```ocaml
(* lib/openai_client.ml *)
let get_api_key () =
  match Env_loader.lookup "OPENAI_API_KEY" with
  | Some key -> Ok key
  | None -> Error "OPENAI_API_KEY not set (check .env or environment)"
```

**Security Rules:**
1. **Never commit secrets** - Use `.env` files (gitignored)
2. **Environment over files** - Production uses env vars, dev uses `.env`
3. **Fail-safe defaults** - Missing secret = error, not empty string
4. **Document requirements** - README lists all required env vars

**.gitignore:**
```
.env
*.secret
credentials.json
```

### SQL Injection Prevention

**Rule: NEVER string interpolate into SQL**

```ocaml
(* BAD - SQL injection vulnerability *)
let find_player pool ~name =
  let sql = "SELECT * FROM players WHERE full_name = '" ^ name ^ "'" in
  exec_query pool sql

(* GOOD - Parameterized query *)
let find_player_query =
  (Caqti_type.string ->? Caqti_type.(t2 uuid string))
  @:- {sql|SELECT player_id, full_name FROM players WHERE full_name = $1|sql}

let find_player pool ~name =
  Database.Pool.use pool (fun (module Db) ->
    Db.find_opt find_player_query name
  )
```

**Caqti enforces this:** No string concatenation possible with typed queries.

### Resource Cleanup Pattern

**Problem: Ensure cleanup even on exception**

```ocaml
(* BAD - Leaks on exception *)
let process_file path =
  let ic = Stdlib.open_in path in
  let result = parse_content (Stdlib.In_channel.input_all ic) in
  Stdlib.close_in ic;  (* Never reached if parse_content raises *)
  result

(* GOOD - Using Base.Exn.protect *)
let process_file path =
  let ic = Stdlib.open_in path in
  Exn.protect
    ~finally:(fun () -> Stdlib.close_in_noerr ic)
    ~f:(fun () ->
      let content = Stdlib.In_channel.input_all ic in
      parse_content content
    )

(* GOOD - Using Lwt.finalize for async *)
let process_file_async path =
  let%lwt ic = Lwt_io.open_file ~mode:Input path in
  Lwt.finalize
    (fun () ->
      let%lwt content = Lwt_io.read ic in
      parse_content_async content)
    (fun () -> Lwt_io.close ic)
```

### Database Best Practices

**Upsert-First Philosophy:**
Prefer `INSERT ... ON CONFLICT` over `SELECT` then `INSERT`

```ocaml
(* BAD - Race condition *)
let ensure_player pool ~name ~fide_id =
  let%lwt existing = select_player pool ~fide_id in
  match existing with
  | Some id -> Lwt.return id
  | None -> insert_player pool ~name ~fide_id

(* GOOD - Atomic upsert *)
let upsert_player_query =
  (Caqti_type.(t2 string (option string)) ->! uuid)
  @:- {sql|
    INSERT INTO players (full_name, fide_id)
    VALUES ($1, $2)
    ON CONFLICT (fide_id)
    DO UPDATE SET full_name = EXCLUDED.full_name
    RETURNING player_id
  |sql}
```

**Custom Caqti Types (Centralized):**
```ocaml
(* lib/database.ml - Custom types section at top *)

(** UUID codec for PostgreSQL UUID type *)
let uuid =
  let encode uuid = Ok (Uuidm.to_string uuid) in
  let decode str = match Uuidm.of_string str with
    | Some uuid -> Ok uuid
    | None -> Error ("Invalid UUID: " ^ str)
  in
  Caqti_type.(custom ~encode ~decode string)

(** Vector codec for pgvector VECTOR(N) type *)
let float_array =
  let encode arr = Ok (Array.to_list arr) in
  let decode lst = Ok (Array.of_list lst) in
  Caqti_type.(custom ~encode ~decode (list float))
```

### Connection Pool Management

```ocaml
(** Create connection pool with safe defaults *)
let create_pool uri_string =
  let uri = Uri.of_string uri_string in
  let config = Caqti_pool_config.create
    ~max_size:10        (* Maximum connections *)
    ~max_idle_size:2    (* Keep warm *)
    ~max_use_count:None (* No rotation *)
    ()
  in
  match Caqti_lwt_unix.connect_pool ~pool_config:config uri with
  | Ok pool -> pool
  | Error err -> failwith (Caqti_error.show err)
```

**Pool sizing rules:**
- **Development:** 5-10 connections
- **Production:** 2x core count, max 50
- **Testing:** 5 (matches most CI runners)

### Input Validation

**Validate early, fail fast:**
```ocaml
type error =
  | Invalid_input of string
  | Database_error of string
  | Not_found

let validate_elo elo =
  if elo < 0 then Error (Invalid_input "ELO cannot be negative")
  else if elo > 3500 then Error (Invalid_input "ELO exceeds maximum")
  else Ok elo

let validate_fide_id fide_id =
  if String.length fide_id <> 7 then
    Error (Invalid_input "FIDE ID must be 7 digits")
  else if not (String.for_all fide_id ~f:Char.is_digit) then
    Error (Invalid_input "FIDE ID must contain only digits")
  else
    Ok fide_id
```

---

## Summary: Essential Checklist for AI Assistants

When working on an OCaml 5.1+ project:

### Project Setup
- [ ] `dune-project` with OCaml >= 5.1, Base, Lwt, Alcotest-lwt
- [ ] `.ocamlformat` with `version=0.27.0`
- [ ] Directory structure: `lib/`, `bin/`, `test/`, `docs/`, `sql/` (if applicable)
- [ ] `.gitignore` with `.env`, `_build/`, `*.install`

### Code Standards
- [ ] Every `.ml` file starts with `open! Base`
- [ ] Every public module has `.mli` interface file
- [ ] Use labeled arguments (`~f:`, `~init:`, `~key:`, `~data:`)
- [ ] CLI logic in `lib/<feature>_cli.ml` (testable)
- [ ] Executables are thin wrappers (3-10 lines)

### Database (if applicable)
- [ ] Custom Caqti types centralized in `database.ml`
- [ ] Queries defined as top-level values
- [ ] Connection pool configured and documented
- [ ] `ON CONFLICT` for upserts (atomicity)
- [ ] Parameterized queries (never string interpolation)

### Testing
- [ ] Alcotest-lwt test suite
- [ ] Environment-based config (`PROJECT_TEST_DB_URI`, `PROJECT_REQUIRE_DB_TESTS`)
- [ ] Test isolation via cleanup helpers
- [ ] Graceful skip when dependencies unavailable

### Documentation
- [ ] `README.md` with quick start
- [ ] `docs/ARCHITECTURE.md` with design decisions
- [ ] `docs/DEVELOPER.md` with setup instructions
- [ ] `docs/GUIDELINES.md` capturing coding standards & review checklist
- [ ] `docs/OPERATIONS.md` documenting deploy/runbooks, monitoring, incident response
- [ ] `CLAUDE.md` for AI assistant guidance (RECOMMENDED)
- [ ] `.mli` files with OCamldoc comments

### Before Every Commit
- [ ] `dune fmt` (autoformat)
- [ ] `dune build` (verify buildability)
- [ ] `dune runtest` (run tests)
- [ ] Review `git diff` for accidental changes

### Release & PR Hygiene

**Commit messages**
- Prefer imperative, component-scoped subjects: `database: tighten batch dedupe`, `ingest_cli: add --skip-fens flag`
- Keep them short (≤50 chars when possible); add body text for context, rationale, and `Fixes #123` references
- Group logical changes atomically to ease review and `git bisect`

**Pull request checklist**
- Summarise scope and highlight schema/data impacts (e.g., new tables, migration needs)
- List verification steps you actually ran: `dune build`, `dune runtest`, manual CLI commands, benchmarks
- Mention docs updated (`README`, `ARCHITECTURE`, release notes) so reviewers can spot mismatches
- Call out new environment variables or secrets
- Link to issue/ticket when applicable

### Performance & Deduplication Practices

- **Compute checksums early**: hash PGN files or other bulk inputs to skip reruns when content is unchanged
- **Deduplicate expensive artifacts**: check for existing FEN rows/embeddings before regenerating; track embedding versions so upgrades are deliberate
- **Persist benchmark baselines**: record throughput/latency metrics in docs (`README`, `RELEASE_NOTES`) to detect regressions
- **Shallow copy state**: ensure pure helpers aren’t mutating shared structures (critical for board state / caches)
- **Short-circuit where possible**: bail out on work when data already matches target state (e.g., embedding version unchanged)
- **Regenerate pattern detections deliberately**: run migrations/backfills when detector logic changes; avoid duplicating rows thanks to `UNIQUE(game_id, pattern_id, detected_by_color)`

### Environment Prerequisites

- Document OS package requirements up front (especially for macOS)
  ```bash
  # macOS (Homebrew)
  brew install gmp libpq pkg-config
  export PKG_CONFIG_PATH="/opt/homebrew/opt/libpq/lib/pkgconfig:$PKG_CONFIG_PATH"
  export LDFLAGS="-L/opt/homebrew/opt/libpq/lib"
  export CPPFLAGS="-I/opt/homebrew/opt/libpq/include"
  ```
- Verify `pkg-config --exists libpq` and other libs during setup; mention these steps in `docs/DEVELOPER.md`
- Include `.env.example` or docs listing required environment variables; keep actual secrets out of VCS
- Recommend standard tooling: `opam`, `dune`, `ocamlformat`, `merlin`, `ocaml-lsp`, Docker (for PostgreSQL)

---

## References and Resources

**Core Libraries:**
- [Jane Street Base](https://opensource.janestreet.com/base/) - Standard library replacement
- [Lwt](https://ocsigen.org/lwt/) - Cooperative concurrency
- [Caqti](https://paurkedal.github.io/ocaml-caqti/) - Type-safe database queries
- [Cmdliner](https://erratique.ch/software/cmdliner) - Declarative CLI parsing
- [Alcotest](https://github.com/mirage/alcotest) - Lightweight testing framework

**Tools:**
- [Dune](https://dune.readthedocs.io/) - Build system
- [OCamlformat](https://github.com/ocaml-ppx/ocamlformat) - Code formatter
- [Merlin](https://github.com/ocaml/merlin) - Editor support
- [OCaml-LSP](https://github.com/ocaml/ocaml-lsp) - Language server

**Learning Resources:**
- [Real World OCaml](https://dev.realworldocaml.org/) - Comprehensive guide
- [OCaml.org](https://ocaml.org/docs) - Official documentation
- [Jane Street Tech Blog](https://blog.janestreet.com/) - Advanced patterns

---

**Generated from ChessBuddy v0.0.8**
https://github.com/HendrikReh/chessbuddy

**License:** CC-BY-4.0 (Documentation)
