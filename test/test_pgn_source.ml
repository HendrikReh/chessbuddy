open! Base

let tests =
  [
    Alcotest_lwt.test_case "sanitize preserves unicode" `Quick
      (fun _switch () ->
        let input = "Étienne – ♞" in
        let sanitized = Chessbuddy.Pgn_source.sanitize_utf8 input in
        Alcotest.(check string) "Unicode preserved" input sanitized;
        Lwt.return_unit);
    Alcotest_lwt.test_case "sanitize drops malformed sequences" `Quick
      (fun _switch () ->
        let input = "Bad\xC3 sequence" in
        let sanitized = Chessbuddy.Pgn_source.sanitize_utf8 input in
        Alcotest.(check string)
          "Malformed bytes pruned" "Bad sequence" sanitized;
        Lwt.return_unit);
  ]
