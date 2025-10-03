(** Chess engine for board state tracking and FEN generation

    This module provides lightweight chess board manipulation focused on FEN
    generation for the ChessBuddy ingestion pipeline. It supports:
    - Board state representation (8x8 array)
    - Move application from SAN notation
    - FEN string serialization

    Performance targets:
    - FEN generation: <1ms per position
    - Move application: <0.5ms per move
    - Board clone: <0.1ms *)

(** {1 Core Types} *)

(** Chess piece types *)
type piece = King | Queen | Rook | Bishop | Knight | Pawn

(** Piece color *)
type color = White | Black

(** Board square - either empty or occupied by a colored piece *)
type square = Empty | Piece of { piece_type : piece; color : color }

type castling_rights = {
  white_kingside : bool;
  white_queenside : bool;
  black_kingside : bool;
  black_queenside : bool;
}
(** Castling rights for both sides *)

(** {1 Board Module} *)

module Board : sig
  type t
  (** 8x8 chess board representation

      Board is indexed [file][rank] where:
      - file: 0-7 (a-h)
      - rank: 0-7 (1-8) *)

  val initial : t
  (** Initial chess position (standard starting setup) *)

  val empty : t
  (** Empty board with no pieces *)

  val get : t -> file:int -> rank:int -> square
  (** Get square at given file and rank

      @param file 0-7 representing files a-h
      @param rank 0-7 representing ranks 1-8
      @raise Invalid_argument if file or rank out of bounds *)

  val set : t -> file:int -> rank:int -> square -> t
  (** Set square at given file and rank (functional update - returns new board)

      @param file 0-7 representing files a-h
      @param rank 0-7 representing ranks 1-8
      @raise Invalid_argument if file or rank out of bounds *)

  val to_fen_board : t -> string
  (** Convert board to FEN board notation (piece placement only)

      Example output: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"

      Uses FEN notation:
      - Uppercase = white pieces (K, Q, R, B, N, P)
      - Lowercase = black pieces (k, q, r, b, n, p)
      - Digits = consecutive empty squares
      - '/' = rank separator (rank 8 to rank 1) *)

  val of_fen_board : string -> (t, string) Result.t
  (** Parse FEN board notation into board state

      @param fen_board FEN piece placement (first field of full FEN)
      @return Ok board or Error message *)

  val to_string : t -> string
  (** Pretty-print board for debugging *)
end

(** {1 Move Application} *)

module Move_parser : sig
  type move_result = {
    board : Board.t;  (** Updated board position *)
    captured : piece option;  (** Piece captured (if any) *)
    castling_rights : castling_rights;
        (** Updated castling rights after move *)
    en_passant_square : string option;
        (** En passant target square (e.g., "e3") for next move if pawn moved
            two squares *)
  }
  (** Result of applying a move, including side effects *)

  val apply_san :
    Board.t ->
    san:string ->
    side_to_move:color ->
    castling_rights:castling_rights ->
    en_passant_target:string option ->
    (move_result, string) Result.t
  (** Apply Standard Algebraic Notation move to board

      Supports:
      - Pawn moves: "e4", "e8=Q" (promotion)
      - Piece moves: "Nf3", "Bb5"
      - Captures: "exd5", "Nxf3"
      - Castling: "O-O" (kingside), "O-O-O" (queenside)
      - Disambiguation: "Nbd7", "R1e2", "Qh4e1"

      Does NOT validate move legality, only parses and applies SAN notation.
      Assumes moves come from valid PGN files.

      @param board Current board position
      @param san Standard Algebraic Notation move string
      @param side_to_move Color of player making the move
      @param castling_rights Current castling availability
      @return Ok move_result or Error message *)
end

(** {1 FEN Generation} *)

module Fen : sig
  type position_metadata = {
    side_to_move : color;
    castling_rights : castling_rights;
    en_passant_square : string option;
    halfmove_clock : int;
    fullmove_number : int;
  }
  (** Complete FEN position metadata *)

  val generate : board:Board.t -> metadata:position_metadata -> string
  (** Generate complete FEN string from board and metadata

      Example output: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

      FEN format: <board> <side> <castling> <en-passant> <halfmove> <fullmove>

      @param board Current board position
      @param metadata Position metadata (side to move, castling, etc.)
      @return Complete FEN string *)

  val parse : string -> (Board.t * position_metadata, string) Result.t
  (** Parse complete FEN string into board and metadata

      @param fen Complete FEN string
      @return Ok (board, metadata) or Error message *)

  val validate : string -> (unit, string) Result.t
  (** Validate FEN string format

      @param fen FEN string to validate
      @return Ok () if valid, Error message otherwise *)
end

(** {1 Utility Functions} *)

val color_to_fen_char : color -> char
(** Convert color to FEN side-to-move character ('w' or 'b') *)

val color_of_fen_char : char -> (color, string) Result.t
(** Parse FEN side-to-move character into color *)

val piece_to_fen_char : piece -> color -> char
(** Convert piece to FEN character (uppercase=white, lowercase=black) *)

val piece_of_fen_char : char -> (piece * color, string) Result.t
(** Parse FEN piece character into (piece, color) *)

val square_notation_to_indices : string -> (int * int, string) Result.t
(** Convert algebraic square notation to (file, rank) indices

    Example: "e4" -> (4, 3)

    @param square Algebraic notation (e.g., "e4", "a1")
    @return Ok (file, rank) or Error message *)

val indices_to_square_notation : int -> int -> (string, string) Result.t
(** Convert (file, rank) indices to algebraic square notation

    Example: (4, 3) -> "e4"

    @param file 0-7
    @param rank 0-7
    @return Algebraic notation or Error if out of bounds *)
