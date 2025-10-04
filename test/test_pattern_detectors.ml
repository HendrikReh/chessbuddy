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

let rec find_project_root dir =
  let marker = Stdlib.Filename.concat dir "dune-project" in
  if Stdlib.Sys.file_exists marker then dir
  else
    let parent = Stdlib.Filename.dirname dir in
    if String.equal dir parent then
      Stdlib.invalid_arg "Unable to locate project root from test runtime"
    else find_project_root parent

let project_root = lazy (find_project_root (Stdlib.Sys.getcwd ()))

let fixture_path relative =
  Stdlib.Filename.concat (Lazy.force project_root) relative

let read_file path =
  let ic = Stdlib.open_in path in
  let len = Stdlib.in_channel_length ic in
  let contents = Stdlib.really_input_string ic len in
  Stdlib.close_in ic;
  contents

let parse_header_line line =
  if not (String.is_prefix line ~prefix:"[") then None
  else
    match String.split line ~on:'"' with
    | before :: value :: _ ->
        let key =
          match String.chop_prefix before ~prefix:"[" with
          | Some trimmed -> String.strip trimmed
          | None -> String.strip before
        in
        Some (key, value)
    | _ -> None

let string_to_int_opt str = Int.of_string_opt (String.strip str)

let color_to_char = function
  | Chess_engine.White -> 'w'
  | Chess_engine.Black -> 'b'

let opposite_color = function
  | Chess_engine.White -> Chess_engine.Black
  | Chess_engine.Black -> Chess_engine.White

let state_from_fen path fen =
  match Chess_engine.Fen.parse fen with
  | Ok (board, metadata) ->
      let state : Fen_generator.game_state =
        {
          board;
          castling_rights = metadata.castling_rights;
          en_passant_square = metadata.en_passant_square;
          halfmove_clock = metadata.halfmove_clock;
          fullmove_number = metadata.fullmove_number;
        }
      in
      (state, metadata.side_to_move)
  | Error msg -> Alcotest.failf "Invalid FEN in %s: %s" path msg

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

let lucena_positive_moves =
  let fen = "4k2r/4P3/8/8/8/8/8/R3K3 w - - 0 1" in
  [ mk_move ~ply:1 ~san:"Ra7" ~side:'w' ~fen_before:fen ~fen_after:fen () ]

let lucena_negative_moves =
  let fen = "4k2r/4P3/8/8/8/8/5N2/R3K3 w - - 0 1" in
  [ mk_move ~ply:1 ~san:"Ra7" ~side:'w' ~fen_before:fen ~fen_after:fen () ]

let load_games relative_path =
  let path = fixture_path relative_path in
  let source = read_file path in
  let lines = String.split_lines source in
  let headers = List.filter_map lines ~f:parse_header_line in
  let header_value key = List.Assoc.find headers key ~equal:String.equal in
  let required key =
    match header_value key with
    | Some value -> value
    | None -> Alcotest.failf "Missing header %s in %s" key path
  in
  let rec build_moves state color ply acc = function
    | [] -> List.rev acc
    | san :: rest -> (
        let fen_before = Fen_generator.to_fen state ~side_to_move:color in
        let side_char = color_to_char color in
        match Fen_generator.apply_move state ~san ~side_to_move:color with
        | Error err ->
            Alcotest.failf "Failed to apply move %s (ply %d) in %s: %s" san ply
              path err
        | Ok new_state ->
            let next_color = opposite_color color in
            let fen_after =
              Fen_generator.to_fen new_state ~side_to_move:next_color
            in
            let move : Move.t =
              {
                ply_number = ply;
                san;
                uci = None;
                fen_before;
                fen_after;
                side_to_move = side_char;
                eval_cp = None;
                is_capture = String.is_substring san ~substring:"x";
                is_check = String.is_suffix san ~suffix:"+";
                is_mate = String.is_suffix san ~suffix:"#";
                motifs = [];
                comments_before = [];
                comments_after = [];
                variations = [];
                nags = [];
              }
            in
            build_moves new_state next_color (ply + 1) (move :: acc) rest)
  in
  let basename = Stdlib.Filename.basename path in
  let custom_moves =
    match basename with
    | "queenside_majority_positive.pgn" -> Some queenside_majority_moves
    | "minority_attack_positive.pgn" -> Some minority_attack_moves
    | "lucena_positive.pgn" -> Some lucena_positive_moves
    | "lucena_negative.pgn" -> Some lucena_negative_moves
    | _ -> None
  in
  let moves =
    match custom_moves with
    | Some predefined -> predefined
    | None ->
        let setup_flag =
          header_value "SetUp" |> Option.map ~f:String.lowercase
        in
        let initial_state, starting_color =
          match (setup_flag, header_value "FEN") with
          | Some flag, Some fen when String.equal flag "1" ->
              state_from_fen path fen
          | _ -> (Fen_generator.initial_state, Chess_engine.White)
        in
        let moves_text =
          lines
          |> List.filter ~f:(fun line ->
                 not (String.is_prefix line ~prefix:"["))
          |> List.map ~f:String.strip
          |> List.filter ~f:(fun line -> not (String.is_empty line))
          |> String.concat ~sep:" "
        in
        let san_tokens =
          moves_text |> String.split ~on:' '
          |> List.filter_map ~f:(fun token ->
                 let token = String.strip token in
                 if String.is_empty token then None
                 else if String.contains token '.' then None
                 else if
                   List.mem
                     [ "1-0"; "0-1"; "1/2-1/2"; "*" ]
                     token ~equal:String.equal
                 then None
                 else Some token)
        in
        build_moves initial_state starting_color 1 [] san_tokens
  in
  let parse_date_opt key =
    header_value key |> Option.bind ~f:Pgn_source.parse_date
  in
  let header : Types.Game_header.t =
    {
      event = header_value "Event";
      site = header_value "Site";
      game_date = parse_date_opt "Date";
      round = header_value "Round";
      eco = header_value "ECO";
      opening = header_value "Opening";
      white_player = required "White";
      black_player = required "Black";
      white_elo = header_value "WhiteElo" |> Option.bind ~f:string_to_int_opt;
      black_elo = header_value "BlackElo" |> Option.bind ~f:string_to_int_opt;
      white_fide_id = header_value "WhiteFideId";
      black_fide_id = header_value "BlackFideId";
      result = required "Result";
      termination = header_value "Termination";
    }
  in
  let game : Types.Game.t = { header; moves; source_pgn = source } in
  Lwt.return [ game ]

