open! Base
open Chessbuddy
module Fmt = Stdlib.Format

(** Timing utilities *)
module Timer = struct
  let time_lwt f =
    let start = Unix.gettimeofday () in
    let%lwt result = f () in
    let finish = Unix.gettimeofday () in
    Lwt.return (result, finish -. start)

  let format_duration seconds =
    if Float.(seconds < 1.0) then Fmt.sprintf "%.2f ms" (seconds *. 1000.0)
    else if Float.(seconds < 60.0) then Fmt.sprintf "%.2f s" seconds
    else Fmt.sprintf "%.2f min" (seconds /. 60.0)

  let format_throughput count seconds =
    let per_second = Float.of_int count /. seconds in
    if Float.(per_second > 1000.0) then
      Fmt.sprintf "%.2f k/s" (per_second /. 1000.0)
    else Fmt.sprintf "%.2f /s" per_second
end

(** Statistics tracking *)
module Stats = struct
  type t = {
    count : int;
    total_time : float;
    min_time : float;
    max_time : float;
    times : float list;
  }

  let create () =
    {
      count = 0;
      total_time = 0.0;
      min_time = Float.max_finite_value;
      max_time = 0.0;
      times = [];
    }

  let add stats time =
    {
      count = stats.count + 1;
      total_time = stats.total_time +. time;
      min_time = Float.min stats.min_time time;
      max_time = Float.max stats.max_time time;
      times = time :: stats.times;
    }

  let mean stats =
    if stats.count = 0 then 0.0
    else stats.total_time /. Float.of_int stats.count

  let median stats =
    if stats.count = 0 then 0.0
    else
      let sorted = List.sort stats.times ~compare:Float.compare in
      let len = List.length sorted in
      if len % 2 = 0 then
        let mid = len / 2 in
        (List.nth_exn sorted mid +. List.nth_exn sorted (mid - 1)) /. 2.0
      else List.nth_exn sorted (len / 2)

  let percentile stats p =
    if stats.count = 0 then 0.0
    else
      let sorted = List.sort stats.times ~compare:Float.compare in
      let idx =
        Float.to_int (Float.of_int (List.length sorted) *. p /. 100.0)
      in
      let idx = Int.max 0 (Int.min (List.length sorted - 1) idx) in
      List.nth_exn sorted idx

  let print_summary label stats =
    Fmt.printf "\n%s:\n" label;
    Fmt.printf "  Count:       %d\n" stats.count;
    Fmt.printf "  Total time:  %s\n" (Timer.format_duration stats.total_time);
    Fmt.printf "  Mean:        %s\n" (Timer.format_duration (mean stats));
    Fmt.printf "  Median:      %s\n" (Timer.format_duration (median stats));
    Fmt.printf "  Min:         %s\n" (Timer.format_duration stats.min_time);
    Fmt.printf "  Max:         %s\n" (Timer.format_duration stats.max_time);
    Fmt.printf "  P50:         %s\n"
      (Timer.format_duration (percentile stats 50.0));
    Fmt.printf "  P95:         %s\n"
      (Timer.format_duration (percentile stats 95.0));
    Fmt.printf "  P99:         %s\n"
      (Timer.format_duration (percentile stats 99.0));
    Fmt.printf "  Throughput:  %s\n"
      (Timer.format_throughput stats.count stats.total_time)
end

type config = {
  db_uri : string;
  pgn_path : string;
  warmup_runs : int;
  benchmark_runs : int;
  retrieval_samples : int;
  pattern_samples : int;
}
(** Benchmark configuration *)

let default_config =
  {
    db_uri = "postgresql://chess:chess@localhost:5433/chessbuddy";
    pgn_path = "data/games/sample.pgn";
    warmup_runs = 1;
    benchmark_runs = 3;
    retrieval_samples = 100;
    pattern_samples = 50;
  }

(** Stub text embedder for benchmarking *)
module Stub_text_embedder = struct
  let model = "stub-benchmark"
  let vector_dim = 1536

  let embed ~text =
    let _text = text in
    (* Use parameter to avoid unused warning *)
    Lwt.return (Ok (Array.create ~len:vector_dim 0.))
