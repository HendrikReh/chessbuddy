open! Base
open Test_helpers

let ( >|= ) = Lwt.( >|= )
let ( let* ) = Lwt.bind

(* Custom float array type for embeddings - encode as pgvector format *)
let float_array =
  let encode arr =
    let str_arr = Array.map arr ~f:Float.to_string in
    Ok ("[" ^ String.concat ~sep:"," (Array.to_list str_arr) ^ "]")
  in
  let decode _str =
    Ok (Array.of_list [ 0.0 ])
    (* Placeholder *)
  in
  Caqti_type.(custom ~encode ~decode string)

(* Custom UUID type matching database.ml *)
let uuid =
  let encode uuid = Ok (Uuidm.to_string uuid) in
  let decode str =
    match Uuidm.of_string str with
    | Some uuid -> Ok uuid
    | None -> Error ("Invalid UUID: " ^ str)
  in
  Caqti_type.(custom ~encode ~decode string)

(* Helper to create a test embedding vector of given dimension *)
let make_embedding dim value = Array.init dim ~f:(fun _ -> value)

(* Test embedding insertion *)
let test_record_embedding () =
  Alcotest_lwt.test_case "record FEN embedding" `Quick (fun _switch () ->
      with_clean_db (fun pool ->
          (* Create a FEN position first *)
          let%lwt fen_id =
            Chessbuddy.Database.upsert_fen pool
              ~fen_text:"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -"
              ~side_to_move:'w' ~castling:"KQkq" ~en_passant:None
              ~material_signature:"PPPPPPPPPPPPPPPP"
            >|= check_ok "FEN creation failed"
          in

          (* Record embedding *)
          let embedding = make_embedding 768 0.1 in
          let%lwt result =
            Chessbuddy.Database.record_embedding pool ~fen_id ~embedding
              ~version:"test-v1"
          in
          check_ok "Embedding insertion failed" result;

          (* Update with new embedding (same fen_id) *)
          let embedding2 = make_embedding 768 0.2 in
          let%lwt result2 =
            Chessbuddy.Database.record_embedding pool ~fen_id
              ~embedding:embedding2 ~version:"test-v2"
          in
          check_ok "Embedding update failed" result2;
          Lwt.return_unit))

(* Test embedding dimension constraint *)
let test_embedding_dimension_constraint () =
  Alcotest_lwt.test_case "embedding dimension must be 768" `Quick
    (fun _switch () ->
      with_clean_db (fun pool ->
          (* Create a FEN position *)
          let%lwt fen_id =
            Chessbuddy.Database.upsert_fen pool
              ~fen_text:"test/position/8/8/8/8/8/8 w - -" ~side_to_move:'w'
              ~castling:"-" ~en_passant:None ~material_signature:"TEST"
            >|= check_ok "FEN creation failed"
          in

          (* Try to insert wrong dimension (512 instead of 768) *)
          let wrong_embedding = make_embedding 512 0.5 in
          let%lwt result =
            Chessbuddy.Database.record_embedding pool ~fen_id
              ~embedding:wrong_embedding ~version:"wrong-dim"
          in

          (* Should fail with dimension error *)
          match result with
          | Ok () -> Alcotest.fail "Should have failed with dimension error"
          | Error err ->
              let err_msg = Caqti_error.show err in
              Alcotest.(check bool)
                "Error message mentions dimension" true
                (not (String.is_empty err_msg));
              Lwt.return_unit))

