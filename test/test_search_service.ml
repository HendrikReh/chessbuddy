open! Base
open Test_helpers
open Chessbuddy

module Stub_embedder = struct
  let model = "stub-test"
  let vector_dim = 1536
  let keywords = [ "magnus"; "hikaru"; "tactics"; "endgame" ]

  let embed ~text =
    let normalized = text |> String.strip |> String.lowercase in
    let embedding = Array.create ~len:vector_dim 0. in
    List.iteri keywords ~f:(fun idx keyword ->
        if String.is_substring normalized ~substring:keyword then
          Array.set embedding idx 1.0);
    Lwt.return (Ok embedding)
end

let embedder = (module Stub_embedder : Search_indexer.TEXT_EMBEDDER)

let uuid_of_string s =
  match Uuidm.of_string s with
  | Some uuid -> uuid
  | None -> Alcotest.failf "invalid UUID literal: %s" s

let test_entity_filters () =
  Alcotest_lwt.test_case "ensure entity filters" `Quick (fun _switch () ->
      let default_filters =
        match Search_service.ensure_entity_filters [] with
        | Ok filters -> filters
        | Error msg -> Alcotest.fail msg
      in
      let available = Search_service.available_entity_names () in
      Alcotest.(check (list string))
        "default matches available" available default_filters;

      let normalized_filters =
        match
          Search_service.ensure_entity_filters [ "PLAYER"; "fen"; "player" ]
        with
        | Ok filters -> filters
        | Error msg -> Alcotest.fail msg
      in
      Alcotest.(check (list string))
        "case-insensitive dedupe"
        [ Search_indexer.entity_type_player; Search_indexer.entity_type_fen ]
        normalized_filters;

      (match Search_service.ensure_entity_filters [ "unknown" ] with
      | Ok _ -> Alcotest.fail "expected validation failure for unknown entity"
      | Error msg ->
          Alcotest.(check bool)
            "error mentions unknown" true
            (String.is_substring msg ~substring:"unknown"));
      Lwt.return_unit)

let test_search_prioritises_relevant_matches () =
  Alcotest_lwt.test_case "search ranks relevant hits" `Quick (fun _switch () ->
      with_clean_db (fun pool ->
          let* () = Search_indexer.ensure_tables pool in
          let magnus_id =
            uuid_of_string "00000000-0000-0000-0000-000000000001"
          in
          let hikaru_id =
            uuid_of_string "00000000-0000-0000-0000-000000000002"
          in
          let game_id = uuid_of_string "00000000-0000-0000-0000-000000000003" in

          let* () =
            Search_indexer.index_player pool ~player_id:magnus_id
              ~name:"Magnus Carlsen" ~fide_id:(Some "1503014")
              ~embedder:(Some embedder)
          in
          let* () =
            Search_indexer.index_player pool ~player_id:hikaru_id
              ~name:"Hikaru Nakamura" ~fide_id:(Some "125777")
              ~embedder:(Some embedder)
          in
          let game =
            {
              Types.Game.header =
                {
                  event = Some "Magnus prepares tactical endgame surprises";
                  site = None;
                  game_date = None;
                  round = None;
                  eco = None;
                  opening = None;
                  termination = None;
                  white_player = "Magnus";
                  black_player = "Test";
                  result = "*";
                  white_elo = None;
                  black_elo = None;
                  white_fide_id = None;
                  black_fide_id = None;
                };
              moves = [];
              source_pgn = "";
            }
          in
          let* () =
            Search_indexer.index_game pool ~game_id ~game
              ~batch_label:"test-batch" ~source_path:"test.pgn"
              ~embedder:(Some embedder)
          in

          let player_filters =
            match Search_service.ensure_entity_filters [ "player" ] with
            | Ok filters -> filters
            | Error msg -> Alcotest.fail msg
          in
          let* player_hits =
            Search_service.search pool ~embedder ~query:"Magnus tactics"
              ~entity_filters:player_filters ~limit:5
          in
          Alcotest.(check int) "player result count" 2 (List.length player_hits);
          List.iter player_hits ~f:(fun hit ->
              Alcotest.(check string)
                "player entity type" Search_indexer.entity_type_player
                hit.Database.entity_type);
          let top_hit = List.hd_exn player_hits in
          Alcotest.(check uuid_testable)
            "best match is Magnus" magnus_id top_hit.Database.entity_id;

          let all_filters =
            match Search_service.ensure_entity_filters [] with
            | Ok filters -> filters
            | Error msg -> Alcotest.fail msg
          in
          let* all_hits =
            Search_service.search pool ~embedder ~query:"Magnus tactics"
              ~entity_filters:all_filters ~limit:5
          in
          Alcotest.(check int) "all result count" 3 (List.length all_hits);
          Alcotest.(check bool)
            "includes game result" true
            (List.exists all_hits ~f:(fun hit ->
                 String.equal hit.Database.entity_type
                   Search_indexer.entity_type_game));
          Lwt.return_unit))

let tests =
  [ test_entity_filters (); test_search_prioritises_relevant_matches () ]