end

(** Helper to create pool or fail *)
let create_pool uri_string =
  match Database.Pool.create (Uri.of_string uri_string) with
  | Ok pool -> pool
  | Error err -> failwith (Caqti_error.show err)

module Pattern_analysis = struct
  module Registry = Pattern_detector.Registry

  let uuid_type =
    let encode uuid = Ok (Uuidm.to_string uuid) in
    let decode str =
      match Uuidm.of_string str with
      | Some uuid -> Ok uuid
      | None -> Error ("Invalid UUID: " ^ str)
    in
    Caqti_type.(custom ~encode ~decode string)

  type sample_game = { result : string; moves : Types.Move_feature.t list }

  let move_query =
    let open Caqti_request.Infix in
    let open Caqti_type in
    let row_type =
      t2 int
        (t2 string
           (t2 (option string)
              (t2 string
                 (t2 string
                    (t2 string (t2 (option int) (t2 bool (t2 bool bool))))))))
    in
    (uuid_type -->* row_type)
    @:- {sql|
    SELECT ply_number,
           san,
           uci,
           fen_before,
           fen_after,
           side_to_move,
           eval_cp,
           is_capture,
           is_check,
           is_mate
    FROM games_positions
    WHERE game_id = ?
    ORDER BY ply_number ASC
  |sql}

  let load_moves pool game_id =
    let%lwt rows_result =
      Database.Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
          Db.collect_list move_query game_id)
    in
    let%lwt rows = Database.or_fail rows_result in
    let moves =
      List.map rows
        ~f:(fun
            ( ply,
              ( san,
                ( uci,
                  ( fen_before,
                    ( fen_after,
                      ( side_to_move,
                        (eval_cp, (is_capture, (is_check, is_mate))) ) ) ) ) )
            )
          ->
          let side_char =
            if String.length side_to_move > 0 then String.get side_to_move 0
            else 'w'
          in
          let motifs = [] in
          {
            Types.Move_feature.ply_number = ply;
            san;
            uci;
            fen_before;
            fen_after;
            side_to_move = side_char;
            eval_cp;
            is_capture;
            is_check;
            is_mate;
            motifs;
            comments_before = [];
            comments_after = [];
            variations = [];
            nags = [];
          })
    in
    Lwt.return moves

  let load_sample_games pool ~limit =
    let limit = Int.max 0 limit in
    if limit = 0 then Lwt.return []
    else
      let%lwt games_result = Database.list_games pool ~limit ~offset:0 in
      let%lwt games = Database.or_fail games_result in
      Lwt_list.filter_map_s
        (fun (overview : Database.game_overview) ->
          let%lwt moves = load_moves pool overview.game_id in
          if List.is_empty moves then Lwt.return_none
          else Lwt.return_some { result = overview.result; moves })
        games

  let pattern_type_to_string = function
    | `Strategic -> "strategic"
    | `Tactical -> "tactical"
    | `Endgame -> "endgame"
    | `Opening_trap -> "opening_trap"

  let outcome_to_string = function
    | Pattern_detector.Victory -> "victory"
    | DrawAdvantage -> "draw_advantage"
    | DrawNeutral -> "draw_neutral"
    | Defeat -> "defeat"

  type pattern_info = {
    detector : (module Pattern_detector.PATTERN_DETECTOR);
    id : string;
    name : string;
    kind : string;
    stats : Stats.t ref;
    detections : int ref;
    successes : int ref;
    confidence_sum : float ref;
    outcome_counts : (string, int) Hashtbl.t;
  }

  let make_info detector =
    let module D = (val detector : Pattern_detector.PATTERN_DETECTOR) in
    {
      detector;
      id = D.pattern_id;
      name = D.pattern_name;
      kind = pattern_type_to_string D.pattern_type;
      stats = ref (Stats.create ());
      detections = ref 0;
      successes = ref 0;
      confidence_sum = ref 0.0;
      outcome_counts = Hashtbl.create (module String);
    }

  let update_outcome counts label =
    Hashtbl.change counts label ~f:(function
      | None -> Some 1
      | Some count -> Some (count + 1))

  let benchmark config =
    Fmt.printf "\n=== Pattern Detection Benchmark ===\n%!";
    let pool = create_pool config.db_uri in
    Patterns.register_all ();
    let detectors = Registry.list () in
    if List.is_empty detectors then (
      Fmt.printf "No pattern detectors registered. Skipping benchmark.\n%!";
      Lwt.return_unit)
    else
      let%lwt samples = load_sample_games pool ~limit:config.pattern_samples in
      let games_processed = List.length samples in
      if games_processed = 0 then (
        Fmt.printf
          "No games with stored positions were found. Ingest data before \
           running pattern benchmarks.\n\
           %!";
        Lwt.return_unit)
      else
        let pattern_infos = List.map detectors ~f:make_info in
        let%lwt () =
          Lwt_list.iter_s
            (fun sample ->
              Lwt_list.iter_s
                (fun info ->
                  let module D =
                    (val info.detector : Pattern_detector.PATTERN_DETECTOR)
                  in
                  let%lwt (detection, (success_flag, outcome)), elapsed =
                    Timer.time_lwt (fun () ->
                        let%lwt detection =
                          D.detect ~moves:sample.moves ~result:sample.result
                        in
                        let%lwt success_info =
                          if detection.detected then
                            D.classify_success ~detection ~result:sample.result
                          else Lwt.return (false, Pattern_detector.DrawNeutral)
                        in
                        Lwt.return (detection, success_info))
                  in
                  info.stats := Stats.add !(info.stats) elapsed;
                  if detection.detected then (
                    info.detections := !(info.detections) + 1;
                    info.confidence_sum :=
                      !(info.confidence_sum) +. detection.confidence;
                    update_outcome info.outcome_counts
                      (outcome_to_string outcome);
                    if success_flag then info.successes := !(info.successes) + 1);
                  Lwt.return_unit)
                pattern_infos)
            samples
        in
        Fmt.printf "Processed %d games across %d detectors.\n" games_processed
          (List.length pattern_infos);
        List.iter pattern_infos ~f:(fun info ->
            let stats_label =
              Fmt.sprintf "%s (%s) [%s]" info.name info.kind info.id
            in
            Stats.print_summary stats_label !(info.stats);
            let detection_count = !(info.detections) in
            let detection_rate =
              if games_processed = 0 then 0.0
              else
                Float.of_int detection_count
                /. Float.of_int games_processed
                *. 100.0
            in
            let avg_confidence =
              if detection_count = 0 then 0.0
              else !(info.confidence_sum) /. Float.of_int detection_count
            in
            let success_rate =
              if detection_count = 0 then 0.0
              else
                Float.of_int !(info.successes)
                /. Float.of_int detection_count
                *. 100.0
            in
            Fmt.printf "  Detections: %d/%d (%.1f%%)\n" detection_count
              games_processed detection_rate;
            Fmt.printf "  Success rate: %.1f%%\n" success_rate;
            Fmt.printf "  Avg confidence: %.3f\n" avg_confidence;
            let outcome_breakdown =
              info.outcome_counts |> Hashtbl.to_alist
              |> List.sort ~compare:(fun (a, _) (b, _) -> String.compare a b)
            in
            if not (List.is_empty outcome_breakdown) then (
              Fmt.printf "  Outcome counts:\n";
              List.iter outcome_breakdown ~f:(fun (label, count) ->
                  Fmt.printf "    %s: %d\n" label count));
            Fmt.printf "\n";
            ());
        Lwt.return_unit
