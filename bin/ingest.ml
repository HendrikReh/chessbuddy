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

let run uri pgn_path batch_label =
  let open Lwt.Infix in
  let format_exn exn =
    match exn with Failure msg -> msg | _ -> Printexc.to_string exn
  in
  Lwt_main.run
    (Lwt.catch
       (fun () ->
         Ingestion_pipeline.with_pool uri (fun pool ->
             Ingestion_pipeline.ingest_file
               (module Pgn_source.Default)
               pool
               ~embedder:(module Embedder.Constant)
               ~pgn_path ~batch_label)
         >|= fun () -> `Ok ())
       (fun exn ->
         let msg = Format.asprintf "ingestion failed: %s" (format_exn exn) in
         Lwt.return (`Error (false, msg))))

let db_uri_term =
  let doc = "PostgreSQL connection URI" in
  Arg.(required & opt (some uri_conv) None & info [ "db-uri" ] ~docv:"URI" ~doc)

let pgn_term =
  let doc = "Path to the PGN file to ingest" in
  Arg.(required & opt (some file) None & info [ "pgn" ] ~docv:"FILE" ~doc)

let batch_term =
  let doc = "Label identifying this ingestion batch" in
  Arg.(value & opt string "manual" & info [ "batch-label" ] ~docv:"LABEL" ~doc)

let cmd =
  let doc = "Ingest PGN games into chessbuddy" in
  let info = Cmd.info "chessbuddy-ingest" ~doc ~exits:Cmd.Exit.defaults in
  Cmd.v info Term.(ret (const run $ db_uri_term $ pgn_term $ batch_term))

let () = exit (Cmd.eval cmd)
