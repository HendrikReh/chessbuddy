open! Base
(* Core type definitions for pattern detectors. *)

type detection_result = {
  detected : bool;
  confidence : float;
  initiating_color : Chess_engine.color option;
  start_ply : int option;
  end_ply : int option;
  metadata : (string * Yojson.Safe.t) list;
}

(** High-level outcome returned by success classifiers. *)
type success_outcome = Victory | DrawAdvantage | DrawNeutral | Defeat

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

module Registry = struct
  let detectors : (module PATTERN_DETECTOR) Hashtbl.M(String).t =
    Hashtbl.create (module String)

  let register (module D : PATTERN_DETECTOR) =
    if not (Hashtbl.mem detectors D.pattern_id) then
      Hashtbl.set detectors ~key:D.pattern_id
        ~data:(module D : PATTERN_DETECTOR)

  let get id = Hashtbl.find detectors id
  let list () = Hashtbl.data detectors
end
