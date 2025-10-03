open! Base

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

(** Initial game state at starting position *)
let initial_state =
  {
    board = Chess_engine.Board.initial;
    castling_rights =
      {
        Chess_engine.white_kingside = true;
        white_queenside = true;
        black_kingside = true;
        black_queenside = true;
      };
    en_passant_square = None;
    halfmove_clock = 0;
    fullmove_number = 1;
  }

(** Detect piece type from SAN notation *)
let piece_type_from_san san =
  if String.equal san "O-O" || String.equal san "O-O-O" then Chess_engine.King
  else if String.length san = 0 then Chess_engine.Pawn
  else
    let first_char = String.get san 0 in
    if Char.is_uppercase first_char then
      (* Piece move: N, B, R, Q, K *)
      match Chess_engine.piece_of_fen_char first_char with
      | Ok (piece, _) -> piece
      | Error _ -> Chess_engine.Pawn (* Fallback to pawn *)
    else Chess_engine.Pawn

(* Lowercase or no prefix = pawn *)

(** Apply a move to the game state, updating board and metadata *)
let apply_move state ~san ~side_to_move =
  let piece_type = piece_type_from_san san in
  match
    Chess_engine.Move_parser.apply_san state.board ~san ~side_to_move
      ~castling_rights:state.castling_rights
      ~en_passant_target:state.en_passant_square
  with
  | Error e -> Error e
  | Ok move_result ->
      let is_pawn_move = Chess_engine.(phys_equal piece_type Pawn) in
      let is_capture = Option.is_some move_result.captured in
      let new_halfmove =
        if is_pawn_move || is_capture then 0 else state.halfmove_clock + 1
      in
      let new_fullmove =
        if Chess_engine.(phys_equal side_to_move Black) then
          state.fullmove_number + 1
        else state.fullmove_number
      in
      Ok
        {
          board = move_result.board;
          castling_rights = move_result.castling_rights;
          en_passant_square = move_result.en_passant_square;
          halfmove_clock = new_halfmove;
          fullmove_number = new_fullmove;
        }

(** Convert game state to FEN string *)
let to_fen state ~side_to_move =
  let metadata : Chess_engine.Fen.position_metadata =
    {
      side_to_move;
      castling_rights = state.castling_rights;
      en_passant_square = state.en_passant_square;
      halfmove_clock = state.halfmove_clock;
      fullmove_number = state.fullmove_number;
    }
  in
  Chess_engine.Fen.generate ~board:state.board ~metadata

(** Starting position FEN for convenience *)
let starting_position_fen =
  to_fen initial_state ~side_to_move:Chess_engine.White

(** Legacy placeholder function - deprecated, logs warning *)
let placeholder_fen ~ply_number:_ ~side_to_move:_ =
  Stdlib.Printf.eprintf
    "[WARN] fen_generator.placeholder_fen is deprecated - use stateful \
     apply_move instead\n";
  starting_position_fen
