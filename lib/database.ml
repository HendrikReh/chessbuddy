open Lwt.Infix

let ( let+ ) = Lwt.map
let ( let* ) = Lwt.bind

module Pool = struct
  type t = (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt.Pool.t

  let create ?(max_size = 10) uri =
    Caqti_lwt.connect_pool ~max_size uri

  let use t f = Caqti_lwt.Pool.use f t
end

let normalize_name name =
  String.trim name |> String.lowercase_ascii

let find_player_by_fide_query =
  Caqti_request.find_optional
    Caqti_type.string
    Caqti_type.uuid
    "SELECT player_id FROM players WHERE fide_id = $1"

let find_player_by_name_query =
  Caqti_request.find_optional
    Caqti_type.string
    Caqti_type.uuid
    "SELECT player_id FROM players WHERE full_name_key = $1"

let insert_player_query =
  Caqti_request.find
    Caqti_type.(tup2 string (option string))
    Caqti_type.uuid
    "INSERT INTO players (full_name, fide_id) VALUES ($1, $2)
     ON CONFLICT (fide_id) DO UPDATE SET full_name = EXCLUDED.full_name
     RETURNING player_id"

let insert_player_without_fide_query =
  Caqti_request.find
    Caqti_type.string
    Caqti_type.uuid
    "INSERT INTO players (full_name) VALUES ($1)
     ON CONFLICT (full_name_key) DO UPDATE SET full_name = EXCLUDED.full_name
     RETURNING player_id"

let upsert_player pool ~(full_name : string) ~(fide_id : string option) =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      match fide_id with
      | Some fide ->
          let* existing = Db.find_optional find_player_by_fide_query fide in
          (match existing with
          | Some id -> Lwt.return_ok id
          | None -> Db.find insert_player_query (full_name, Some fide))
      | None ->
          let* existing =
            Db.find_optional find_player_by_name_query (normalize_name full_name)
          in
          (match existing with
          | Some id -> Lwt.return_ok id
          | None -> Db.find insert_player_without_fide_query full_name))
  )

let insert_rating_query =
  Caqti_request.exec
    Caqti_type.(tup4 uuid date (option int) (option int))
    "INSERT INTO player_ratings (player_id, rating_date, standard_elo, rapid_elo)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (player_id, rating_date) DO UPDATE
     SET standard_elo = EXCLUDED.standard_elo,
         rapid_elo = EXCLUDED.rapid_elo"

let record_rating pool ~player_id ~date ?standard ?rapid () =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec insert_rating_query (player_id, date, standard, rapid))

let insert_batch_query =
  Caqti_request.find
    Caqti_type.(tup3 string string string)
    Caqti_type.uuid
    "INSERT INTO ingestion_batches (source_path, label, checksum)
     VALUES ($1, $2, $3)
     ON CONFLICT (checksum) DO UPDATE SET source_path = EXCLUDED.source_path,
                                         label = EXCLUDED.label
     RETURNING batch_id"

let create_batch pool ~source_path ~label ~checksum =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find insert_batch_query (source_path, label, checksum))

let insert_game_query =
  let open Caqti_type in
  let header_type = tup4 (option string) (option string) (option date) (option string) in
  let opening_type = tup4 (option string) (option string) (option int) (option int) in
  let tail_type = tup4 string (option string) string uuid in
  Caqti_request.find
    (tup4 uuid uuid (tup2 header_type opening_type) tail_type)
    uuid
    "INSERT INTO games (white_id, black_id, event, site, game_date, round, eco_code,
                        opening_name, white_elo, black_elo, result, termination,
                        source_pgn, ingestion_batch)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
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
  Caqti_request.find
    Caqti_type.(tup5 string string string (option string) string)
    Caqti_type.uuid
    "INSERT INTO fens (fen_text, side_to_move, castling_rights, en_passant_file, material_signature)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (fen_text) DO UPDATE SET fen_text = EXCLUDED.fen_text
     RETURNING fen_id"

let insert_game_position_query =
  let open Caqti_type in
  let header_type = tup5 uuid int uuid string string in
  let body_type = tup4 (option string) string string (option string) in
  let state_type = tup3 (option int) bool bool in
  let tail_type = tup2 bool (array string) in
  Caqti_request.exec
    (tup4 header_type body_type state_type tail_type)
    "INSERT INTO games_positions (game_id, ply_number, fen_id, side_to_move, san, uci,
                                  fen_before, fen_after, clock, eval_cp, is_capture,
                                  is_check, is_mate, motif_flags)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
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
  Caqti_request.exec
    Caqti_type.(tup3 uuid (array float) string)
    "INSERT INTO fen_embeddings (fen_id, embedding, embedding_version)
     VALUES ($1, $2, $3)
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
