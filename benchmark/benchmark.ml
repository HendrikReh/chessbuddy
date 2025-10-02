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
    if Float.(per_second > 1000.0) then Fmt.sprintf "%.2f k/s" (per_second /. 1000.0)
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
}
(** Benchmark configuration *)

let default_config =
  {
    db_uri = "postgresql://chess:chess@localhost:5433/chessbuddy";
    pgn_path = "data/games/sample.pgn";
    warmup_runs = 1;
    benchmark_runs = 3;
    retrieval_samples = 100;
  }

(** Stub text embedder for benchmarking *)
module Stub_text_embedder = struct
  let model = "stub-benchmark"
  let vector_dim = 1536

  let embed ~text =
    let _text = text in (* Use parameter to avoid unused warning *)
    Lwt.return (Ok (Array.create ~len:vector_dim 0.))
end

(** Helper to create pool or fail *)
let create_pool uri_string =
  match Database.Pool.create (Uri.of_string uri_string) with
  | Ok pool -> pool
  | Error err -> failwith (Caqti_error.show err)

(** Ingestion benchmarks *)
module Ingestion = struct
  let create_test_pgn path ~num_games =
    let oc = Stdlib.open_out path in
    Exn.protect
      ~finally:(fun () -> Stdlib.close_out_noerr oc)
      ~f:(fun () ->
        for i = 1 to num_games do
          Fmt.fprintf
            (Stdlib.Format.formatter_of_out_channel oc)
            {|[Event "Benchmark Game %d"]
[Site "Test"]
[Date "2024.01.01"]
[Round "1"]
[White "Player A"]
[Black "Player B"]
[Result "1-0"]
[WhiteFideId "%d"]
[BlackFideId "%d"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 1-0

|}
            i (100000 + i) (200000 + i)
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
      let batch_label =
        Fmt.sprintf "benchmark-%f" (Unix.gettimeofday ())
      in

      Ingestion_pipeline.ingest_file
        source
        pool
        ~embedder
        ~pgn_path:test_pgn
        ~batch_label
        ~search_embedder:(Some search_embedder)
        ()
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

(** Retrieval benchmarks - simplified for now *)
module Retrieval = struct
  let benchmark_all config =
    let _config = config in
    Fmt.printf "\n=== Retrieval Benchmarks ===\n";
    Fmt.printf "Retrieval benchmarks not yet implemented.\n";
    Fmt.printf "Focus on ingestion benchmark for now.\n";
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

  let start_time = Unix.gettimeofday () in

  let%lwt () = Ingestion.benchmark_full_ingestion config in
  let%lwt () = Ingestion.benchmark_player_upsert config in
  let%lwt () = Ingestion.benchmark_fen_deduplication config in

  let%lwt () = Retrieval.benchmark_all config in

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

  let usage = "benchmark [options]" in
  let specs =
    [
      ("--db-uri", Stdlib.Arg.Set_string db_uri, "Database URI");
      ("--pgn", Stdlib.Arg.Set_string pgn_path, "PGN file path");
      ("--warmup", Stdlib.Arg.Set_int warmup, "Warmup runs");
      ("--runs", Stdlib.Arg.Set_int runs, "Benchmark runs");
      ("--samples", Stdlib.Arg.Set_int samples, "Retrieval samples");
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
    }
  in

  Lwt_main.run (run_benchmarks config)
