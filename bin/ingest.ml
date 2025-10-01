open Cmdliner
open Chessbuddy

let uri_conv : Uri.t Arg.conv =
  let parse s =
    try Ok (Uri.of_string s)
    with exn ->
      let msg =
        Format.asprintf "invalid URI %S (%s)" s (Printexc.to_string exn)
      in
      Error (`Msg msg)
  in
  let print fmt uri = Format.pp_print_string fmt (Uri.to_string uri) in
  Arg.conv ~docv:"URI" (parse, print)

let uuid_conv : Uuidm.t Arg.conv =
  let parse s =
    match Uuidm.of_string s with
    | Some uuid -> Ok uuid
    | None -> Error (`Msg (Format.asprintf "invalid UUID %S" s))
  in
  let print fmt uuid = Format.pp_print_string fmt (Uuidm.to_string uuid) in
  Arg.conv ~docv:"UUID" (parse, print)

let take n lst =
  let rec aux acc idx = function
    | [] -> List.rev acc
    | _ when idx = 0 -> List.rev acc
    | x :: xs -> aux (x :: acc) (idx - 1) xs
  in
  aux [] n lst

let format_exn = function Failure msg -> msg | exn -> Printexc.to_string exn

let run_lwt action =
  let open Lwt.Infix in
  Lwt_main.run
    (Lwt.catch
       (fun () -> action () >|= fun () -> `Ok ())
       (fun exn ->
         let msg = Format.asprintf "error: %s" (format_exn exn) in
         Lwt.return (`Error (false, msg))))

let pp_timestamp ts = Ptime.to_rfc3339 ~tz_offset_s:0 ts

let command_catalog =
  [
    ( "ingest",
      "Ingest a PGN file into the database",
      "ingest --db-uri URI --pgn FILE [--batch-label LABEL] [--dry-run]" );
    ( "batches list",
      "List recently ingested batches",
      "batches list --db-uri URI [--limit N]" );
    ( "batches show",
      "Show metrics for a specific batch",
      "batches show --db-uri URI --id UUID" );
    ( "players sync",
      "Upsert players from a PGN without recording games",
      "players sync --db-uri URI --from-pgn FILE" );
    ( "health check",
      "Verify database connectivity and required extensions",
      "health check --db-uri URI" );
    ("help", "Explain available commands and their parameters", "help [COMMAND]");
  ]

