open! Base

let eval argv = Retrieve_cli.eval_value ~argv ()

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

let test_root_help () =
  Alcotest_lwt.test_case "--help at root" `Quick (fun _switch () ->
      expect_help "root help" [| "retrieve"; "--help" |])

let test_similar_help () =
  Alcotest_lwt.test_case "similar --help" `Quick (fun _switch () ->
      expect_help "similar help" [| "retrieve"; "similar"; "--help" |])

let test_similar_requires_fen () =
  Alcotest_lwt.test_case "similar requires --fen" `Quick (fun _switch () ->
      expect_parse_error "similar missing fen"
        [| "retrieve"; "similar"; "--db-uri"; "postgresql://example" |])

let test_game_requires_id () =
  Alcotest_lwt.test_case "game requires --id" `Quick (fun _switch () ->
      expect_parse_error "game missing id"
        [| "retrieve"; "game"; "--db-uri"; "postgresql://example" |])

let test_games_help () =
  Alcotest_lwt.test_case "games --help" `Quick (fun _switch () ->
      expect_help "games help" [| "retrieve"; "games"; "--help" |])

let test_games_require_db_uri () =
  Alcotest_lwt.test_case "games requires db-uri" `Quick (fun _switch () ->
      expect_parse_error "games missing db-uri" [| "retrieve"; "games" |])

let test_registered_commands () =
  Alcotest_lwt.test_case "command list" `Quick (fun _switch () ->
      let expected =
        [ "similar"; "game"; "games"; "fen"; "player"; "batch"; "export" ]
      in
      let actual = Retrieve_cli.command_names () in
      Alcotest.(check (list string)) "registered commands" expected actual;
      Lwt.return_unit)

let tests =
  [
    test_root_help ();
    test_similar_help ();
    test_similar_requires_fen ();
    test_game_requires_id ();
    test_games_help ();
    test_games_require_db_uri ();
    test_registered_commands ();
  ]
