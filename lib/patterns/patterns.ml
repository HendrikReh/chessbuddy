open! Base

let register_all () =
  Strategic_patterns.register_all ();
  Tactical_patterns.register_all ();
  Endgame_patterns.register_all ()
