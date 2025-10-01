open! Base

let ( let+ ) = Lwt.map
let ( let* ) = Lwt.bind

(* Custom UUID type for Caqti 2.x *)
let uuid =
  let encode uuid = Ok (Uuidm.to_string uuid) in
  let decode str =
    match Uuidm.of_string str with
    | Some uuid -> Ok uuid
    | None -> Error ("Invalid UUID: " ^ str)
  in
  Caqti_type.(custom ~encode ~decode string)

(* Custom date type for (year, month, day) tuples *)
let date =
  let encode (y, m, d) =
    match Ptime.of_date (y, m, d) with
    | Some pt -> Ok pt
    | None -> Error "Invalid date"
  in
  let decode pt = Ok (Ptime.to_date pt) in
  Caqti_type.(custom ~encode ~decode pdate)

(* Custom array type for string arrays (PostgreSQL text[]) *)
let string_array =
  let encode arr =
    (* Encode as PostgreSQL array: {elem1,elem2,...} *)
    let escaped =
      Array.map arr ~f:(fun s -> "\"" ^ Stdlib.String.escaped s ^ "\"")
    in
    Ok ("{" ^ String.concat ~sep:"," (Array.to_list escaped) ^ "}")
  in
  let decode str =
    (* Simple decode - just pass through PostgreSQL array string *)
    (* For full decode, we'd need to parse PostgreSQL array syntax *)
    Ok (Array.of_list [ str ])
    (* Placeholder *)
  in
  Caqti_type.(custom ~encode ~decode string)

(* Custom float array for embeddings - encode as pgvector format *)
let float_array =
  let encode arr =
    let str_arr = Array.map arr ~f:Float.to_string in
    Ok ("[" ^ String.concat ~sep:"," (Array.to_list str_arr) ^ "]")
  in
  let decode _str =
    (* Simple passthrough for now *)
    Ok (Array.of_list [ 0.0 ])
    (* Placeholder *)
  in
  Caqti_type.(custom ~encode ~decode string)

module Pool = struct
  type t = (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t

  let create ?(max_size = 10) uri =
    let pool_config = Caqti_pool_config.create ~max_size () in
    Caqti_lwt_unix.connect_pool ~pool_config uri

  let use t f = Caqti_lwt_unix.Pool.use f t
end

(* High-level projections for CLI reporting. *)
type batch_overview = {
  batch_id : Uuidm.t;
  label : string;
  source_path : string;
  checksum : string;
  ingested_at : Ptime.t;
}

type batch_summary = {
  overview : batch_overview;
  games_count : int;
  position_count : int;
  unique_fens : int;
  embedding_count : int;
}

type health_report = {
  server_version : string;
  database_name : string;
  extensions : (string * bool) list;
}

let or_fail = function
  | Ok v -> Lwt.return v
  | Error err -> Lwt.fail_with (Caqti_error.show err)

let normalize_name name = String.strip name |> String.lowercase

let find_player_by_fide_query =
  let open Caqti_request.Infix in
  (Caqti_type.string -->? uuid)
  @:- "SELECT player_id FROM players WHERE fide_id = ?"

let find_player_by_name_query =
  let open Caqti_request.Infix in
  (Caqti_type.string -->? uuid)
  @:- "SELECT player_id FROM players WHERE full_name_key = ?"

let insert_player_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string (option string)) -->! uuid)
  @:- {sql|
   INSERT INTO players (full_name, fide_id) VALUES (?, ?)
   ON CONFLICT (fide_id) DO UPDATE SET full_name = EXCLUDED.full_name
   RETURNING player_id
  |sql}

let insert_player_without_fide_query =
  let open Caqti_request.Infix in
  (Caqti_type.string -->! uuid)
  @:- {sql|
   INSERT INTO players (full_name) VALUES (?)
   ON CONFLICT (full_name_key) DO UPDATE SET full_name = EXCLUDED.full_name
   RETURNING player_id
  |sql}

let upsert_player pool ~(full_name : string) ~(fide_id : string option) =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      match fide_id with
      | Some fide -> (
          let* existing = Db.find_opt find_player_by_fide_query fide in
          match existing with
          | Ok (Some id) -> Lwt.return_ok id
          | Ok None -> Db.find insert_player_query (full_name, Some fide)
          | Error _ as err -> Lwt.return err)
      | None -> (
          let* existing =
            Db.find_opt find_player_by_name_query (normalize_name full_name)
          in
          match existing with
          | Ok (Some id) -> Lwt.return_ok id
          | Ok None -> Db.find insert_player_without_fide_query full_name
          | Error _ as err -> Lwt.return err))

let insert_rating_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t4 uuid date (option int) (option int)) -->. Caqti_type.unit)
  @:- {sql|
   INSERT INTO player_ratings (player_id, rating_date, standard_elo, rapid_elo)
   VALUES (?, ?, ?, ?)
   ON CONFLICT (player_id, rating_date) DO UPDATE
   SET standard_elo = EXCLUDED.standard_elo,
       rapid_elo = EXCLUDED.rapid_elo
  |sql}

