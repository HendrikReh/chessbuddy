(** FEN (Forsyth-Edwards Notation) generator for chess positions

    Note: This is a simplified implementation that generates placeholder FENs.
    Full position tracking requires integration with a chess library.
*)

let starting_position_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

let placeholder_fen ~ply_number ~side_to_move =
  (* Generate a placeholder FEN with move numbers updated *)
  let fullmove = (ply_number + 1) / 2 in
  Printf.sprintf "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR %c KQkq - %d %d"
    side_to_move
    0  (* halfmove clock *)
    fullmove