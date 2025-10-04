open! Base

(* Core type definitions. *)

type detection_result = {
  detected : bool;
  confidence : float;
  initiating_color : Chess_engine.color option;
  start_ply : int option;
  end_ply : int option;
  metadata : (string * Yojson.Safe.t) list;
}
(** Result produced by a pattern detector. *)

type success_outcome =
  | Victory
  | DrawAdvantage
  | DrawNeutral
  | Defeat  (** High-level outcome returned by success classifiers. *)

module type PATTERN_DETECTOR = sig
  val pattern_id : string
  val pattern_name : string
  val pattern_type : [ `Strategic | `Tactical | `Endgame | `Opening_trap ]

  val detect :
    moves:Types.Move_feature.t list -> result:string -> detection_result Lwt.t

  val classify_success :
    detection:detection_result ->
    result:string ->
    (bool * success_outcome) Lwt.t
end

module Registry : sig
  val register : (module PATTERN_DETECTOR) -> unit
  val get : string -> (module PATTERN_DETECTOR) option
  val list : unit -> (module PATTERN_DETECTOR) list
end
