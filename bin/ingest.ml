open Cmdliner
open Chessbuddy

let run db_uri pgn_path batch_label =
  let uri = Uri.of_string db_uri in
  Lwt_main.run
    (Ingestion_pipeline.with_pool uri (fun pool ->
         Ingestion_pipeline.ingest_file
           (module Pgn_source.Default)
           pool
           ~embedder:(module Embedder.Constant)
           ~pgn_path
           ~batch_label))

let db_uri_term =
  let doc = "PostgreSQL connection URI" in
  Arg.(required & opt (some string) None & info [ "db-uri" ] ~docv:"URI" ~doc)

let pgn_term =
  let doc = "Path to the PGN file to ingest" in
  Arg.(required & opt (some file) None & info [ "pgn" ] ~docv:"FILE" ~doc)

let batch_term =
  let doc = "Label identifying this ingestion batch" in
  Arg.(value & opt string "manual" & info [ "batch-label" ] ~docv:"LABEL" ~doc)

let cmd =
  let doc = "Ingest PGN games into chessbuddy" in
  let exits = Term.default_exits in
  Term.(const run $ db_uri_term $ pgn_term $ batch_term), Term.info "chessbuddy-ingest" ~doc ~exits

let () = Term.exit @@ Term.eval cmd
