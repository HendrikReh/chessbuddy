(* Main test suite runner *)

let () =
  Lwt_main.run
    (Alcotest_lwt.run "ChessBuddy Database Tests"
       [
         ("Database Operations", Test_database.tests);
         ("Vector Operations", Test_vector.tests);
       ])
