open Lwt.Infix
open Test_helpers

(* Test player upsert with FIDE ID *)
let test_upsert_player_with_fide () =
  Alcotest_lwt.test_case "upsert player with FIDE ID" `Quick (fun _switch () ->
      with_clean_db (fun pool ->
          let%lwt result =
            Chessbuddy.Database.upsert_player pool ~full_name:"Magnus Carlsen"
              ~fide_id:(Some "1503014")
          in
          let player_id = check_ok "First upsert failed" result in

          (* Upsert again with different name but same FIDE ID *)
          let%lwt result2 =
            Chessbuddy.Database.upsert_player pool
              ~full_name:"Magnus Carlsen (Updated)" ~fide_id:(Some "1503014")
          in
          let player_id2 = check_ok "Second upsert failed" result2 in

          (* Should return the same UUID *)
          Alcotest.(check uuid_testable)
            "Same player ID for same FIDE ID" player_id player_id2;
          Lwt.return_unit))

(* Test player upsert without FIDE ID *)
let test_upsert_player_without_fide () =
  Alcotest_lwt.test_case "upsert player without FIDE ID" `Quick
    (fun _switch () ->
      with_clean_db (fun pool ->
          let%lwt result =
            Chessbuddy.Database.upsert_player pool ~full_name:"Unknown Player"
              ~fide_id:None
          in
          let player_id = check_ok "First upsert failed" result in

          (* Upsert again with same normalized name *)
          let%lwt result2 =
            Chessbuddy.Database.upsert_player pool
              ~full_name:"UNKNOWN PLAYER" (* Different case *) ~fide_id:None
          in
          let player_id2 = check_ok "Second upsert failed" result2 in

          (* Should return the same UUID due to normalized name matching *)
          Alcotest.(check uuid_testable)
            "Same player ID for normalized name match" player_id player_id2;
          Lwt.return_unit))

(* Test player rating insertion *)
let test_record_rating () =
  Alcotest_lwt.test_case "record player rating" `Quick (fun _switch () ->
      with_clean_db (fun pool ->
          (* First create a player *)
          let%lwt result =
            Chessbuddy.Database.upsert_player pool ~full_name:"Test Player"
              ~fide_id:(Some "999999")
          in
          let player_id = check_ok "Player creation failed" result in

          (* Record a rating *)
          let date = make_date 2024 1 1 in
          let%lwt result =
            Chessbuddy.Database.record_rating pool ~player_id
              ~date:(Ptime.to_date date) ~standard:2800 ~rapid:2750 ()
          in
          check_ok "Rating insertion failed" result;

          (* Insert same rating again (should update due to ON CONFLICT) *)
          let%lwt result2 =
            Chessbuddy.Database.record_rating pool ~player_id
              ~date:(Ptime.to_date date) ~standard:2810 ~rapid:2760 ()
          in
          check_ok "Rating update failed" result2;
          Lwt.return_unit))

(* Test batch creation *)
let test_create_batch () =
  Alcotest_lwt.test_case "create ingestion batch" `Quick (fun _switch () ->
      with_clean_db (fun pool ->
          let%lwt result =
            Chessbuddy.Database.create_batch pool
              ~source_path:"/path/to/test.pgn" ~label:"test-batch"
              ~checksum:"abc123"
          in
          let batch_id = check_ok "Batch creation failed" result in

          (* Create batch with same checksum (should return same ID) *)
          let%lwt result2 =
            Chessbuddy.Database.create_batch pool
              ~source_path:"/path/to/test2.pgn" ~label:"test-batch-updated"
              ~checksum:"abc123"
          in
          let batch_id2 = check_ok "Batch re-creation failed" result2 in

          Alcotest.(check uuid_testable)
            "Same batch ID for same checksum" batch_id batch_id2;
          Lwt.return_unit))

(* Test FEN upsert *)
let test_upsert_fen () =
  Alcotest_lwt.test_case "upsert FEN position" `Quick (fun _switch () ->
      with_clean_db (fun pool ->
          let fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -" in
          let%lwt result =
            Chessbuddy.Database.upsert_fen pool ~fen_text:fen ~side_to_move:'w'
              ~castling:"KQkq" ~en_passant:None
              ~material_signature:"PPPPPPPPPPPPPPPP"
          in
          let fen_id = check_ok "FEN upsert failed" result in

          (* Upsert same FEN again *)
          let%lwt result2 =
            Chessbuddy.Database.upsert_fen pool ~fen_text:fen ~side_to_move:'w'
              ~castling:"KQkq" ~en_passant:None
              ~material_signature:"PPPPPPPPPPPPPPPP"
          in
          let fen_id2 = check_ok "FEN re-upsert failed" result2 in

          Alcotest.(check uuid_testable)
            "Same FEN ID for identical position" fen_id fen_id2;
          Lwt.return_unit))

(* Test game recording *)
let test_record_game () =
  Alcotest_lwt.test_case "record game" `Quick (fun _switch () ->
      with_clean_db (fun pool ->
          (* Create players *)
          let%lwt white_id =
            Chessbuddy.Database.upsert_player pool ~full_name:"White Player"
              ~fide_id:(Some "100001")
            >|= check_ok "White player creation failed"
          in
          let%lwt black_id =
            Chessbuddy.Database.upsert_player pool ~full_name:"Black Player"
              ~fide_id:(Some "100002")
            >|= check_ok "Black player creation failed"
          in

          (* Create batch *)
          let%lwt batch_id =
            Chessbuddy.Database.create_batch pool ~source_path:"/test.pgn"
              ~label:"test" ~checksum:"test123"
            >|= check_ok "Batch creation failed"
          in

          (* Create game header *)
          let header : Chessbuddy.Types.Game_header.t =
            {
              event = Some "Test Tournament";
              site = Some "Test City";
              game_date = Some (make_date 2024 3 15);
              round = Some "1";
              eco = Some "C42";
              opening = Some "Petrov Defense";
              white_player = "White Player";
              black_player = "Black Player";
              white_elo = Some 2500;
              black_elo = Some 2480;
              white_fide_id = Some "12345678";
              black_fide_id = Some "87654321";
              result = "1-0";
              termination = Some "Normal";
            }
          in

          (* Record game *)
          let%lwt result =
            Chessbuddy.Database.record_game pool ~white_id ~black_id ~header
              ~source_pgn:"1. e4 e5 2. Nf3 1-0" ~batch_id
          in
          let _game_id = check_ok "Game recording failed" result in
          Lwt.return_unit))

(* Collect all database tests *)
let tests =
  [
    test_upsert_player_with_fide ();
    test_upsert_player_without_fide ();
    test_record_rating ();
    test_create_batch ();
    test_upsert_fen ();
    test_record_game ();
  ]