end

(** Ingestion benchmarks *)
module Ingestion = struct
  let create_test_pgn path ~num_games =
    let oc = Stdlib.open_out path in
    Exn.protect
      ~finally:(fun () -> Stdlib.close_out_noerr oc)
      ~f:(fun () ->
        for i = 1 to num_games do
          let white_fide = 100000 + i in
          let black_fide = 200000 + i in
          Fmt.fprintf
            (Stdlib.Format.formatter_of_out_channel oc)
            {|[Event "Benchmark Game %d"]
[Site "Test"]
[Date "2024.01.01"]
[Round "1"]
[White "White Player %d"]
[Black "Black Player %d"]
[Result "1-0"]
[WhiteFideId "%d"]
[BlackFideId "%d"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 1-0

|}
            i white_fide black_fide white_fide black_fide
        done)

  let benchmark_full_ingestion config =
    Fmt.printf "\n=== Ingestion Benchmarks ===\n";

    (* Create test PGN *)
    let test_pgn = Stdlib.Filename.temp_file "benchmark" ".pgn" in
    create_test_pgn test_pgn ~num_games:100;

    let run_ingestion () =
      let pool = create_pool config.db_uri in
      let embedder = (module Embedder.Constant : Ingestion_pipeline.EMBEDDER) in
      let search_embedder =
        (module Stub_text_embedder : Ingestion_pipeline.TEXT_EMBEDDER)
      in
      let source =
        (module Pgn_source.Default : Ingestion_pipeline.PGN_SOURCE)
      in

      (* Use unique batch label to avoid conflicts *)
      let batch_label = Fmt.sprintf "benchmark-%f" (Unix.gettimeofday ()) in

      Ingestion_pipeline.ingest_file source pool ~embedder ~pgn_path:test_pgn
        ~batch_label ~search_embedder:(Some search_embedder) ()
    in

    let%lwt () =
      Fmt.printf "\nWarmup runs (%d)...\n" config.warmup_runs;
      Lwt_list.iter_s
        (fun i ->
          Fmt.printf "  Warmup %d/%d\n%!" i config.warmup_runs;
          let%lwt _ = run_ingestion () in
          Lwt.return_unit)
        (List.init config.warmup_runs ~f:(fun i -> i + 1))
    in

    Fmt.printf "\nBenchmark runs (%d)...\n" config.benchmark_runs;
    let stats = ref (Stats.create ()) in

    let%lwt () =
      Lwt_list.iter_s
        (fun i ->
          Fmt.printf "  Run %d/%d\n%!" i config.benchmark_runs;
          let%lwt _, elapsed = Timer.time_lwt run_ingestion in
          stats := Stats.add !stats elapsed;
          Lwt.return_unit)
        (List.init config.benchmark_runs ~f:(fun i -> i + 1))
    in

    Stats.print_summary "Full Ingestion (100 games)" !stats;

    (* Cleanup *)
    Stdlib.Sys.remove test_pgn;
    Lwt.return_unit

  let benchmark_player_upsert config =
    Fmt.printf "\n=== Player Upsert Benchmark ===\n";

    let pool = create_pool config.db_uri in
    let stats = ref (Stats.create ()) in
    let num_players = 1000 in

    Fmt.printf "Upserting %d players...\n" num_players;

    let%lwt () =
      Lwt_list.iter_s
        (fun i ->
          let name = Fmt.sprintf "Player %d" i in
          let fide_id = Some (Fmt.sprintf "%d" (100000 + i)) in
          let%lwt _, elapsed =
            Timer.time_lwt (fun () ->
                Database.upsert_player pool ~full_name:name ~fide_id)
          in
          stats := Stats.add !stats elapsed;
          Lwt.return_unit)
        (List.init num_players ~f:(fun i -> i))
    in

    Stats.print_summary "Player Upsert" !stats;
    Lwt.return_unit

  let benchmark_fen_deduplication config =
    Fmt.printf "\n=== FEN Deduplication Benchmark ===\n";

    let pool = create_pool config.db_uri in
    let stats_first = ref (Stats.create ()) in
    let stats_duplicate = ref (Stats.create ()) in
    let num_fens = 500 in

    Fmt.printf "Inserting %d unique FENs...\n" num_fens;

    let%lwt () =
      Lwt_list.iter_s
        (fun i ->
          let fen_text =
            Fmt.sprintf
              "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 %d" (i + 1)
          in
          let%lwt _, elapsed =
            Timer.time_lwt (fun () ->
                Database.upsert_fen pool ~fen_text ~side_to_move:'w'
                  ~castling:"KQkq" ~en_passant:None
                  ~material_signature:"standard")
          in
          stats_first := Stats.add !stats_first elapsed;
          Lwt.return_unit)
        (List.init num_fens ~f:(fun i -> i))
    in

    Fmt.printf "Re-upserting same %d FENs (testing dedup)...\n" num_fens;

    let%lwt () =
      Lwt_list.iter_s
        (fun i ->
          let fen_text =
            Fmt.sprintf
              "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 %d" (i + 1)
          in
          let%lwt _, elapsed =
            Timer.time_lwt (fun () ->
                Database.upsert_fen pool ~fen_text ~side_to_move:'w'
                  ~castling:"KQkq" ~en_passant:None
                  ~material_signature:"standard")
          in
          stats_duplicate := Stats.add !stats_duplicate elapsed;
          Lwt.return_unit)
        (List.init num_fens ~f:(fun i -> i))
    in

    Stats.print_summary "FEN First Insert" !stats_first;
    Stats.print_summary "FEN Duplicate (dedup)" !stats_duplicate;

    let speedup = Stats.mean !stats_first /. Stats.mean !stats_duplicate in
    Fmt.printf "\nDeduplication speedup: %.2fx\n" speedup;

    Lwt.return_unit
end

(** Retrieval benchmarks *)
module Retrieval = struct
  let benchmark_game_retrieval config =
    Fmt.printf "\n=== Game Retrieval Benchmark ===\n";

    let pool = create_pool config.db_uri in
    let stats = ref (Stats.create ()) in

    (* Get sample game IDs *)
    Fmt.printf "Fetching sample game IDs...\n%!";
    let%lwt game_ids =
      let%lwt result =
        Database.list_games pool ~limit:config.retrieval_samples ~offset:0
      in
      match result with
      | Ok games -> Lwt.return (List.map games ~f:(fun g -> g.Database.game_id))
      | Error err -> failwith (Caqti_error.show err)
    in

    if List.is_empty game_ids then (
      Fmt.printf "No games in database. Run ingestion first.\n";
      Lwt.return_unit)
    else (
      Fmt.printf "Retrieving %d games...\n%!" (List.length game_ids);

      let%lwt () =
        Lwt_list.iter_s
          (fun game_id ->
            let%lwt _, elapsed =
              Timer.time_lwt (fun () ->
                  let%lwt result = Database.get_game_detail pool ~game_id in
                  match result with
                  | Ok _ -> Lwt.return_unit
                  | Error err -> failwith (Caqti_error.show err))
            in
            stats := Stats.add !stats elapsed;
            Lwt.return_unit)
          game_ids
      in

      Stats.print_summary "Game Retrieval" !stats;
      Lwt.return_unit)

  let benchmark_player_search config =
    Fmt.printf "\n=== Player Search Benchmark ===\n";

    let pool = create_pool config.db_uri in
    let stats = ref (Stats.create ()) in
    let search_terms = [ "White"; "Black"; "Player"; "100"; "200" ] in

    Fmt.printf "Searching %d terms, %d iterations each...\n%!"
      (List.length search_terms)
      (config.retrieval_samples / List.length search_terms);

    let iterations = config.retrieval_samples / List.length search_terms in

    let%lwt () =
      Lwt_list.iter_s
        (fun term ->
          Lwt_list.iter_s
            (fun _ ->
              let%lwt _, elapsed =
                Timer.time_lwt (fun () ->
                    let%lwt result =
                      Database.search_players pool ~query:term ~limit:10
                    in
                    match result with
                    | Ok _ -> Lwt.return_unit
                    | Error err -> failwith (Caqti_error.show err))
              in
              stats := Stats.add !stats elapsed;
              Lwt.return_unit)
            (List.init iterations ~f:(fun i -> i)))
        search_terms
    in

    Stats.print_summary "Player Search" !stats;
    Lwt.return_unit

  let benchmark_fen_lookup config =
    Fmt.printf "\n=== FEN Lookup Benchmark ===\n";

    let pool = create_pool config.db_uri in
    let stats = ref (Stats.create ()) in

    (* Get sample FEN IDs by querying games_positions *)
    Fmt.printf "Fetching sample FEN IDs...\n%!";
    let uuid_type =
      let encode uuid = Ok (Uuidm.to_string uuid) in
      let decode str =
        match Uuidm.of_string str with
        | Some uuid -> Ok uuid
        | None -> Error ("Invalid UUID: " ^ str)
      in
      Caqti_type.(custom ~encode ~decode string)
    in
    let get_fen_ids_query =
      let open Caqti_request.Infix in
      (Caqti_type.int -->* uuid_type)
      @:- {sql|
        SELECT DISTINCT fen_id FROM games_positions LIMIT ?
      |sql}
    in

    let%lwt fen_ids =
      let%lwt result =
        Database.Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
            Db.fold get_fen_ids_query
              (fun id acc -> id :: acc)
              config.retrieval_samples [])
      in
      match result with
      | Ok ids -> Lwt.return ids
      | Error err -> failwith (Caqti_error.show err)
    in

    if List.is_empty fen_ids then (
      Fmt.printf "No FENs in database. Run ingestion first.\n";
      Lwt.return_unit)
    else (
      Fmt.printf "Looking up %d FENs...\n%!" (List.length fen_ids);

      let%lwt () =
        Lwt_list.iter_s
          (fun fen_id ->
            let%lwt _, elapsed =
              Timer.time_lwt (fun () ->
                  let%lwt result = Database.get_fen_details pool ~fen_id in
                  match result with
                  | Ok _ -> Lwt.return_unit
                  | Error err -> failwith (Caqti_error.show err))
            in
            stats := Stats.add !stats elapsed;
            Lwt.return_unit)
          fen_ids
      in

      Stats.print_summary "FEN Lookup" !stats;
      Lwt.return_unit)

  let benchmark_similar_search config =
    Fmt.printf "\n=== Vector Similarity Search Benchmark ===\n";

    let pool = create_pool config.db_uri in
    let stats = ref (Stats.create ()) in

    (* Get a sample FEN with embedding *)
    Fmt.printf "Finding FEN with embedding...\n%!";
    let uuid_type =
      let encode uuid = Ok (Uuidm.to_string uuid) in
      let decode str =
        match Uuidm.of_string str with
        | Some uuid -> Ok uuid
        | None -> Error ("Invalid UUID: " ^ str)
      in
      Caqti_type.(custom ~encode ~decode string)
    in
    let get_fen_query =
      let open Caqti_request.Infix in
      (Caqti_type.unit -->? uuid_type)
      @:- {sql|
        SELECT fen_id FROM fen_embeddings LIMIT 1
      |sql}
    in

    let%lwt result =
      Database.Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
          Db.find_opt get_fen_query ())
    in

    match result with
    | Error err -> failwith (Caqti_error.show err)
    | Ok None ->
        Fmt.printf "No FEN embeddings in database. Run ingestion first.\n";
        Lwt.return_unit
    | Ok (Some fen_id) ->
        Fmt.printf "Running %d similarity searches...\n%!"
          config.retrieval_samples;

        let%lwt () =
          Lwt_list.iter_s
            (fun _ ->
              let%lwt _, elapsed =
                Timer.time_lwt (fun () ->
                    let%lwt result =
                      Database.find_similar_fens pool ~fen_id ~limit:10
                    in
                    match result with
                    | Ok _ -> Lwt.return_unit
                    | Error err -> failwith (Caqti_error.show err))
              in
              stats := Stats.add !stats elapsed;
              Lwt.return_unit)
            (List.init config.retrieval_samples ~f:(fun i -> i))
        in

        Stats.print_summary "Similarity Search" !stats;
        Lwt.return_unit

  let benchmark_batch_listing config =
    Fmt.printf "\n=== Batch Listing Benchmark ===\n";

    let pool = create_pool config.db_uri in
    let stats = ref (Stats.create ()) in

    Fmt.printf "Listing batches %d times...\n%!" config.retrieval_samples;

    let%lwt () =
      Lwt_list.iter_s
        (fun _ ->
          let%lwt _, elapsed =
            Timer.time_lwt (fun () ->
                let%lwt result = Database.list_batches pool ~limit:20 in
                match result with
                | Ok _ -> Lwt.return_unit
                | Error err -> failwith (Caqti_error.show err))
          in
          stats := Stats.add !stats elapsed;
          Lwt.return_unit)
        (List.init config.retrieval_samples ~f:(fun i -> i))
    in

    Stats.print_summary "Batch Listing" !stats;
    Lwt.return_unit
