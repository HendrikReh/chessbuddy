open! Base
open Alcotest
open Chessbuddy
open Lwt.Infix
module Move = Types.Move_feature
module Helpers = Test_helpers

let color_pp fmt = function
  | Chess_engine.White -> Stdlib.Format.fprintf fmt "white"
  | Chess_engine.Black -> Stdlib.Format.fprintf fmt "black"

let color_to_string = function
  | Chess_engine.White -> "white"
  | Chess_engine.Black -> "black"

let color_testable = Alcotest.testable color_pp Poly.equal

let mk_move ~ply ~san ~side ~fen_before ~fen_after ?(is_capture = false) () =
  {
    Move.ply_number = ply;
    san;
    uci = None;
    fen_before;
    fen_after;
    side_to_move = side;
    eval_cp = None;
    is_capture;
    is_check = String.is_suffix san ~suffix:"+";
    is_mate = String.is_suffix san ~suffix:"#";
    motifs = [];
    comments_before = [];
    comments_after = [];
    variations = [];
    nags = [];
  }

let queenside_majority_moves =
  let f0 = "6k1/8/pp6/8/PPP5/8/8/4K3 w - - 0 1" in
  let f1 = "6k1/8/pp6/1P6/P1P5/8/8/4K3 b - - 0 1" in
  let f2 = "7k/8/pp6/1P6/P1P5/8/8/4K3 w - - 1 2" in
  let f3 = "7k/8/Pp6/8/P1P5/8/8/4K3 b - - 0 2" in
  let f4 = "8/6k1/Pp6/8/P1P5/8/8/4K3 w - - 1 3" in
  [
    mk_move ~ply:1 ~san:"b5" ~side:'w' ~fen_before:f0 ~fen_after:f1 ();
    mk_move ~ply:2 ~san:"Kh8" ~side:'b' ~fen_before:f1 ~fen_after:f2 ();
    mk_move ~ply:3 ~san:"bxa6" ~side:'w' ~fen_before:f2 ~fen_after:f3
      ~is_capture:true ();
    mk_move ~ply:4 ~san:"Kg7" ~side:'b' ~fen_before:f3 ~fen_after:f4 ();
  ]

let minority_attack_moves =
  let f0 = "6k1/ppp5/8/8/8/PP6/8/4K3 w - - 0 1" in
  let f1 = "6k1/ppp5/8/8/1P6/P7/8/4K3 b - - 0 1" in
  let f2 = "6k1/pp6/2p5/8/1P6/P7/8/4K3 w - - 0 2" in
  let f3 = "6k1/pp6/2p5/1P6/8/P7/8/4K3 b - - 0 2" in
  let f4 = "6k1/1p6/p1p5/1P6/8/P7/8/4K3 w - - 1 3" in
  let f5 = "6k1/1p6/p1P5/8/8/P7/8/4K3 b - - 0 3" in
  [
    mk_move ~ply:1 ~san:"b4" ~side:'w' ~fen_before:f0 ~fen_after:f1 ();
    mk_move ~ply:2 ~san:"c6" ~side:'b' ~fen_before:f1 ~fen_after:f2 ();
    mk_move ~ply:3 ~san:"b5" ~side:'w' ~fen_before:f2 ~fen_after:f3 ();
    mk_move ~ply:4 ~san:"a6" ~side:'b' ~fen_before:f3 ~fen_after:f4 ();
    mk_move ~ply:5 ~san:"bxc6" ~side:'w' ~fen_before:f4 ~fen_after:f5
      ~is_capture:true ();
  ]

let test_registry _switch () =
  Patterns.register_all ();
  let patterns = Pattern_detector.Registry.list () in
  check bool "has patterns" true (List.length patterns >= 4);
  Lwt.return_unit

let test_queenside_detects_nothing_on_empty _switch () =
  Strategic_patterns.Queenside_majority.detect ~moves:[] ~result:"1-0"
  >>= fun detection ->
  check bool "not detected" false detection.detected;
  Lwt.return_unit

