open! Base

(* Pawn structure analysis helpers built on top of Chess_engine. *)

type zone = [ `Queenside | `Kingside | `Center ]

type transition = {
  from_file : int;
  from_rank : int;
  to_file : int;
  to_rank : int;
  is_capture : bool;
  double_step : bool;
}
(** Details about a single pawn move detected via board diffs. *)

val pawn_positions :
  Chess_engine.Board.t -> color:Chess_engine.color -> (int * int) list
(** List all pawn coordinates (file, rank) for the given color. Files 0-7
    correspond to files a-h; ranks 0-7 correspond to ranks 1-8. *)

val count_zone : Chess_engine.Board.t -> color:Chess_engine.color -> zone -> int
(** Count pawns belonging to [color] inside the specified zone. Queenside =
    files a-c, kingside = files f-h, centre = files d-e. *)

val has_zone_majority :
  Chess_engine.Board.t -> zone:zone -> color:Chess_engine.color -> bool
(** Returns [true] if [color] has strictly more pawns than the opponent in
    [zone]. *)

val detect_transition :
  before:Chess_engine.Board.t ->
  after:Chess_engine.Board.t ->
  color:Chess_engine.color ->
  zone:zone ->
  transition option
(** Compute the pawn transition inside [zone] for [color] between two boards. *)

val advancing_pawn :
  before:Chess_engine.Board.t ->
  after:Chess_engine.Board.t ->
  color:Chess_engine.color ->
  zone:zone ->
  (int * int) option
(** Detect whether [color] advanced a pawn inside [zone] when transitioning from
    board [before] to board [after]. Returns the destination square if detected.
*)

val opponent_pawn_removed :
  before:Chess_engine.Board.t ->
  after:Chess_engine.Board.t ->
  color:Chess_engine.color ->
  zone:zone ->
  bool
(** True if an opponent pawn disappears from [zone] during the transition. *)

val passed_pawn_created :
  before:Chess_engine.Board.t ->
  after:Chess_engine.Board.t ->
  color:Chess_engine.color ->
  zone:zone ->
  bool
(** Rough heuristic that checks if a pawn move in [zone] created a potential
    passed pawn (no opponent pawns on adjacent files ahead of the pawn). *)

val island_count : Chess_engine.Board.t -> color:Chess_engine.color -> int
(** Count pawn islands (contiguous files containing pawns) for [color]. *)

val max_rank_in_zone :
  Chess_engine.Board.t -> color:Chess_engine.color -> zone:zone -> int option
(** Highest rank reached by [color]'s pawn inside [zone] (closest to promotion).
*)
