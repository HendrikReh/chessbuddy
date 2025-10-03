# Chess Library Evaluation Report

**Date:** 2025-10-02
**Evaluator:** System Analysis
**Objective:** Identify OCaml chess library for FEN generation and board tracking

## Executive Summary

**Recommendation:** Build custom FEN generator module using existing PGN parser

**Rationale:**
- No mature OCaml chess library with FEN generation API available in opam
- Existing solutions are either unmaintained, incomplete, or not packaged as libraries
- ChessBuddy already has robust SAN move parsing
- FEN generation is algorithmically straightforward given board state

## Libraries Evaluated

### 1. ocamlchess (bmourad01/ocamlchess)

**Status:** ⚠️ Available but Not Packaged

**Repository:** https://github.com/bmourad01/ocamlchess

**Strengths:**
- UCI-compatible chess engine in OCaml
- 64-bit bitboard representation (performance optimized)
- Active development (1,260+ commits)
- GPL-3.0 licensed

**Critical Weaknesses:**
- **Not published to opam** (would need to vendor or pin)
- **FEN generation API unclear** (UCI engine, not library)
- **Requires Flambda compiler** for best performance
- **64-bit only** (significant performance penalty on 32-bit)
- **Heavy dependencies** (core_kernel, cmdliner, etc.)
- Designed as chess engine, not board manipulation library

**Assessment:** Not suitable for ChessBuddy
- Would need to extract/adapt code from engine
- Unclear if FEN generation is exposed as library API
- Vendoring entire chess engine adds unnecessary complexity

### 2. pgn_parser (ckaf/pgn_parser)

**Status:** ⚠️ Partial Fit

**Strengths:**
- Available in opam (`opam install pgn_parser`)
- Board state tracking with Zobrist hashing
- SAN move parsing (captures, castling, en passant, promotions)
- Property-based testing with QCheck
- MIT licensed, maintained (v1.0.1, 2024)

**Weaknesses:**
- **No FEN generation API** - critical missing feature
- Packaged as binary, not library (no `.mli` files installed)
- Would require forking and modifying source

**Dependencies:**
- ocaml >= 4.14
- cohttp-lwt-unix >= 5.0
- yojson >= 1.7
- lwt >= 5.6

**API Highlights:**
```ocaml
type board = (piece option * bool) array array
type zobrist_hash = int64

val create_starting_position : unit -> board
val apply_move_to_board : board -> move_type -> bool -> board
val calculate_zobrist_hash : board -> zobrist_hash
val get_board_after_move : move list -> int -> bool -> board option
```

**Performance:** Not tested (library not exposed)

### 3. henryrobbins/chess

**Status:** ❌ Educational Project

- OCaml chess implementation from CS 3110 course
- FEN input support mentioned, but no API documentation
- Not available as opam package
- Would require vendoring entire codebase
- 3 stars on GitHub, unclear maintenance status

### 4. cs51project/ocaml-chess

**Status:** ❌ Educational Project

- Learning chess engine in OCaml
- Mentions `fen_encode`, `fen_decode`, `fen_to_pos` functions
- Not available as opam package
- Course project, not production-ready library

### 5. Other Search Results

**Findings:**
- No dedicated chess board manipulation library in opam
- Chess.com API client and Lichess API client exist, but API wrappers only
- No mature, maintained chess engine library ecosystem in OCaml

## Gap Analysis

### What We Need

1. **FEN Generation** ✅ CRITICAL
   - Convert 8x8 board state to FEN notation
   - Track side-to-move, castling rights, en passant square
   - Support full FEN with halfmove clock and fullmove number

2. **Board State Management** ✅ HAVE (via existing Types.ml)
   - Position tracking per move
   - Material balance calculation

3. **Move Application** ✅ HAVE (via PGN parser)
   - SAN parsing and validation
   - Legal move generation (implicit via PGN parsing)

4. **Performance** ✅ CRITICAL
   - Must handle 1M+ moves efficiently
   - Target: <1ms per FEN generation

### What We Have

From ChessBuddy existing codebase:

```ocaml
(* types.ml *)
module Castling_rights = struct
  type t = {
    white_kingside: bool;
    white_queenside: bool;
    black_kingside: bool;
    black_queenside: bool;
  } [@@deriving show, yojson]
end

module Position_feature = struct
  type t = {
    fen: string;
    side_to_move: string;
    castling_rights: string;
    en_passant_square: string option;
    material_signature: string;
    halfmove_clock: int;
    fullmove_number: int;
  } [@@deriving show, yojson]
end
```

We already track all FEN components! Just need the board state conversion.

## Recommendation: Custom FEN Generator

### Approach

Build lightweight `chess_engine.ml` module providing:

1. **Board representation** (8x8 array)
2. **Move application** (SAN → board updates)
3. **FEN serialization** (board → FEN string)

### Implementation Strategy

#### Phase 1: Board State Module (Week 1-2)