end

(** Main benchmark runner *)
let run_benchmarks config =
  Fmt.printf "ChessBuddy Performance Benchmark\n";
  Fmt.printf "=================================\n\n";
  Fmt.printf "Configuration:\n";
  Fmt.printf "  DB URI:           %s\n" config.db_uri;
  Fmt.printf "  PGN Path:         %s\n" config.pgn_path;
  Fmt.printf "  Warmup runs:      %d\n" config.warmup_runs;
  Fmt.printf "  Benchmark runs:   %d\n" config.benchmark_runs;
  Fmt.printf "  Retrieval samples: %d\n" config.retrieval_samples;
  Fmt.printf "  Pattern samples:  %d\n" config.pattern_samples;

  let start_time = Unix.gettimeofday () in

  let%lwt () = Ingestion.benchmark_full_ingestion config in
  let%lwt () = Ingestion.benchmark_player_upsert config in
  let%lwt () = Ingestion.benchmark_fen_deduplication config in

  let%lwt () = Retrieval.benchmark_game_retrieval config in
  let%lwt () = Retrieval.benchmark_player_search config in
  let%lwt () = Retrieval.benchmark_fen_lookup config in
  let%lwt () = Retrieval.benchmark_similar_search config in
  let%lwt () = Retrieval.benchmark_batch_listing config in
  let%lwt () = Pattern_analysis.benchmark config in

  let total_time = Unix.gettimeofday () -. start_time in

  Fmt.printf "\n=================================\n";
  Fmt.printf "Total benchmark time: %s\n" (Timer.format_duration total_time);
  Fmt.printf "=================================\n";

  Lwt.return_unit