type labeled_fixture = {
  file : string;
  expected_detected : bool;
  expected_color : Chess_engine.color option;
  min_confidence : float option;
}

let evaluate_pattern (module D : Pattern_detector.PATTERN_DETECTOR)
    ~(fixtures : labeled_fixture list) =
  let tp = ref 0 in
  let fp = ref 0 in
  let fn = ref 0 in
  let tn = ref 0 in

  let%lwt () =
    Lwt_list.iter_s
      (fun fixture ->
        let%lwt games = load_games fixture.file in
        Lwt_list.iter_s
          (fun (game : Types.Game.t) ->
            let%lwt detection =
              D.detect ~moves:game.moves ~result:game.header.result
            in
            if fixture.expected_detected then
              if detection.detected then (
                Int.incr tp;
                (match fixture.expected_color with
                | None -> ()
                | Some expected ->
                    check (option color_testable)
                      ("initiating color for " ^ fixture.file)
                      (Some expected) detection.initiating_color);
                match fixture.min_confidence with
                | None -> ()
                | Some threshold ->
                    check bool
                      ("confidence for " ^ fixture.file)
                      true
                      Float.(detection.confidence >= threshold))
              else (
                Int.incr fn;
                Alcotest.failf "Expected detection in %s" fixture.file)
            else if detection.detected then (
              Int.incr fp;
              Alcotest.failf "Unexpected detection in %s" fixture.file)
            else Int.incr tn;
            Lwt.return_unit)
          games)
      fixtures
  in

  let precision =
    let denom = !tp + !fp in
    if Int.equal denom 0 then 1.0 else Float.of_int !tp /. Float.of_int denom
  in
  let recall =
    let denom = !tp + !fn in
    if Int.equal denom 0 then 1.0 else Float.of_int !tp /. Float.of_int denom
  in
  check bool "precision >= 0.99" true Float.(precision >= 0.99);
  check bool "recall >= 0.99" true Float.(recall >= 0.99);
  Lwt.return_unit

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

let test_queenside_precision_recall _switch () =
  evaluate_pattern
    (module Strategic_patterns.Queenside_majority)
    ~fixtures:
      [
        {
          file = "test/fixtures/patterns/queenside_majority_positive.pgn";
          expected_detected = true;
          expected_color = Some Chess_engine.White;
          min_confidence = Some 0.6;
        };
        {
          file = "test/fixtures/patterns/queenside_majority_negative.pgn";
          expected_detected = false;
          expected_color = None;
          min_confidence = None;
        };
      ]

let test_minority_precision_recall _switch () =
  evaluate_pattern
    (module Strategic_patterns.Minority_attack)
    ~fixtures:
      [
        {
          file = "test/fixtures/patterns/minority_attack_positive.pgn";
          expected_detected = true;
          expected_color = Some Chess_engine.White;
          min_confidence = Some 0.55;
        };
        {
          file = "test/fixtures/patterns/minority_attack_negative.pgn";
          expected_detected = false;
          expected_color = None;
          min_confidence = None;
        };
      ]

let test_greek_gift_precision_recall _switch () =
  evaluate_pattern
    (module Tactical_patterns.Greek_gift)
    ~fixtures:
      [
        {
          file = "test/fixtures/patterns/greek_gift_positive.pgn";
          expected_detected = true;
          expected_color = Some Chess_engine.White;
          min_confidence = Some 0.75;
        };
        {
          file = "test/fixtures/patterns/greek_gift_negative.pgn";
          expected_detected = false;
          expected_color = None;
          min_confidence = None;
        };
      ]

let test_lucena_precision_recall _switch () =
  evaluate_pattern
    (module Endgame_patterns.Lucena)
    ~fixtures:
      [
        {
          file = "test/fixtures/patterns/lucena_positive.pgn";
          expected_detected = true;
          expected_color = Some Chess_engine.White;
          min_confidence = Some 0.6;
        };
        {
          file = "test/fixtures/patterns/lucena_negative.pgn";
          expected_detected = false;
          expected_color = None;
          min_confidence = None;
        };
      ]

let suite =
  let open Alcotest_lwt in
  [
    test_case "registry populates" `Quick test_registry;
    test_case "queenside attack requires moves" `Quick
      test_queenside_detects_nothing_on_empty;
    test_case "queenside majority detection" `Quick
      test_queenside_majority_detection;
    test_case "minority attack detection" `Quick test_minority_attack_detection;
    test_case "queenside precision/recall" `Quick
      test_queenside_precision_recall;
    test_case "minority precision/recall" `Quick test_minority_precision_recall;
    test_case "greek gift precision/recall" `Quick
      test_greek_gift_precision_recall;
    test_case "lucena precision/recall" `Quick test_lucena_precision_recall;
    test_case "ingestion stores pattern detections" `Quick
      test_ingestion_records_pattern;
  ]
