open! Base

let eval argv = Ingest_cli.eval_value ~argv ()

let string_of_eval = function
  | Ok (`Ok ()) -> "`Ok ()"
  | Ok `Help -> "`Help"
  | Ok `Version -> "`Version"
  | Error `Parse -> "`Error `Parse"
  | Error `Term -> "`Error `Term"
  | Error `Exn -> "`Error `Exn"

let expect_help label argv =
  match eval argv with
  | Ok `Help -> Lwt.return_unit
  | other ->
      Alcotest.failf "%s: expected help, got %s" label (string_of_eval other)

let expect_parse_error label argv =
  match eval argv with
  | Error `Parse -> Lwt.return_unit
  | other ->
      Alcotest.failf "%s: expected parse error, got %s" label
        (string_of_eval other)

let expect_term_error label argv =
  match eval argv with
  | Error `Term -> Lwt.return_unit
  | other ->
      Alcotest.failf "%s: expected term error, got %s" label
        (string_of_eval other)

let expect_ok label argv =
  match eval argv with
  | Ok (`Ok ()) -> Lwt.return_unit
  | other ->
      Alcotest.failf "%s: expected ok, got %s" label (string_of_eval other)

let test_root_help () =
  Alcotest_lwt.test_case "--help at root" `Quick (fun _switch () ->
      expect_help "root help" [| "chessbuddy"; "--help" |])

let test_ingest_help () =
  Alcotest_lwt.test_case "ingest --help" `Quick (fun _switch () ->
      expect_help "ingest help" [| "chessbuddy"; "ingest"; "--help" |])

let test_ingest_requires_args () =
  Alcotest_lwt.test_case "ingest requires db-uri and pgn" `Quick
    (fun _switch () ->
      expect_parse_error "ingest missing args"
        [| "chessbuddy"; "ingest"; "--pgn"; "games.pgn" |])

let test_batches_requires_subcommand () =
  Alcotest_lwt.test_case "batches requires subcommand" `Quick (fun _switch () ->
      expect_term_error "batches missing subcommand"
        [| "chessbuddy"; "batches" |])

let test_batches_list_requires_db_uri () =
  Alcotest_lwt.test_case "batches list requires db-uri" `Quick
    (fun _switch () ->
      expect_parse_error "batches list missing db-uri"
        [| "chessbuddy"; "batches"; "list"; "--limit"; "5" |])

let test_batches_show_requires_id () =
  Alcotest_lwt.test_case "batches show requires id" `Quick (fun _switch () ->
      expect_parse_error "batches show missing id"
        [|
          "chessbuddy"; "batches"; "show"; "--db-uri"; "postgresql://example";
        |])

let test_players_sync_requires_db_uri () =
  Alcotest_lwt.test_case "players sync requires db-uri" `Quick
    (fun _switch () ->
      expect_parse_error "players sync missing db-uri"
        [| "chessbuddy"; "players"; "sync"; "--from-pgn"; "games.pgn" |])

let test_players_sync_requires_pgn () =
  Alcotest_lwt.test_case "players sync requires from-pgn" `Quick
    (fun _switch () ->
      expect_parse_error "players sync missing from-pgn"
        [|
          "chessbuddy"; "players"; "sync"; "--db-uri"; "postgresql://example";
        |])

let test_health_requires_db_uri () =
  Alcotest_lwt.test_case "health requires db-uri" `Quick (fun _switch () ->
      expect_parse_error "health missing db-uri"
        [| "chessbuddy"; "health"; "check" |])

let test_help_command_succeeds () =
  Alcotest_lwt.test_case "help command ok" `Quick (fun _switch () ->
      expect_ok "help command" [| "chessbuddy"; "help" |])

let test_help_topic_succeeds () =
  Alcotest_lwt.test_case "help ingest ok" `Quick (fun _switch () ->
      expect_ok "help ingest" [| "chessbuddy"; "help"; "ingest" |])

let test_registered_commands () =
  Alcotest_lwt.test_case "command list" `Quick (fun _switch () ->
      let expected = [ "ingest"; "batches"; "players"; "health"; "help" ] in
      let actual = Ingest_cli.command_names () in
      Alcotest.(check (list string)) "registered commands" expected actual;
      Lwt.return_unit)

let tests =
  [
    test_root_help ();
    test_ingest_help ();
    test_ingest_requires_args ();
    test_batches_requires_subcommand ();
    test_batches_list_requires_db_uri ();
    test_batches_show_requires_id ();
    test_players_sync_requires_db_uri ();
    test_players_sync_requires_pgn ();
    test_health_requires_db_uri ();
    test_help_command_succeeds ();
    test_help_topic_succeeds ();
    test_registered_commands ();
  ]
