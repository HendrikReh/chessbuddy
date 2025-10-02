(** Domain types for ChessBuddy.

    This module defines the core data structures used throughout the application:
    chess players, game headers, moves with annotations, and ingestion batches.
    All types support ppx_deriving for pretty-printing and JSON serialization. *)

open! Base
open Ppx_yojson_conv_lib.Yojson_conv.Primitives

(** {1 Player Types} *)

module Rating : sig
  type t = {
    standard : int option;  (** FIDE standard time control rating *)
    rapid : int option;  (** FIDE rapid rating *)
    blitz : int option;  (** FIDE blitz rating *)
  }
  [@@deriving show, yojson]
  (** ELO ratings for different time controls.

      All fields are optional as not all players have all rating types. *)
end

module Player : sig
  type t = {
    fide_id : string option;  (** FIDE ID (e.g., "1503014" for Magnus Carlsen) *)
    full_name : string;  (** Player's full name as it appears in PGN *)
    rating_history : (Ptime.t * Rating.t) list;
        (** Historical ratings as (timestamp, ratings) pairs *)
  }
  [@@deriving show]
  (** Chess player with identity and rating history.

      Players are uniquely identified by FIDE ID when available, otherwise by
      normalized name. Rating history allows tracking performance over time. *)
end

(** {1 Game Types} *)

module Game_header : sig
  type t = {
    event : string option;  (** Tournament or match name *)
    site : string option;  (** Location (city, venue, or online platform) *)
    game_date : Ptime.t option;  (** Game date (parsed from PGN YYYY.MM.DD format) *)
    round : string option;  (** Round number or identifier *)
    eco : string option;  (** ECO opening code (e.g., "B90" for Sicilian Najdorf) *)
    opening : string option;  (** Opening name (e.g., "Sicilian Defense") *)
    white_player : string;  (** White player's name *)
    black_player : string;  (** Black player's name *)
    white_elo : int option;  (** White's ELO rating at time of game *)
    black_elo : int option;  (** Black's ELO rating at time of game *)
    white_fide_id : string option;  (** White's FIDE ID *)
    black_fide_id : string option;  (** Black's FIDE ID *)
    result : string;  (** Game result: "1-0", "0-1", "1/2-1/2", or "*" (unknown) *)
    termination : string option;
        (** How game ended: "Normal", "Time forfeit", "Abandoned", etc. *)
  }
  [@@deriving show]
  (** PGN game header metadata.

      Contains all standard PGN seven-tag roster fields plus optional extended tags.
      White and black player names are required; all other fields are optional. *)
end

module Move_feature : sig
  type t = {
    ply_number : int;  (** Move number starting from 1 *)
    san : string;  (** Standard Algebraic Notation (e.g., "Nf3", "e4") *)
    uci : string option;  (** Universal Chess Interface notation (e.g., "e2e4") *)
    fen_before : string;  (** FEN position before this move *)
    fen_after : string;  (** FEN position after this move *)
    side_to_move : char;  (** 'w' for white, 'b' for black *)
    eval_cp : int option;  (** Engine evaluation in centipawns *)
    is_capture : bool;  (** True if move captures a piece *)
    is_check : bool;  (** True if move gives check *)
    is_mate : bool;  (** True if move is checkmate *)
    motifs : string list;
        (** Tactical motifs: "pin", "fork", "skewer", "discovered_attack", etc. *)
    comments_before : string list;  (** Comments before move (from PGN {text}) *)
    comments_after : string list;  (** Comments after move (from PGN {text}) *)
    variations : string list;  (** Alternative move sequences (from PGN (...)) *)
    nags : int list;  (** Numeric Annotation Glyphs (e.g., $1 = good move) *)
  }
  [@@deriving show, yojson]
  (** Complete move information with annotations.

      Captures all data from PGN move text including:
      - Move notation (SAN and optionally UCI)
      - Position tracking (FEN before/after)
      - Annotations (comments, variations, NAGs)
      - Tactical features (captures, checks, mate)
      - Future motif detection placeholder

      FEN positions are currently placeholders (starting position board state)
      pending integration with chess engine for real position tracking. *)
end

module Game : sig
  type t = {
    header : Game_header.t;  (** Game metadata *)
    moves : Move_feature.t list;  (** Chronological list of moves *)
    source_pgn : string;  (** Raw PGN text for this game *)
  }
  [@@deriving show]
  (** Complete chess game with header, moves, and source text.

      Preserves original PGN for reference and stores structured move data
      for analysis. Moves are ordered by ply_number from 1 to N. *)
end

(** {1 Ingestion Types} *)

module Batch : sig
  type t = {
    label : string;  (** Human-readable batch identifier *)
    checksum : string;  (** SHA256 hash of source PGN file *)
    ingested_at : Ptime.t;  (** Timestamp of ingestion *)
  }
  [@@deriving show]
  (** Ingestion batch metadata.

      Batches track PGN file ingestion runs. The checksum prevents duplicate
      ingestion of the same file content. Labels provide human-friendly
      identification (e.g., "twic-1611", "mega-2024"). *)
end