let record_rating pool ~player_id ~date ?standard ?rapid () =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec insert_rating_query (player_id, date, standard, rapid))

let insert_batch_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 string string string) -->! uuid)
  @:- {sql|
   INSERT INTO ingestion_batches (source_path, label, checksum)
   VALUES (?, ?, ?)
   ON CONFLICT (checksum) DO UPDATE SET source_path = EXCLUDED.source_path,
                                       label = EXCLUDED.label
   RETURNING batch_id
  |sql}

let create_batch pool ~source_path ~label ~checksum =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find insert_batch_query (source_path, label, checksum))

let insert_game_query =
  let open Caqti_request.Infix in
  let open Caqti_type in
  let header_type =
    t4 (option string) (option string) (option date) (option string)
  in
  let opening_type =
    t4 (option string) (option string) (option int) (option int)
  in
  let tail_type = t4 string (option string) string uuid in
  (t4 uuid uuid (t2 header_type opening_type) tail_type -->! uuid)
  @:- {sql|
   INSERT INTO games (white_id, black_id, event, site, game_date, round, eco_code,
                      opening_name, white_elo, black_elo, result, termination,
                      source_pgn, ingestion_batch)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
   ON CONFLICT (white_id, black_id, game_date, round, pgn_hash) DO UPDATE
     SET source_pgn = EXCLUDED.source_pgn, ingestion_batch = EXCLUDED.ingestion_batch
   RETURNING game_id
  |sql}

let record_game pool ~white_id ~black_id ~(header : Types.Game_header.t)
    ~source_pgn ~batch_id =
  let game_date = Option.map header.game_date ~f:Ptime.to_date in
  let header_data = (header.event, header.site, game_date, header.round) in
  let opening_data =
    (header.eco, header.opening, header.white_elo, header.black_elo)
  in
  let tail_data = (header.result, header.termination, source_pgn, batch_id) in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find insert_game_query
        (white_id, black_id, (header_data, opening_data), tail_data))

let insert_fen_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t5 string string string (option string) string) -->! uuid)
  @:- {sql|
   INSERT INTO fens (fen_text, side_to_move, castling_rights, en_passant_file, material_signature)
   VALUES (?, ?, ?, ?, ?)
   ON CONFLICT (fen_text) DO UPDATE SET fen_text = EXCLUDED.fen_text
   RETURNING fen_id
  |sql}

let insert_game_position_query =
  let open Caqti_request.Infix in
  let open Caqti_type in
  let header_type = t5 uuid int uuid string string in
  let body_type = t4 (option string) string string (option string) in
  let state_type = t3 (option int) bool bool in
  let tail_type = t2 bool string_array in
  (t4 header_type body_type state_type tail_type -->. Caqti_type.unit)
  @:- {sql|
   INSERT INTO games_positions (game_id, ply_number, fen_id, side_to_move, san, uci,
                                fen_before, fen_after, clock, eval_cp, is_capture,
                                is_check, is_mate, motif_flags)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
   ON CONFLICT (game_id, ply_number) DO UPDATE
   SET fen_id = EXCLUDED.fen_id,
       san = EXCLUDED.san,
       uci = EXCLUDED.uci,
       fen_before = EXCLUDED.fen_before,
       fen_after = EXCLUDED.fen_after,
       eval_cp = EXCLUDED.eval_cp,
       is_capture = EXCLUDED.is_capture,
       is_check = EXCLUDED.is_check,
       is_mate = EXCLUDED.is_mate,
       motif_flags = EXCLUDED.motif_flags
  |sql}

let insert_embedding_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 uuid float_array string) -->. Caqti_type.unit)
  @:- {sql|
   INSERT INTO fen_embeddings (fen_id, embedding, embedding_version)
   VALUES (?, ?, ?)
   ON CONFLICT (fen_id) DO UPDATE
   SET embedding = EXCLUDED.embedding,
       embedding_version = EXCLUDED.embedding_version
  |sql}

let upsert_fen pool ~(fen_text : string) ~(side_to_move : char)
    ~(castling : string) ~(en_passant : string option)
    ~(material_signature : string) =
  let params =
    ( fen_text,
      String.of_char side_to_move,
      castling,
      en_passant,
      material_signature )
  in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find insert_fen_query params)

let record_position pool ~game_id ~(move : Types.Move_feature.t) ~fen_id
    ~side_to_move =
  let header =
    (game_id, move.ply_number, fen_id, String.of_char side_to_move, move.san)
  in
  let body = (move.uci, move.fen_before, move.fen_after, None) in
  let state = (move.eval_cp, move.is_capture, move.is_check) in
  let tail = (move.is_mate, Array.of_list move.motifs) in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec insert_game_position_query (header, body, state, tail))

