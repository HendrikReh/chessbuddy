(** FEN (Forsyth-Edwards Notation) generator with chess engine integration

    This module provides stateful position tracking through a game, using
    Chess_engine for accurate board state, castling rights, en passant squares,
    and move clocks. *)

type game_state = {
  board : Chess_engine.Board.t;
  castling_rights : Chess_engine.castling_rights;
  en_passant_square : string option;
  halfmove_clock : int;
  fullmove_number : int;
}
(** Game state tracking all information needed for FEN generation *)

val initial_state : game_state
(** Initial game state at starting position *)

val apply_move :
  game_state ->
  san:string ->
  side_to_move:Chess_engine.color ->
  (game_state, string) Result.t
(** Apply a move to the game state, updating board and metadata
    @param state Current game state
    @param san Standard Algebraic Notation move string
    @param side_to_move Color of player making the move
    @return Ok new_state or Error message *)

val to_fen : game_state -> side_to_move:Chess_engine.color -> string
(** Convert game state to FEN string
    @param state Current game state
    @param side_to_move Color whose turn it is
    @return Complete FEN string *)

val starting_position_fen : string
(** Standard starting position FEN *)

val placeholder_fen : ply_number:int -> side_to_move:char -> string
(** DEPRECATED: Generate placeholder FEN
    @param ply_number The move number (1-indexed)
    @param side_to_move 'w' or 'b'
    @return A placeholder FEN string *)
