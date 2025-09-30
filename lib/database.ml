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
    let escaped = Array.map (fun s -> "\"" ^ String.escaped s ^ "\"") arr in
    Ok ("{" ^ String.concat "," (Array.to_list escaped) ^ "}")
  in
  let decode str =
    (* Simple decode - just pass through PostgreSQL array string *)
    (* For full decode, we'd need to parse PostgreSQL array syntax *)
    Ok (Array.of_list [str]) (* Placeholder *)
  in
  Caqti_type.(custom ~encode ~decode string)

(* Custom float array for embeddings - encode as pgvector format *)
let float_array =
  let encode arr =
    let str_arr = Array.map string_of_float arr in
    Ok ("[" ^ String.concat "," (Array.to_list str_arr) ^ "]")
  in
  let decode _str =
    (* Simple passthrough for now *)
    Ok (Array.of_list [0.0]) (* Placeholder *)
  in
  Caqti_type.(custom ~encode ~decode string)

module Pool = struct
  type t = (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t

  let create ?(max_size = 10) uri =
    let pool_config = Caqti_pool_config.create ~max_size () in
    Caqti_lwt_unix.connect_pool ~pool_config uri

  let use t f = Caqti_lwt_unix.Pool.use f t
end

let normalize_name name =
  String.trim name |> String.lowercase_ascii

let find_player_by_fide_query =
  let open Caqti_request.Infix in
  Caqti_type.string -->? uuid @:-
  "SELECT player_id FROM players WHERE fide_id = ?"

let find_player_by_name_query =
  let open Caqti_request.Infix in
  Caqti_type.string -->? uuid @:-
  "SELECT player_id FROM players WHERE full_name_key = ?"

let insert_player_query =
  let open Caqti_request.Infix in
  Caqti_type.(t2 string (option string)) -->! uuid @:-
  "INSERT INTO players (full_name, fide_id) VALUES (?, ?)
   ON CONFLICT (fide_id) DO UPDATE SET full_name = EXCLUDED.full_name
   RETURNING player_id"

let insert_player_without_fide_query =
  let open Caqti_request.Infix in
  Caqti_type.string -->! uuid @:-
  "INSERT INTO players (full_name) VALUES (?)
   ON CONFLICT (full_name_key) DO UPDATE SET full_name = EXCLUDED.full_name
   RETURNING player_id"

let upsert_player pool ~(full_name : string) ~(fide_id : string option) =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      match fide_id with
      | Some fide ->
          let* existing = Db.find_opt find_player_by_fide_query fide in
          (match existing with
          | Ok (Some id) -> Lwt.return_ok id
          | Ok None -> Db.find insert_player_query (full_name, Some fide)
          | Error _ as err -> Lwt.return err)
      | None ->
          let* existing =
            Db.find_opt find_player_by_name_query (normalize_name full_name)
          in
          match existing with
          | Ok (Some id) -> Lwt.return_ok id
          | Ok None -> Db.find insert_player_without_fide_query full_name
          | Error _ as err -> Lwt.return err)

let insert_rating_query =
  let open Caqti_request.Infix in
  Caqti_type.(t4 uuid date (option int) (option int)) -->. Caqti_type.unit @:-
  "INSERT INTO player_ratings (player_id, rating_date, standard_elo, rapid_elo)
   VALUES (?, ?, ?, ?)
   ON CONFLICT (player_id, rating_date) DO UPDATE
   SET standard_elo = EXCLUDED.standard_elo,
       rapid_elo = EXCLUDED.rapid_elo"

let record_rating pool ~player_id ~date ?standard ?rapid () =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec insert_rating_query (player_id, date, standard, rapid))

let insert_batch_query =
  let open Caqti_request.Infix in
  Caqti_type.(t3 string string string) -->! uuid @:-
  "INSERT INTO ingestion_batches (source_path, label, checksum)
   VALUES (?, ?, ?)
   ON CONFLICT (checksum) DO UPDATE SET source_path = EXCLUDED.source_path,
                                       label = EXCLUDED.label
   RETURNING batch_id"

let create_batch pool ~source_path ~label ~checksum =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find insert_batch_query (source_path, label, checksum))

let insert_game_query =
  let open Caqti_request.Infix in
  let open Caqti_type in
  let header_type = t4 (option string) (option string) (option date) (option string) in
  let opening_type = t4 (option string) (option string) (option int) (option int) in
  let tail_type = t4 string (option string) string uuid in
  t4 uuid uuid (t2 header_type opening_type) tail_type -->! uuid @:-
  "INSERT INTO games (white_id, black_id, event, site, game_date, round, eco_code,
                      opening_name, white_elo, black_elo, result, termination,
                      source_pgn, ingestion_batch)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
   RETURNING game_id"

let record_game pool ~white_id ~black_id ~(header : Types.Game_header.t) ~source_pgn ~batch_id =
  let game_date = Option.map Ptime.to_date header.game_date in
  let header_data = (header.event, header.site, game_date, header.round) in
  let opening_data = (header.eco, header.opening, header.white_elo, header.black_elo) in
  let tail_data = (header.result, header.termination, source_pgn, batch_id) in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find insert_game_query
        (white_id, black_id, (header_data, opening_data), tail_data))

let insert_fen_query =
  let open Caqti_request.Infix in
  Caqti_type.(t5 string string string (option string) string) -->! uuid @:-
  "INSERT INTO fens (fen_text, side_to_move, castling_rights, en_passant_file, material_signature)
   VALUES (?, ?, ?, ?, ?)
   ON CONFLICT (fen_text) DO UPDATE SET fen_text = EXCLUDED.fen_text
   RETURNING fen_id"

let insert_game_position_query =
  let open Caqti_request.Infix in
  let open Caqti_type in
  let header_type = t5 uuid int uuid string string in
  let body_type = t4 (option string) string string (option string) in
  let state_type = t3 (option int) bool bool in
  let tail_type = t2 bool string_array in
  t4 header_type body_type state_type tail_type -->. Caqti_type.unit @:-
  "INSERT INTO games_positions (game_id, ply_number, fen_id, side_to_move, san, uci,
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
       motif_flags = EXCLUDED.motif_flags"

let insert_embedding_query =
  let open Caqti_request.Infix in
  Caqti_type.(t3 uuid float_array string) -->. Caqti_type.unit @:-
  "INSERT INTO fen_embeddings (fen_id, embedding, embedding_version)
   VALUES (?, ?, ?)
   ON CONFLICT (fen_id) DO UPDATE
   SET embedding = EXCLUDED.embedding,
       embedding_version = EXCLUDED.embedding_version"

let upsert_fen pool ~(fen_text : string) ~(side_to_move : char) ~(castling : string)
    ~(en_passant : string option) ~(material_signature : string) =
  let params =
    ( fen_text
    , String.make 1 side_to_move
    , castling
    , en_passant
    , material_signature )
  in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find insert_fen_query params)

let record_position pool ~game_id ~(move : Types.Move_feature.t) ~fen_id =
  let header =
    ( game_id
    , move.ply_number
    , fen_id
    , String.make 1 move.side_to_move
    , move.san )
  in
  let body =
    ( move.uci
    , move.fen_before
    , move.fen_after
    , None )
  in
  let state = (move.eval_cp, move.is_capture, move.is_check) in
  let tail = (move.is_mate, Array.of_list move.motifs) in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec insert_game_position_query (header, body, state, tail))

let record_embedding pool ~fen_id ~embedding ~version =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec insert_embedding_query (fen_id, embedding, version))