open! Base
open Pattern_detector

module Greek_gift_stub : PATTERN_DETECTOR = struct
  let pattern_id = "greek_gift_sacrifice"
  let pattern_name = "Greek Gift Sacrifice"
  let pattern_type = `Tactical

  let detect ~moves:_ ~result:_ =
    Lwt.return
      {
        detected = false;
        confidence = 0.0;
        initiating_color = None;
        start_ply = None;
        end_ply = None;
        metadata = [];
      }

  let classify_success ~detection ~result:_ =
    if not detection.detected then Lwt.return (false, DrawNeutral)
    else Lwt.return (false, DrawNeutral)
end

let register_all () =
  Pattern_detector.Registry.register (module Greek_gift_stub)