let show_catalog topic =
  let print_entry (name, summary, usage) =
    Format.printf "%-14s %s@." name summary;
    Format.printf "              Usage: %s@.@." usage
  in
  match topic with
  | None ->
      Format.printf "Available commands:@.@.";
      List.iter print_entry command_catalog;
      `Ok ()
  | Some raw -> (
      let topic = String.lowercase_ascii raw in
      let matches (name, _, _) = String.lowercase_ascii name = topic in
      match List.find_opt matches command_catalog with
      | Some entry ->
          print_entry entry;
          `Ok ()
      | None ->
          Format.printf "Unknown command %s@.@." raw;
          List.iter print_entry command_catalog;
          `Ok ())

let help_term =
  let doc = "Show chessbuddy CLI help" in
  let topic_doc = "Command name to describe" in
  let topic =
    Arg.(
      value & pos 0 (some string) None & info [] ~doc:topic_doc ~docv:"COMMAND")
  in
  let term = Term.(ret (const show_catalog $ topic)) in
  Cmd.v (Cmd.info "help" ~doc) term

let ingest_action uri pgn_path batch_label dry_run =
  let open Lwt.Infix in
  let action () =
    if dry_run then (
      Ingestion_pipeline.inspect_file (module Pgn_source.Default) ~pgn_path
      >|= fun summary ->
      Format.printf "PGN dry-run summary:@.";
      Format.printf "  Games: %d@." summary.total_games;
      Format.printf "  Moves: %d@." summary.total_moves;
      Format.printf "  Unique players: %d@." summary.unique_players;
      let preview = take 5 summary.players in
      (match preview with
      | [] -> ()
      | players ->
          Format.printf "  Sample players:@.";
          List.iter
            (fun (name, fide) ->
              match fide with
              | None -> Format.printf "    - %s@." name
              | Some id -> Format.printf "    - %s (FIDE %s)@." name id)
            players);
      if summary.unique_players > List.length preview then
        Format.printf "  ...@.";
      Format.printf "Use without --dry-run to persist results.@.";
      ())
    else
      Ingestion_pipeline.with_pool uri (fun pool ->
          Ingestion_pipeline.ingest_file
            (module Pgn_source.Default)
            pool
            ~embedder:(module Embedder.Constant)
            ~pgn_path ~batch_label)
      >|= fun () ->
      Format.printf "Ingestion completed for label %s.@." batch_label
  in
  run_lwt action

let ingest_cmd =
  let doc = "Ingest PGN games into chessbuddy" in
  let info = Cmd.info "ingest" ~doc in
  let db_uri_doc = "PostgreSQL connection URI" in
  let pgn_doc = "Path to the PGN file to ingest" in
  let batch_doc = "Label identifying the ingestion batch" in
  let dry_doc =
    "Parse the PGN and report summary without writing to the database"
  in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:db_uri_doc ~docv:"URI")
  in
  let pgn =
    Arg.(
      required & opt (some file) None & info [ "pgn" ] ~doc:pgn_doc ~docv:"FILE")
  in
  let batch =
    Arg.(
      value & opt string "manual"
      & info [ "batch-label" ] ~doc:batch_doc ~docv:"LABEL")
  in
  let dry_run = Arg.(value & flag & info [ "dry-run" ] ~doc:dry_doc) in
  let term =
    Term.(ret (const ingest_action $ db_uri $ pgn $ batch $ dry_run))
  in
  Cmd.v info term

let batches_list_action uri limit =
  let open Lwt.Infix in
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool ->
        Database.list_batches pool ~limit)
    >>= function
    | Error err -> Lwt.fail_with (Caqti_error.show err)
    | Ok batches ->
        let () =
          match batches with
          | [] -> Format.printf "No batches found.@."
          | batches ->
              Format.printf "%-38s  %-12s  %-20s  %s@." "Batch ID" "Label"
                "Ingested At" "Source";
              List.iter
                (fun (batch : Database.batch_overview) ->
                  let source = Filename.basename batch.source_path in
                  Format.printf "%-38s  %-12s  %-20s  %s@."
                    (Uuidm.to_string batch.batch_id)
                    batch.label
                    (pp_timestamp batch.ingested_at)
                    source)
                batches
        in
        Lwt.return_unit
  in
  run_lwt action

let list_cmd =
  let doc = "List recently ingested batches" in
  let info = Cmd.info "list" ~doc in
  let db_uri_doc = "PostgreSQL connection URI" in
  let limit_doc = "Maximum number of batches to display" in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:db_uri_doc ~docv:"URI")
  in
  let limit =
    Arg.(value & opt int 10 & info [ "limit" ] ~doc:limit_doc ~docv:"N")
  in
  let term = Term.(ret (const batches_list_action $ db_uri $ limit)) in
  Cmd.v info term

let batches_show_action uri batch_id =
  let open Lwt.Infix in
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool ->
        Database.get_batch_summary pool ~batch_id)
    >>= function
    | Error err -> Lwt.fail_with (Caqti_error.show err)
    | Ok None ->
        Lwt.fail_with
          (Format.asprintf "No batch found for id %s" (Uuidm.to_string batch_id))
    | Ok (Some summary) ->
        Format.printf "Batch %s@." (Uuidm.to_string summary.overview.batch_id);
        Format.printf "  Label: %s@." summary.overview.label;
        Format.printf "  Source: %s@." summary.overview.source_path;
        Format.printf "  Checksum: %s@." summary.overview.checksum;
        Format.printf "  Ingested at: %s@."
          (pp_timestamp summary.overview.ingested_at);
        Format.printf "  Games: %d@." summary.games_count;
        Format.printf "  Positions: %d@." summary.position_count;
        Format.printf "  Unique FENs: %d@." summary.unique_fens;
        Format.printf "  Embeddings: %d@." summary.embedding_count;
        Lwt.return_unit
  in
  run_lwt action

let show_cmd =
  let doc = "Show metrics for a specific batch" in
  let info = Cmd.info "show" ~doc in
  let db_uri_doc = "PostgreSQL connection URI" in
  let batch_doc = "Batch UUID to inspect" in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:db_uri_doc ~docv:"URI")
  in
  let batch_id =
    Arg.(
      required
      & opt (some uuid_conv) None
      & info [ "id" ] ~doc:batch_doc ~docv:"UUID")
  in
  let term = Term.(ret (const batches_show_action $ db_uri $ batch_id)) in
  Cmd.v info term

let batches_cmd =
  let doc = "Inspect ingestion batches" in
  Cmd.group (Cmd.info "batches" ~doc) [ list_cmd; show_cmd ]

let players_sync_action uri pgn_path =
  let open Lwt.Infix in
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool ->
        Ingestion_pipeline.sync_players_from_pgn
          (module Pgn_source.Default)
          pool ~pgn_path)
    >|= fun count -> Format.printf "Upserted %d unique players.@." count
  in
  run_lwt action

let players_sync_cmd =
  let doc = "Sync players from a PGN file" in
  let info = Cmd.info "sync" ~doc in
  let db_uri_doc = "PostgreSQL connection URI" in
  let pgn_doc = "Path to the PGN file" in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:db_uri_doc ~docv:"URI")
  in
  let pgn =
    Arg.(
      required
      & opt (some file) None
      & info [ "from-pgn" ] ~doc:pgn_doc ~docv:"FILE")
  in
  let term = Term.(ret (const players_sync_action $ db_uri $ pgn)) in
  Cmd.v info term

let players_cmd =
  let doc = "Player management helpers" in
  Cmd.group (Cmd.info "players" ~doc) [ players_sync_cmd ]

let health_check_action uri =
  let open Lwt.Infix in
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool -> Database.health_check pool)
    >>= function
    | Error err -> Lwt.fail_with (Caqti_error.show err)
    | Ok report ->
        Format.printf "Database: %s@." report.database_name;
        Format.printf "Server version: %s@." report.server_version;
        Format.printf "Extensions:@.";
        List.iter
          (fun (name, present) ->
            let status = if present then "ok" else "missing" in
            Format.printf "  - %-10s %s@." name status)
          report.extensions;
        Lwt.return_unit
  in
  run_lwt action

let health_cmd =
  let doc = "Run health checks against PostgreSQL" in
  let info = Cmd.info "check" ~doc in
  let db_uri_doc = "PostgreSQL connection URI" in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:db_uri_doc ~docv:"URI")
  in
  let term = Term.(ret (const health_check_action $ db_uri)) in
  Cmd.v info term

let health_group =
  let doc = "Database diagnostics" in
  Cmd.group (Cmd.info "health" ~doc) [ health_cmd ]

let default_term = Term.(ret (const show_catalog $ const None))

let chessbuddy_cmd =
  let doc = "Chessbuddy ingestion CLI" in
  Cmd.group ~default:default_term
    (Cmd.info "chessbuddy" ~doc)
    [ ingest_cmd; batches_cmd; players_cmd; health_group; help_term ]

let () = exit (Cmd.eval chessbuddy_cmd)
