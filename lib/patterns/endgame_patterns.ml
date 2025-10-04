open! Base
open Pattern_detector

let stub_detection =
  {
    detected = false;
    confidence = 0.0;
    initiating_color = None;
    start_ply = None;
    end_ply = None;
    metadata = [];
  }

module Lucena_stub : PATTERN_DETECTOR = struct
  let pattern_id = "lucena_position"
  let pattern_name = "Lucena Position"
  let pattern_type = `Endgame
  let detect ~moves:_ ~result:_ = Lwt.return stub_detection

  let classify_success ~detection ~result:_ =
    if not detection.detected then Lwt.return (false, DrawNeutral)
    else Lwt.return (false, DrawNeutral)
end

module Philidor_stub : PATTERN_DETECTOR = struct
  let pattern_id = "philidor_position"
  let pattern_name = "Philidor Position"
  let pattern_type = `Endgame
  let detect ~moves:_ ~result:_ = Lwt.return stub_detection

  let classify_success ~detection ~result:_ =
    if not detection.detected then Lwt.return (false, DrawNeutral)
    else Lwt.return (false, DrawNeutral)
end

let register_all () =
  Pattern_detector.Registry.register (module Lucena_stub);
  Pattern_detector.Registry.register (module Philidor_stub)