(** CLI *)
let () =
  let db_uri = ref default_config.db_uri in
  let pgn_path = ref default_config.pgn_path in
  let warmup = ref default_config.warmup_runs in
  let runs = ref default_config.benchmark_runs in
  let samples = ref default_config.retrieval_samples in
  let pattern_samples = ref default_config.pattern_samples in

  let usage = "benchmark [options]" in
  let specs =
    [
      ("--db-uri", Stdlib.Arg.Set_string db_uri, "Database URI");
      ("--pgn", Stdlib.Arg.Set_string pgn_path, "PGN file path");
      ("--warmup", Stdlib.Arg.Set_int warmup, "Warmup runs");
      ("--runs", Stdlib.Arg.Set_int runs, "Benchmark runs");
      ("--samples", Stdlib.Arg.Set_int samples, "Retrieval samples");
      ( "--pattern-samples",
        Stdlib.Arg.Set_int pattern_samples,
        "Pattern detection sample size" );
    ]
  in

  Stdlib.Arg.parse specs (fun _ -> ()) usage;

  let config =
    {
      db_uri = !db_uri;
      pgn_path = !pgn_path;
      warmup_runs = !warmup;
      benchmark_runs = !runs;
      retrieval_samples = !samples;
      pattern_samples = Int.max 0 !pattern_samples;
    }
  in

  Lwt_main.run (run_benchmarks config)
