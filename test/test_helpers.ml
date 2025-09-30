let ( let* ) = Lwt.bind

let test_db_uri =
  Sys.getenv_opt "CHESSBUDDY_TEST_DB_URI"
  |> Option.value ~default:"postgresql://chess:chess@localhost:5433/chessbuddy"

let require_db_tests =
  match Sys.getenv_opt "CHESSBUDDY_REQUIRE_DB_TESTS" with
  | Some v -> (
      match String.lowercase_ascii (String.trim v) with
      | "1" | "true" | "yes" -> true
      | _ -> false)
  | None -> false

exception Skip_db_tests of string

let pp_skipping reason =
  Format.printf "⚠️  Skipping database-backed tests: %s@." reason

let raise_or_skip err =
  let msg = Format.asprintf "%a" Caqti_error.pp err in
  if require_db_tests then Alcotest.failf "Database error: %s" msg
  else raise (Skip_db_tests msg)

(* Create a test database pool *)
let create_test_pool () =
  let uri = Uri.of_string test_db_uri in
  let pool_config = Caqti_pool_config.create ~max_size:5 () in
  match Caqti_lwt_unix.connect_pool ~pool_config uri with
  | Ok pool -> pool
  | Error err -> raise_or_skip err

(* Execute a query and handle errors *)
let exec_query pool query params =
  let* result = Chessbuddy.Database.Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec query params) in
  match result with
  | Ok () -> Lwt.return_unit
  | Error err -> raise_or_skip err

(* Clean up test data from all tables *)
let cleanup_test_data pool =
  let open Caqti_request.Infix in
  let delete_games_positions = Caqti_type.unit -->. Caqti_type.unit @:- "DELETE FROM games_positions" in
  let delete_game_themes = Caqti_type.unit -->. Caqti_type.unit @:- "DELETE FROM game_themes" in
  let delete_games = Caqti_type.unit -->. Caqti_type.unit @:- "DELETE FROM games" in
  let delete_fen_embeddings = Caqti_type.unit -->. Caqti_type.unit @:- "DELETE FROM fen_embeddings" in
  let delete_fens = Caqti_type.unit -->. Caqti_type.unit @:- "DELETE FROM fens" in
  let delete_ingestion_batches = Caqti_type.unit -->. Caqti_type.unit @:- "DELETE FROM ingestion_batches" in
  let delete_player_ratings = Caqti_type.unit -->. Caqti_type.unit @:- "DELETE FROM player_ratings" in
  let delete_players = Caqti_type.unit -->. Caqti_type.unit @:- "DELETE FROM players" in

  let%lwt () = exec_query pool delete_games_positions () in
  let%lwt () = exec_query pool delete_game_themes () in
  let%lwt () = exec_query pool delete_games () in
  let%lwt () = exec_query pool delete_fen_embeddings () in
  let%lwt () = exec_query pool delete_fens () in
  let%lwt () = exec_query pool delete_ingestion_batches () in
  let%lwt () = exec_query pool delete_player_ratings () in
  let%lwt () = exec_query pool delete_players () in
  Lwt.return_unit

(* Wrapper for tests that need a clean database *)
let with_clean_db f =
  Lwt.catch
    (fun () ->
      let pool = create_test_pool () in
      let%lwt () = cleanup_test_data pool in
      Lwt.finalize
        (fun () -> f pool)
        (fun () -> cleanup_test_data pool))
    (function
      | Skip_db_tests reason ->
          pp_skipping reason;
          Lwt.return_unit
      | exn -> Lwt.fail exn)

(* UUID equality checker for Alcotest *)
let uuid_testable = Alcotest.testable Uuidm.pp Uuidm.equal

(* Result checker for Caqti results *)
let check_ok msg = function
  | Ok v -> v
  | Error err -> Alcotest.failf "%s: %a" msg Caqti_error.pp err

(* Create a sample date *)
let make_date year month day =
  match Ptime.of_date (year, month, day) with
  | Some t -> t
  | None -> Alcotest.fail "Invalid date"