let record_embedding pool ~fen_id ~embedding ~version =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec insert_embedding_query (fen_id, embedding, version))

let list_batches_query =
  let open Caqti_request.Infix in
  (Caqti_type.int -->* Caqti_type.(t5 uuid string string string ptime))
  @:- {sql|
   SELECT batch_id, label, source_path, checksum, ingested_at
   FROM ingestion_batches
   ORDER BY ingested_at DESC
   LIMIT ?
  |sql}

let fetch_batch_query =
  let open Caqti_request.Infix in
  (uuid -->? Caqti_type.(t4 string string string ptime))
  @:- {sql|
   SELECT label, source_path, checksum, ingested_at
   FROM ingestion_batches
   WHERE batch_id = ?
  |sql}

let count_games_query =
  let open Caqti_request.Infix in
  (uuid -->! Caqti_type.int)
  @:- {sql|
   SELECT COUNT(*)::int
   FROM games
   WHERE ingestion_batch = ?
  |sql}

let count_positions_query =
  let open Caqti_request.Infix in
  (uuid -->! Caqti_type.int)
  @:- {sql|
   SELECT COUNT(*)::int
   FROM games_positions gp
   JOIN games g ON gp.game_id = g.game_id
   WHERE g.ingestion_batch = ?
  |sql}

let count_unique_fens_query =
  let open Caqti_request.Infix in
  (uuid -->! Caqti_type.int)
  @:- {sql|
   SELECT COUNT(DISTINCT gp.fen_id)::int
   FROM games_positions gp
   JOIN games g ON gp.game_id = g.game_id
   WHERE g.ingestion_batch = ?
  |sql}

let count_embeddings_query =
  let open Caqti_request.Infix in
  (uuid -->! Caqti_type.int)
  @:- {sql|
   SELECT COUNT(DISTINCT fe.fen_id)::int
   FROM fen_embeddings fe
   JOIN games_positions gp ON gp.fen_id = fe.fen_id
   JOIN games g ON gp.game_id = g.game_id
   WHERE g.ingestion_batch = ?
  |sql}

let server_info_query =
  let open Caqti_request.Infix in
  (Caqti_type.unit -->! Caqti_type.(t2 string string))
  @:- {sql|
   SELECT current_setting('server_version'), current_database()
  |sql}

let extension_exists_query =
  let open Caqti_request.Infix in
  (Caqti_type.string -->! Caqti_type.bool)
  @:- {sql|
   SELECT EXISTS (
     SELECT 1 FROM pg_extension WHERE extname = ?
   )
  |sql}

let list_batches pool ~limit =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let* rows_res = Db.collect_list list_batches_query limit in
      Lwt.return
        (Result.map rows_res ~f:(fun rows ->
             List.map rows
               ~f:(fun (batch_id, label, source_path, checksum, ingested_at) ->
                 { batch_id; label; source_path; checksum; ingested_at }))))

let get_batch_summary pool ~batch_id =
  let bind_result res f =
    match res with Ok v -> f v | Error err -> Lwt.return (Error err)
  in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let open Lwt.Infix in
      Db.find_opt fetch_batch_query batch_id >>= fun overview_res ->
      bind_result overview_res (function
        | None -> Lwt.return (Ok None)
        | Some (label, source_path, checksum, ingested_at) ->
            let overview =
              { batch_id; label; source_path; checksum; ingested_at }
            in
            Db.find count_games_query batch_id >>= fun games_res ->
            bind_result games_res (fun games_count ->
                Db.find count_positions_query batch_id >>= fun positions_res ->
                bind_result positions_res (fun position_count ->
                    Db.find count_unique_fens_query batch_id >>= fun fens_res ->
                    bind_result fens_res (fun unique_fens ->
                        Db.find count_embeddings_query batch_id
                        >>= fun embeddings_res ->
                        bind_result embeddings_res (fun embedding_count ->
                            Lwt.return
                              (Ok
                                 (Some
                                    {
                                      overview;
                                      games_count;
                                      position_count;
                                      unique_fens;
                                      embedding_count;
                                    }))))))))

let health_check ?(extensions = [ "vector"; "pgcrypto"; "uuid-ossp" ]) pool =
  let bind_result res f =
    match res with Ok v -> f v | Error err -> Lwt.return (Error err)
  in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let open Lwt.Infix in
      Db.find server_info_query () >>= fun info_res ->
      bind_result info_res (fun (server_version, database_name) ->
          let rec gather acc = function
            | [] -> Lwt.return (Ok (List.rev acc))
            | ext :: rest ->
                Db.find extension_exists_query ext >>= fun exists_res ->
                bind_result exists_res (fun exists ->
                    gather ((ext, exists) :: acc) rest)
          in
          gather [] extensions >>= fun extensions_res ->
          bind_result extensions_res (fun extensions ->
              Lwt.return (Ok { server_version; database_name; extensions }))))