```ocaml
(* lib/chess/chess_engine.ml *)
module Board : sig
  type square =
    | Empty
    | Piece of { piece_type: piece; color: color }

  and piece = King | Queen | Rook | Bishop | Knight | Pawn
  and color = White | Black

  type t = square array array

  val initial : t
  val get : t -> file:int -> rank:int -> square
  val set : t -> file:int -> rank:int -> square -> t
  val to_fen_board : t -> string
end
```

#### Phase 2: Move Application (Week 2-3)

```ocaml
module Move_parser : sig
  type move_result = {
    board: Board.t;
    captures: Board.piece option;
    updates_castling: bool;
    creates_en_passant: string option;
  }

  val apply_san :
    Board.t ->
    san:string ->
    side_to_move:color ->
    castling_rights:Castling_rights.t ->
    (move_result, string) Result.t
end
```

#### Phase 3: FEN Generation (Week 3-4)

```ocaml
module Fen : sig
  val generate :
    board:Board.t ->
    side_to_move:color ->
    castling:Castling_rights.t ->
    en_passant:string option ->
    halfmove:int ->
    fullmove:int ->
    string

  val parse : string -> (Board.t * metadata, string) Result.t
end
```

### Testing Strategy

```ocaml
(* test/test_chess_engine.ml *)
let test_fen_generation () =
  let board = Board.initial in
  let fen = Fen.generate
    ~board
    ~side_to_move:White
    ~castling:Castling_rights.all_allowed
    ~en_passant:None
    ~halfmove:0
    ~fullmove:1
  in
  Alcotest.(check string)
    "starting position"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    fen

let test_move_application () =
  let board = Board.initial in
  let result = Move_parser.apply_san board ~san:"e4" ~side_to_move:White in
  match result with
  | Error msg -> Alcotest.fail msg
  | Ok { board; _ } ->
      let fen_board = Board.to_fen_board board in
      (* Verify pawn moved from e2 to e4 *)
      Alcotest.(check bool) "e2 empty" true
        (Board.get board ~file:4 ~rank:1 = Empty);
      Alcotest.(check bool) "e4 has white pawn" true
        (match Board.get board ~file:4 ~rank:3 with
         | Piece { piece_type = Pawn; color = White } -> true
         | _ -> false)
```

### Performance Targets

| Operation | Target | Rationale |
|-----------|--------|-----------|
| FEN generation | <1ms | 428K positions in TWIC benchmark |
| Move application | <0.5ms | Bottle neck for ingestion |
| Board clone | <0.1ms | Frequent operation |

### Validation

Test against standard chess positions:

1. Starting position
2. After 1. e4
3. Scholar's mate
4. Castling positions (both sides)
5. En passant scenarios
6. Promotion examples
7. Complex middlegame (15+ moves)

### Dependencies

**Minimal:**
- Base (already in use)
- No external chess libraries
- ~500 LOC estimated

**Optional enhancements:**
- Legal move validation (if needed)
- Check/checkmate detection (if needed)
- Opening book integration (future)

## Alternative: Fork pgn_parser

### Pros
- Board tracking already implemented
- Zobrist hashing for deduplication
- Tested with QCheck property-based tests

### Cons
- Would need to expose library API (modify dune config)
- Add FEN generation (200-300 LOC)
- Maintain fork alongside upstream
- Pull in unnecessary API client dependencies (cohttp)
- Adds 60 dependencies to ChessBuddy

### Decision
❌ **Not recommended** - Custom solution is cleaner and more maintainable

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| FEN generation bugs | High | Extensive test suite, validate against known positions |
| Performance regression | Medium | Benchmark against current placeholder approach |
| SAN parsing edge cases | Medium | Leverage existing PGN parser validation |
| Maintenance burden | Low | ~500 LOC, well-defined scope |

## Next Steps

1. ✅ Create `lib/chess/chess_engine.ml` module skeleton
2. ✅ Implement `Board` representation
3. ✅ Add FEN serialization
4. ✅ Write test suite with standard positions
5. ⬜ Benchmark performance
6. ⬜ Integrate with `ingestion_pipeline.ml`
7. ⬜ Create migration tooling (regenerate-fens command)

## Appendix: FEN Format Reference

```
FEN: <board> <side> <castling> <en-passant> <halfmove> <fullmove>

Example:
rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1
```

**Board notation:**
- Pieces: K/Q/R/B/N/P (white), k/q/r/b/n/p (black)
- Empty squares: digits 1-8
- Ranks: separated by `/`, from rank 8 to rank 1

**Side to move:** `w` or `b`

**Castling availability:** `KQkq`, `-` if none

**En passant target square:** file + rank (e.g., `e3`), `-` if none

**Halfmove clock:** moves since last capture/pawn move (for 50-move rule)

**Fullmove number:** increments after Black's move

## References

- [PGN Standard](http://www.saremba.de/chessgml/standards/pgn/pgn-complete.htm)
- [FEN Notation](https://www.chessprogramming.org/Forsyth-Edwards_Notation)
- [pgn_parser GitHub](https://github.com/ckaf/pgn_parser)
- [ChessBuddy Implementation Plan](IMPLEMENTATION_PLAN.md)