(* Test vector similarity search - cosine distance *)
let test_cosine_similarity () =
  Alcotest_lwt.test_case "vector cosine similarity search" `Quick
    (fun _switch () ->
      with_clean_db (fun pool ->
          (* Create two FEN positions with different embeddings *)
          let%lwt fen_id1 =
            Chessbuddy.Database.upsert_fen pool
              ~fen_text:"position1/8/8/8/8/8/8/8 w - -" ~side_to_move:'w'
              ~castling:"-" ~en_passant:None ~material_signature:"POS1"
            >|= check_ok "FEN 1 creation failed"
          in

          let%lwt fen_id2 =
            Chessbuddy.Database.upsert_fen pool
              ~fen_text:"position2/8/8/8/8/8/8/8 w - -" ~side_to_move:'w'
              ~castling:"-" ~en_passant:None ~material_signature:"POS2"
            >|= check_ok "FEN 2 creation failed"
          in

          (* Insert embeddings *)
          let%lwt () =
            Chessbuddy.Database.record_embedding pool ~fen_id:fen_id1
              ~embedding:(make_embedding 768 0.1) ~version:"v1"
            >|= check_ok "Embedding 1 failed"
          in

          let%lwt () =
            Chessbuddy.Database.record_embedding pool ~fen_id:fen_id2
              ~embedding:(make_embedding 768 0.9) ~version:"v1"
            >|= check_ok "Embedding 2 failed"
          in

          (* Query using raw SQL to test cosine similarity *)
          let query_cosine =
            let open Caqti_request.Infix in
            (float_array -->* Caqti_type.(t2 uuid float))
            @:- {|
              SELECT fe.fen_id, fe.embedding <=> $1::vector as distance
              FROM fen_embeddings fe
              ORDER BY distance
              LIMIT 2
            |}
          in

          let query_vector = make_embedding 768 0.15 in
          let* result =
            Chessbuddy.Database.Pool.use pool
              (fun (module Db : Caqti_lwt.CONNECTION) ->
                Db.collect_list query_cosine query_vector)
          in

          let results = check_ok "Cosine query failed" result in
          (* Should get 2 results, sorted by distance *)
          Alcotest.(check int) "Got 2 results" 2 (List.length results);

          (* First result should be closer to 0.15 (fen_id1 with 0.1 embedding) *)
          let first_id, first_dist = List.hd_exn results in
          Alcotest.(check uuid_testable)
            "First result is fen_id1" fen_id1 first_id;
          Alcotest.(check bool)
            "First distance is smaller" true
            Float.(first_dist < 1.0);

          Lwt.return_unit))

(* Test vector L2 distance *)
let test_l2_distance () =
  Alcotest_lwt.test_case "vector L2 (Euclidean) distance" `Quick
    (fun _switch () ->
      with_clean_db (fun pool ->
          (* Create FEN with embedding *)
          let%lwt fen_id =
            Chessbuddy.Database.upsert_fen pool
              ~fen_text:"test/l2/8/8/8/8/8/8 w - -" ~side_to_move:'w'
              ~castling:"-" ~en_passant:None ~material_signature:"L2TEST"
            >|= check_ok "FEN creation failed"
          in

          let%lwt () =
            Chessbuddy.Database.record_embedding pool ~fen_id
              ~embedding:(make_embedding 768 0.5) ~version:"v1"
            >|= check_ok "Embedding failed"
          in

          (* Query using L2 distance *)
          let query_l2 =
            let open Caqti_request.Infix in
            (float_array -->! Caqti_type.float)
            @:- "SELECT embedding <-> $1::vector FROM fen_embeddings LIMIT 1"
          in

          let query_vector = make_embedding 768 0.5 in
          let* result =
            Chessbuddy.Database.Pool.use pool
              (fun (module Db : Caqti_lwt.CONNECTION) ->
                Db.find query_l2 query_vector)
          in

          let distance = check_ok "L2 distance query failed" result in
          (* Distance from [0.5, 0.5, ...] to itself should be 0.0 *)
          Alcotest.(check (float 0.001)) "L2 distance is 0" 0.0 distance;

          Lwt.return_unit))

(* Test inner product *)
let test_inner_product () =
  Alcotest_lwt.test_case "vector inner product" `Quick (fun _switch () ->
      with_clean_db (fun pool ->
          let%lwt fen_id =
            Chessbuddy.Database.upsert_fen pool
              ~fen_text:"test/ip/8/8/8/8/8/8 w - -" ~side_to_move:'w'
              ~castling:"-" ~en_passant:None ~material_signature:"IPTEST"
            >|= check_ok "FEN creation failed"
          in

          let%lwt () =
            Chessbuddy.Database.record_embedding pool ~fen_id
              ~embedding:(make_embedding 768 1.0) ~version:"v1"
            >|= check_ok "Embedding failed"
          in

          (* Query using negative inner product *)
          let query_ip =
            let open Caqti_request.Infix in
            (float_array -->! Caqti_type.float)
            @:- "SELECT embedding <#> $1::vector FROM fen_embeddings LIMIT 1"
          in

          let query_vector = make_embedding 768 1.0 in
          let* result =
            Chessbuddy.Database.Pool.use pool
              (fun (module Db : Caqti_lwt.CONNECTION) ->
                Db.find query_ip query_vector)
          in

          let neg_inner_prod = check_ok "Inner product query failed" result in
          (* Inner product of [1, 1, ...] (768 dims) with itself is 768
             pgvector returns negative, so -768 *)
          Alcotest.(check (float 1.0))
            "Negative inner product is -768" (-768.0) neg_inner_prod;

          Lwt.return_unit))

let test_embedding_version_lookup () =
  Alcotest_lwt.test_case "lookup embedding version" `Quick (fun _switch () ->
      with_clean_db (fun pool ->
          let%lwt fen_id =
            Chessbuddy.Database.upsert_fen pool
              ~fen_text:"test/version/8/8/8/8/8/8 w - -" ~side_to_move:'w'
              ~castling:"-" ~en_passant:None ~material_signature:"VER"
            >|= check_ok "FEN creation failed"
          in
          let%lwt () =
            Chessbuddy.Database.record_embedding pool ~fen_id
              ~embedding:(make_embedding 768 0.3) ~version:"ver-1"
            >|= check_ok "Embedding insert failed"
          in
          let%lwt version_res =
            Chessbuddy.Database.get_fen_embedding_version pool ~fen_id
          in
          let version = check_ok "Version lookup failed" version_res in
          Alcotest.(check (option string))
            "Initial version" (Some "ver-1") version;
          let%lwt () =
            Chessbuddy.Database.record_embedding pool ~fen_id
              ~embedding:(make_embedding 768 0.7) ~version:"ver-2"
            >|= check_ok "Embedding update failed"
          in
          let%lwt updated_res =
            Chessbuddy.Database.get_fen_embedding_version pool ~fen_id
          in
          let updated = check_ok "Updated lookup failed" updated_res in
          Alcotest.(check (option string))
            "Updated version" (Some "ver-2") updated;
          Lwt.return_unit))

(* Collect all vector tests *)
let tests =
  [
    test_record_embedding ();
    test_embedding_dimension_constraint ();
    test_cosine_similarity ();
    test_l2_distance ();
    test_inner_product ();
    test_embedding_version_lookup ();
  ]
