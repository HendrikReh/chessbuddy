open! Base
open Pattern_detector

module Queenside_majority_stub : PATTERN_DETECTOR = struct
  let pattern_id = "queenside_majority_attack"
  let pattern_name = "Queenside Majority Attack"
  let pattern_type = `Strategic

  let empty_detection =
    {
      detected = false;
      confidence = 0.0;
      initiating_color = None;
      start_ply = None;
      end_ply = None;
      metadata = [];
    }

  let detect ~moves:_ ~result:_ = Lwt.return empty_detection

  let classify_success ~detection ~result:_ =
    if not detection.detected then Lwt.return (false, DrawNeutral)
    else Lwt.return (false, DrawNeutral)
end

module Minority_attack_stub : PATTERN_DETECTOR = struct
  let pattern_id = "minority_attack"
  let pattern_name = "Minority Attack"
  let pattern_type = `Strategic

  let empty_detection =
    {
      detected = false;
      confidence = 0.0;
      initiating_color = None;
      start_ply = None;
      end_ply = None;
      metadata = [];
    }

  let detect ~moves:_ ~result:_ = Lwt.return empty_detection

  let classify_success ~detection ~result:_ =
    if not detection.detected then Lwt.return (false, DrawNeutral)
    else Lwt.return (false, DrawNeutral)
end

let register_all () =
  Pattern_detector.Registry.register (module Queenside_majority_stub);
  Pattern_detector.Registry.register (module Minority_attack_stub)
