(** FEN (Forsyth-Edwards Notation) generator for chess positions

    Note: This is a simplified implementation that generates placeholder FENs.
    Full position tracking requires integration with a chess library. *)

val starting_position_fen : string
(** Standard starting position FEN *)

val placeholder_fen : ply_number:int -> side_to_move:char -> string
(** Generate placeholder FEN for a position after N moves
    @param ply_number The move number (1-indexed)
    @param side_to_move 'w' or 'b'
    @return A placeholder FEN string *)
