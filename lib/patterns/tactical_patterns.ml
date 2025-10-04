open! Base
open Pattern_detector

let is_greek_gift san =
  String.is_substring san ~substring:"Bxh7"
  || String.is_substring san ~substring:"Bxh2"

module Greek_gift : PATTERN_DETECTOR = struct
  let pattern_id = "greek_gift_sacrifice"
  let pattern_name = "Greek Gift Sacrifice"
  let pattern_type = `Tactical

  let detect ~moves ~result:_ =
    match
      List.findi moves ~f:(fun _ (move : Types.Move_feature.t) ->
          is_greek_gift move.san)
    with
    | None ->
        Lwt.return
          {
            detected = false;
            confidence = 0.0;
            initiating_color = None;
            start_ply = None;
            end_ply = None;
            metadata = [];
          }
    | Some (_idx, move) ->
        let color =
          if Char.equal move.side_to_move 'w' then Chess_engine.White
          else Chess_engine.Black
        in
        let confidence =
          if String.is_suffix move.san ~suffix:"#" then 1.0 else 0.8
        in
        Lwt.return
          {
            detected = true;
            confidence;
            initiating_color = Some color;
            start_ply = Some move.ply_number;
            end_ply = Some move.ply_number;
            metadata =
              [ ("san", `String move.san); ("ply", `Int move.ply_number) ];
          }

  let classify_success ~detection ~result =
    if not detection.detected then Lwt.return (false, DrawNeutral)
    else
      let color =
        Option.value detection.initiating_color ~default:Chess_engine.White
      in
      let success =
        match (color, result) with
        | Chess_engine.White, "1-0" -> true
        | Chess_engine.Black, "0-1" -> true
        | _ -> false
      in
      let outcome =
        if success then Victory
        else if String.equal result "1/2-1/2" then DrawNeutral
        else Defeat
      in
      Lwt.return (success, outcome)
end

let register_all () = Registry.register (module Greek_gift)