let test_queenside_majority_detection _switch () =
  Strategic_patterns.Queenside_majority.detect ~moves:queenside_majority_moves
    ~result:"1-0"
  >>= fun detection ->
  if not detection.detected then
    Alcotest.failf "detection failed: confidence=%f metadata=%s"
      detection.confidence
      (Yojson.Safe.to_string (`Assoc detection.metadata));
  check bool "detected" true detection.detected;
  check (option color_testable) "initiating color" (Some Chess_engine.White)
    detection.initiating_color;
  check bool "confidence high" true Float.(detection.confidence >= 0.55);
  Lwt.return_unit

let test_minority_attack_detection _switch () =
  Strategic_patterns.Minority_attack.detect ~moves:minority_attack_moves
    ~result:"1-0"
  >>= fun detection ->
  check bool "detected" true detection.detected;
  check (option color_testable) "initiating color" (Some Chess_engine.White)
    detection.initiating_color;
  check bool "confidence reasonable" true Float.(detection.confidence >= 0.45);
  Lwt.return_unit

let test_ingestion_records_pattern _switch () =
  Helpers.with_clean_db (fun pool ->
      let header : Types.Game_header.t =
        {
          event = Some "Test Event";
          site = Some "Test Site";
          game_date = None;
          round = Some "1";
          eco = Some "E90";
          opening = Some "King's Indian Defence";
          white_player = "GM White";
          black_player = "IM Black";
          white_elo = Some 2550;
          black_elo = Some 2400;
          white_fide_id = None;
          black_fide_id = None;
          result = "1-0";
          termination = None;
        }
      in
      let game : Types.Game.t =
        {
          header;
          moves = queenside_majority_moves;
          source_pgn = "1. b5 Kh8 2. bxa6 Kg7 1-0";
        }
      in
      let embedder = (module Embedder.Constant : Ingestion_pipeline.EMBEDDER) in
      let%lwt () =
        Database.ensure_ingestion_batches pool >>= function
        | Ok () -> Lwt.return_unit
        | Error err ->
            let () = Helpers.raise_or_skip err in
            Lwt.return_unit
      in
      let%lwt batch_res =
        Database.create_batch pool ~source_path:"/tmp/test.pgn"
          ~label:"test-batch" ~checksum:"checksum"
      in
      let batch_id =
        match batch_res with
        | Ok id -> id
        | Error err -> Helpers.raise_or_skip err
      in
      let%lwt () =
        Ingestion_pipeline.process_game pool ~embedder ~batch_id ~game
          ~source_path:"/tmp/test.pgn" ~batch_label:"test-batch"
          ~search_embedder:None
      in
      let%lwt results =
        Database.query_games_with_pattern pool
          ~pattern_ids:[ "queenside_majority_attack" ]
          ~detected_by:(Some Chess_engine.White) ~success:true
          ~min_confidence:(Some 0.5) ~max_confidence:None ~eco_prefix:(Some "E")
          ~opening_substring:(Some "King's") ~min_white_elo:(Some 2500)
          ~max_white_elo:None ~min_black_elo:None ~max_black_elo:None
          ~min_rating_difference:(Some 100) ~min_move_count:(Some 4)
          ~max_move_count:None ~start_date:None ~end_date:None
          ~white_name_substring:(Some "GM") ~black_name_substring:(Some "IM")
          ~result_filter:(Some "1-0") ~limit:10 ~offset:0
        >>= function
        | Ok rows -> Lwt.return rows
        | Error err ->
            let () = Helpers.raise_or_skip err in
            Lwt.return []
      in
      check int "one game detected" 1 (List.length results);
      (match results with
      | [ overview ] ->
          check string "white player" header.white_player overview.white_player;
          check string "black player" header.black_player overview.black_player;
          check string "result" header.result overview.result;
          check (option string) "eco" header.eco overview.eco;
          check (option string) "opening" header.opening overview.opening;
          check string "detected color" "white"
            (color_to_string overview.detected_by);
          check bool "confidence >= 0.55" true
            Float.(overview.confidence >= 0.55);
          check (option string) "outcome" (Some "victory") overview.outcome
      | _ -> ());
      Lwt.return_unit)

let suite =
  let open Alcotest_lwt in
  [
    test_case "registry populates" `Quick test_registry;
    test_case "queenside attack requires moves" `Quick
      test_queenside_detects_nothing_on_empty;
    test_case "queenside majority detection" `Quick
      test_queenside_majority_detection;
    test_case "minority attack detection" `Quick test_minority_attack_detection;
    test_case "ingestion stores pattern detections" `Quick
      test_ingestion_records_pattern;
  ]
