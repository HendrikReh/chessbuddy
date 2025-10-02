open! Base

(* Main test suite runner *)

let () =
  Lwt_main.run
    (Alcotest_lwt.run "ChessBuddy Database Tests"
       [
         ("Database Operations", Test_database.tests);
         ("Vector Operations", Test_vector.tests);
         ("PGN Source", Test_pgn_source.tests);
         ("Search Service", Test_search_service.tests);
         ("Retrieve CLI", Test_retrieve_cli.tests);
         ("Ingest CLI", Test_ingest_cli.tests);
         ("Chess Engine", Test_chess_engine.tests);
       ])
