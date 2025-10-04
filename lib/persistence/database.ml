(** Database persistence layer implementation.

    See {!module:Database} for public API documentation. This module uses Caqti
    2.x for type-safe database queries and custom encoders for
    PostgreSQL-specific types (UUIDs, arrays, pgvector). *)

open! Base

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
  let escape_element element =
    let buf = Stdlib.Buffer.create (String.length element) in
    String.iter element ~f:(fun ch ->
        (match ch with
        | '"' | '\\' -> Stdlib.Buffer.add_char buf '\\'
        | _ -> ());
        Stdlib.Buffer.add_char buf ch);
    Stdlib.Buffer.contents buf
  in
  let encode arr =
    let elements =
      arr |> Array.to_list
      |> List.map ~f:(fun element -> "\"" ^ escape_element element ^ "\"")
    in
    Ok ("{" ^ String.concat ~sep:"," elements ^ "}")
  in
  let decode str =
    let len = String.length str in
    if
      len < 2
      || (not (Char.equal (String.get str 0) '{'))
      || not (Char.equal (String.get str (len - 1)) '}')
    then Ok (Array.of_list [ str ])
    else
      let content = String.sub str ~pos:1 ~len:(len - 2) in
      let buf = Stdlib.Buffer.create 32 in
      let add_current value_started acc =
        let value = Stdlib.Buffer.contents buf in
        Stdlib.Buffer.clear buf;
        if (not value_started) && String.is_empty value then acc
        else value :: acc
      in
      let rec loop i in_quotes escaped value_started acc =
        if i >= String.length content then
          let acc =
            if in_quotes then acc
            else if value_started || Stdlib.Buffer.length buf > 0 then
              add_current value_started acc
            else acc
          in
          Ok (Array.of_list (List.rev acc))
        else
          let ch = String.get content i in
          if escaped then (
            Stdlib.Buffer.add_char buf ch;
            loop (i + 1) in_quotes false true acc)
          else if in_quotes then (
            match ch with
            | '"' -> loop (i + 1) false false true acc
            | '\\' -> loop (i + 1) true true value_started acc
            | _ ->
                Stdlib.Buffer.add_char buf ch;
                loop (i + 1) true false true acc)
          else
            match ch with
            | '"' -> loop (i + 1) true false true acc
            | ',' ->
                let acc = add_current value_started acc in
                loop (i + 1) false false false acc
            | _ ->
                Stdlib.Buffer.add_char buf ch;
                loop (i + 1) false false true acc
      in
      loop 0 false false false []
  in
  Caqti_type.(custom ~encode ~decode string)

(* Custom float array for embeddings - encode as pgvector format *)
let float_array =
  let encode arr =
    let str_arr = Array.map arr ~f:Float.to_string in
    Ok ("[" ^ String.concat ~sep:"," (Array.to_list str_arr) ^ "]")
  in
  let decode str =
    let trimmed = String.strip str in
    if
      String.length trimmed < 2
      || (not (Char.equal (String.get trimmed 0) '['))
      || not (Char.equal (String.get trimmed (String.length trimmed - 1)) ']')
    then Error "Invalid vector literal"
    else
      let inner =
        String.sub trimmed ~pos:1 ~len:(String.length trimmed - 2)
        |> String.strip
      in
      if String.is_empty inner then Ok [||]
      else
        let parse part =
          let value = String.strip part in
          if String.is_empty value then Error "Empty vector component"
          else
            try Ok (Float.of_string value)
            with Stdlib.Failure _ -> Error ("Invalid float: " ^ value)
        in
        let rec collect acc = function
          | [] -> Ok (Array.of_list (List.rev acc))
          | part :: rest -> (
              match parse part with
              | Ok v -> collect (v :: acc) rest
              | Error _ as err -> err)
        in
        collect [] (String.split ~on:',' inner)
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

type fen_info = {
  fen_id : Uuidm.t;
  fen_text : string;
  side_to_move : char;
  castling : string;
  en_passant : string option;
  material_signature : string;
  embedding_version : string option;
  embedding : string option;
  usage_count : int;
}

type fen_similarity = {
  fen_id : Uuidm.t;
  fen_text : string;
  embedding_version : string;
  distance : float;
  usage_count : int;
}

type game_detail = {
  game_id : Uuidm.t;
  header : Types.Game_header.t;
  source_pgn : string;
  batch_label : string option;
  ingested_at : Ptime.t;
  move_count : int;
}

type game_overview = {
  game_id : Uuidm.t;
  game_date : Ptime.t option;
  event : string option;
  white_player : string;
  black_player : string;
  result : string;
  move_count : int;
}

type pattern_game = {
  game_id : Uuidm.t;
  game_date : Ptime.t option;
  event : string option;
  white_player : string;
  black_player : string;
  result : string;
  move_count : int;
  eco : string option;
  opening : string option;
  detected_by : Chess_engine.color;
  confidence : float;
  outcome : string option;
  start_ply : int option;
  end_ply : int option;
  metadata : Yojson.Safe.t;
}

type player_overview = {
  player_id : Uuidm.t;
  full_name : string;
  fide_id : string option;
  total_games : int;
  last_played : Ptime.t option;
  latest_standard_elo : int option;
}

type search_hit = {
  entity_type : string;
  entity_id : Uuidm.t;
  content : string;
  score : float;
  model : string;
}

let or_fail = function
  | Ok v -> Lwt.return v
  | Error err -> Lwt.fail_with (Caqti_error.show err)

let normalize_name name = String.strip name |> String.lowercase
let char_of_string s = if String.length s = 0 then 'w' else String.get s 0

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

let ensure_ingestion_batches_table_query =
  let open Caqti_request.Infix in
  (Caqti_type.unit -->. Caqti_type.unit)
  @:- {sql|
   CREATE TABLE IF NOT EXISTS ingestion_batches (
    batch_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    source_path TEXT NOT NULL,
    label TEXT NOT NULL,
    checksum TEXT NOT NULL UNIQUE,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now()
   )
  |sql}

let ensure_ingestion_batches_ingested_at_column_query =
  let open Caqti_request.Infix in
  (Caqti_type.unit -->. Caqti_type.unit)
  @:- "ALTER TABLE ingestion_batches ADD COLUMN IF NOT EXISTS ingested_at \
       TIMESTAMPTZ NOT NULL DEFAULT now()"

let ensure_ingestion_batches_checksum_index_query =
  let open Caqti_request.Infix in
  (Caqti_type.unit -->. Caqti_type.unit)
  @:- "CREATE UNIQUE INDEX IF NOT EXISTS ingestion_batches_checksum_idx ON \
       ingestion_batches (checksum)"

let ensure_ingestion_batches pool =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let open Lwt_result.Syntax in
      let* () = Db.exec ensure_ingestion_batches_table_query () in
      let* () = Db.exec ensure_ingestion_batches_ingested_at_column_query () in
      let* () = Db.exec ensure_ingestion_batches_checksum_index_query () in
      Lwt.return_ok ())

let ensure_search_documents_table_query =
  let open Caqti_request.Infix in
  (Caqti_type.unit -->. Caqti_type.unit)
  @:- {sql|
   CREATE TABLE IF NOT EXISTS search_documents (
    document_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    entity_type TEXT NOT NULL,
    entity_id UUID NOT NULL,
    content TEXT NOT NULL,
    embedding vector(1536) NOT NULL,
    model TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (entity_type, entity_id)
   )
  |sql}

let ensure_search_documents_entity_index_query =
  let open Caqti_request.Infix in
  (Caqti_type.unit -->. Caqti_type.unit)
  @:- "CREATE INDEX IF NOT EXISTS idx_search_documents_entity ON \
       search_documents (entity_type, entity_id)"

let ensure_search_documents_updated_index_query =
  let open Caqti_request.Infix in
  (Caqti_type.unit -->. Caqti_type.unit)
  @:- "CREATE INDEX IF NOT EXISTS idx_search_documents_updated ON \
       search_documents (updated_at DESC)"

let ensure_search_documents_ivfflat_index_query =
  let open Caqti_request.Infix in
  (Caqti_type.unit -->. Caqti_type.unit)
  @:- "CREATE INDEX IF NOT EXISTS idx_search_documents_embedding ON \
       search_documents USING ivfflat (embedding vector_l2_ops) WITH (lists = \
       500)"

let ensure_search_documents_column_query =
  let open Caqti_request.Infix in
  (Caqti_type.unit -->. Caqti_type.unit)
  @:- "ALTER TABLE search_documents ALTER COLUMN embedding TYPE vector(1536)"

let ensure_search_documents pool =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let open Lwt_result.Syntax in
      let* () = Db.exec ensure_search_documents_table_query () in
      let* () =
        Lwt.bind (Db.exec ensure_search_documents_column_query ()) (function
          | Ok () -> Lwt.return_ok ()
          | Error err ->
              let message = Caqti_error.show err in
              if
                String.is_substring message ~substring:"does not exist"
                || String.is_substring message ~substring:"already of type"
              then Lwt.return_ok ()
              else Lwt.return_error err)
      in
      let* () = Db.exec ensure_search_documents_entity_index_query () in
      let* () = Db.exec ensure_search_documents_updated_index_query () in
      let* () = Db.exec ensure_search_documents_ivfflat_index_query () in
      Lwt.return_ok ())

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

let upsert_search_document_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t5 string uuid string float_array string) -->. Caqti_type.unit)
  @:- {sql|
   INSERT INTO search_documents (entity_type, entity_id, content, embedding, model)
   VALUES (?, ?, ?, ?, ?)
   ON CONFLICT (entity_type, entity_id)
   DO UPDATE
   SET content = EXCLUDED.content,
       embedding = EXCLUDED.embedding,
       model = EXCLUDED.model,
       updated_at = now()
  |sql}

let search_documents_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t4 float_array string_array float_array int)
  -->* Caqti_type.(t5 string uuid string float string))
  @:- {sql|
   SELECT entity_type,
          entity_id,
          content,
          1.0 / (1.0 + (embedding <=> ?))::float AS score,
          model
   FROM search_documents
   WHERE entity_type = ANY(?)
   ORDER BY embedding <=> ?
   LIMIT ?
  |sql}

let upsert_search_document pool ~entity_type ~entity_id ~content ~embedding
    ~model =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec upsert_search_document_query
        (entity_type, entity_id, content, embedding, model))

let search_documents pool ~query_embedding ~entity_types ~limit =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let open Lwt_result.Syntax in
      let* rows =
        Db.collect_list search_documents_query
          (query_embedding, entity_types, query_embedding, limit)
      in
      let hits =
        List.map rows ~f:(fun (entity_type, entity_id, content, score, model) ->
            { entity_type; entity_id; content; score; model })
      in
      Lwt.return_ok hits)

(* -------------------------------------------------------------------------- *)
(* Pattern detections                                                         *)

let color_to_text = function Chess_engine.White -> "white" | Black -> "black"

let color_of_text = function
  | "white" -> Chess_engine.White
  | "black" -> Chess_engine.Black
  | other -> failwith ("Unexpected color value: " ^ other)

let record_pattern_detection pool ~game_id ~pattern_id ~detected_by ~success
    ~confidence ~start_ply ~end_ply ~outcome ~metadata =
  let open Caqti_request.Infix in
  let request =
    Caqti_type.(
      t9 uuid string string bool float (option int) (option int) (option string)
        string)
    -->. Caqti_type.unit
    @:- {sql|
      INSERT INTO pattern_detections (
        game_id,
        pattern_id,
        detected_by_color,
        success,
        confidence,
        start_ply,
        end_ply,
        outcome,
        metadata
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb)
      ON CONFLICT (game_id, pattern_id, detected_by_color)
      DO UPDATE SET
        success = EXCLUDED.success,
        confidence = EXCLUDED.confidence,
        start_ply = COALESCE(EXCLUDED.start_ply, pattern_detections.start_ply),
        end_ply = COALESCE(EXCLUDED.end_ply, pattern_detections.end_ply),
        outcome = COALESCE(EXCLUDED.outcome, pattern_detections.outcome),
        metadata = EXCLUDED.metadata
    |sql}
  in
  let color = color_to_text detected_by in
  let json = Yojson.Safe.to_string metadata in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.exec request
        ( game_id,
          pattern_id,
          color,
          success,
          confidence,
          start_ply,
          end_ply,
          outcome,
          json ))

let date_to_string = function
  | None -> None
  | Some t ->
      let year, month, day = Ptime.to_date t in
      Some (Printf.sprintf "%04d-%02d-%02d" year month day)

let query_games_with_pattern pool ~pattern_ids ~detected_by ~success
    ~min_confidence ~max_confidence ~eco_prefix ~opening_substring
    ~min_white_elo ~max_white_elo ~min_black_elo ~max_black_elo
    ~min_rating_difference ~min_move_count ~max_move_count ~start_date
    ~end_date ~white_name_substring ~black_name_substring ~result_filter ~limit
    ~offset =
  let open Caqti_request.Infix in
  let params_type =
    let open Caqti_type in
    let base = t2 int int in
    let base = t2 (option string) base in (* result_filter *)
    let base = t2 (option string) base in (* black_name_substring *)
    let base = t2 (option string) base in (* white_name_substring *)
    let base = t2 (option string) base in (* end_date *)
    let base = t2 (option string) base in (* start_date *)
    let base = t2 (option int) base in (* max_move_count *)
    let base = t2 (option int) base in (* min_move_count *)
    let base = t2 (option int) base in (* min_rating_difference *)
    let base = t2 (option int) base in (* max_black_elo *)
    let base = t2 (option int) base in (* min_black_elo *)
    let base = t2 (option int) base in (* max_white_elo *)
    let base = t2 (option int) base in (* min_white_elo *)
    let base = t2 (option string) base in (* opening_substring *)
    let base = t2 (option string) base in (* eco_prefix *)
    let base = t2 (option string) base in (* detected_by *)
    let base = t2 (option float) base in (* max_confidence *)
    let base = t2 float base in (* min_confidence *)
    let base = t2 bool base in (* success flag *)
    t2 string_array base
  in
  let query =
    (params_type
    -->* Caqti_type.(
           t2 uuid
             (t2 (option date)
                (t2 (option string)
                   (t2 string
                      (t2 string
                         (t2 string
                            (t2 int
                               (t2 (option string)
                                  (t2 (option string)
                                     (t2 string
                                        (t2 float
                                           (t2 (option string)
                                              (t2 (option int)
                                                 (t2 (option int) string))))))))))))))
    @:- {sql|
      SELECT g.game_id,
             g.game_date,
             g.event,
             w.full_name AS white_player,
             b.full_name AS black_player,
             g.result,
             COALESCE(mc.move_count, 0),
             g.eco_code,
             g.opening_name,
             pd.detected_by_color,
             pd.confidence,
             pd.outcome,
             pd.start_ply,
             pd.end_ply,
             pd.metadata::text
      FROM games g
      JOIN players w ON g.white_id = w.player_id
      JOIN players b ON g.black_id = b.player_id
      LEFT JOIN (
        SELECT game_id, COUNT(*)::int AS move_count
        FROM games_positions
        GROUP BY game_id
      ) mc ON mc.game_id = g.game_id
      JOIN pattern_detections pd ON pd.game_id = g.game_id
      WHERE pd.pattern_id = ANY (?)
        AND pd.success = ?
        AND pd.confidence >= ?
        AND pd.confidence <= COALESCE(?::float, pd.confidence)
        AND COALESCE(?::text, pd.detected_by_color) = pd.detected_by_color
        AND COALESCE(g.eco_code, '') ILIKE COALESCE(?::text, COALESCE(g.eco_code, ''))
        AND COALESCE(g.opening_name, '') ILIKE COALESCE(?::text, COALESCE(g.opening_name, ''))
        AND COALESCE(?::int, -2147483647) <= COALESCE(g.white_elo, -2147483647)
        AND COALESCE(g.white_elo, 2147483647) <= COALESCE(?::int, COALESCE(g.white_elo, 2147483647))
        AND COALESCE(?::int, -2147483647) <= COALESCE(g.black_elo, -2147483647)
        AND COALESCE(g.black_elo, 2147483647) <= COALESCE(?::int, COALESCE(g.black_elo, 2147483647))
        AND COALESCE(?::int, -2147483647) <= COALESCE(g.white_elo - g.black_elo, -2147483647)
        AND COALESCE(?::int, -2147483647) <= COALESCE(mc.move_count, -2147483647)
        AND COALESCE(mc.move_count, 2147483647) <= COALESCE(?::int, COALESCE(mc.move_count, 2147483647))
        AND g.game_date >= COALESCE(?::date, g.game_date)
        AND g.game_date <= COALESCE(?::date, g.game_date)
        AND w.full_name ILIKE COALESCE(?::text, w.full_name)
        AND b.full_name ILIKE COALESCE(?::text, b.full_name)
        AND g.result = COALESCE(?::text, g.result)
      ORDER BY g.game_date DESC, g.ingested_at DESC
      LIMIT ? OFFSET ?
    |sql})
  in
  let detected_by_param = Option.map detected_by ~f:color_to_text in
  let min_conf = Option.value ~default:0.0 min_confidence in
  let eco_like = Option.map eco_prefix ~f:(fun prefix -> prefix ^ "%") in
  let opening_like =
    Option.map opening_substring ~f:(fun needle -> "%" ^ needle ^ "%")
  in
  let white_like =
    Option.map white_name_substring ~f:(fun needle -> "%" ^ needle ^ "%")
  in
  let black_like =
    Option.map black_name_substring ~f:(fun needle -> "%" ^ needle ^ "%")
  in
  let start_date_str = date_to_string start_date in
  let end_date_str = date_to_string end_date in
  let pattern_ids_array = Array.of_list pattern_ids in
  let params =
    let base = (limit, offset) in
    let base = (result_filter, base) in
    let base = (black_like, base) in
    let base = (white_like, base) in
    let base = (end_date_str, base) in
    let base = (start_date_str, base) in
    let base = (max_move_count, base) in
    let base = (min_move_count, base) in
    let base = (min_rating_difference, base) in
    let base = (max_black_elo, base) in
    let base = (min_black_elo, base) in
    let base = (max_white_elo, base) in
    let base = (min_white_elo, base) in
    let base = (opening_like, base) in
    let base = (eco_like, base) in
    let base = (detected_by_param, base) in
    let base = (max_confidence, base) in
    let base = (min_conf, base) in
    let base = (success, base) in
    let base = (pattern_ids_array, base) in
    base
  in
  let open Lwt_result.Syntax in
  let* rows =
    Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
        Db.collect_list query params)
  in
  let games =
    List.map rows ~f:(fun row ->
        let game_id, rest = row in
        let game_date, rest = rest in
        let event, rest = rest in
        let white_player, rest = rest in
        let black_player, rest = rest in
        let result, rest = rest in
        let move_count, rest = rest in
        let eco, rest = rest in
        let opening, rest = rest in
        let detected_by_color, rest = rest in
        let confidence, rest = rest in
        let outcome, rest = rest in
        let start_ply, rest = rest in
        let end_ply, metadata_text = rest in
        let metadata =
          try Yojson.Safe.from_string metadata_text
          with Yojson.Json_error _ -> `String metadata_text
        in
        {
          game_id;
          game_date =
            Option.bind game_date ~f:(fun (y, m, d) -> Ptime.of_date (y, m, d));
          event;
          white_player;
          black_player;
          result;
          move_count;
          eco;
          opening;
          detected_by = color_of_text detected_by_color;
          confidence;
          outcome;
          start_ply;
          end_ply;
          metadata;
        })
  in
  Lwt.return_ok games

let find_fen_id_by_text_query =
  let open Caqti_request.Infix in
  (Caqti_type.string -->? uuid) @:- "SELECT fen_id FROM fens WHERE fen_text = ?"

let fetch_fen_query =
  let open Caqti_request.Infix in
  (uuid -->? Caqti_type.(t5 string string string (option string) string))
  @:- "SELECT fen_text, side_to_move, castling_rights, en_passant_file, \
       material_signature\n\
      \   FROM fens\n\
      \   WHERE fen_id = ?"

let fen_usage_query =
  let open Caqti_request.Infix in
  (uuid -->! Caqti_type.int)
  @:- "SELECT COALESCE(COUNT(*), 0)::int FROM games_positions WHERE fen_id = ?"

let get_fen_embedding_query =
  let open Caqti_request.Infix in
  (uuid -->? Caqti_type.(t2 string string))
  @:- "SELECT embedding::text, embedding_version\n\
      \   FROM fen_embeddings\n\
      \   WHERE fen_id = ?"

let get_embedding_version_query =
  let open Caqti_request.Infix in
  (uuid -->? Caqti_type.string)
  @:- "SELECT embedding_version FROM fen_embeddings WHERE fen_id = ?"

let position_motifs_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 uuid int) -->? string_array)
  @:- "SELECT motif_flags FROM games_positions WHERE game_id = ? AND \
       ply_number = ?"

let similar_fens_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 uuid int) -->* Caqti_type.(t5 uuid string string float int))
  @:- {sql|
   WITH target AS (
     SELECT embedding FROM fen_embeddings WHERE fen_id = ?
   ), usage AS (
     SELECT fen_id, COUNT(*)::int AS usage_count
     FROM games_positions
     GROUP BY fen_id
   )
   SELECT fe.fen_id,
          f.fen_text,
          fe.embedding_version,
          (fe.embedding <=> (SELECT embedding FROM target))::float AS distance,
          COALESCE(u.usage_count, 0)
   FROM fen_embeddings fe
   JOIN fens f ON fe.fen_id = f.fen_id
   LEFT JOIN usage u ON u.fen_id = fe.fen_id
   WHERE (SELECT embedding FROM target) IS NOT NULL
   ORDER BY distance ASC
   LIMIT ?
  |sql}

let game_metadata_query =
  let open Caqti_request.Infix in
  let open Caqti_type in
  let players_type =
    t2 (t2 string (option string)) (t2 string (option string))
  in
  let details_primary =
    t4 (option string) (option string) (option string) (option date)
  in
  let details_secondary = t3 (option string) (option string) string in
  let details_tail = t3 (option string) (option int) (option int) in
  let details_type = t3 details_primary details_secondary details_tail in
  let ingest_type = t3 (option uuid) (option string) ptime in
  (uuid -->? t3 players_type details_type ingest_type)
  @:- {sql|
   SELECT
     w.full_name,
     w.fide_id,
     b.full_name,
     b.fide_id,
     g.event,
     g.site,
     g.round,
     g.game_date,
     g.eco_code,
     g.opening_name,
     g.result,
     g.termination,
     g.white_elo,
     g.black_elo,
     g.ingestion_batch,
     ib.label,
     g.ingested_at
   FROM games g
   JOIN players w ON g.white_id = w.player_id
   JOIN players b ON g.black_id = b.player_id
   LEFT JOIN ingestion_batches ib ON ib.batch_id = g.ingestion_batch
   WHERE g.game_id = ?
  |sql}

let game_source_query =
  let open Caqti_request.Infix in
  (uuid -->? Caqti_type.string)
  @:- "SELECT source_pgn FROM games WHERE game_id = ?"

let game_move_count_query =
  let open Caqti_request.Infix in
  (uuid -->! Caqti_type.int)
  @:- "SELECT COUNT(*)::int FROM games_positions WHERE game_id = ?"

let player_search_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string int)
  -->* Caqti_type.(
         t6 uuid string (option string) int (option date) (option int)))
  @:- {sql|
   WITH appearances AS (
     SELECT white_id AS player_id, game_date FROM games
     UNION ALL
     SELECT black_id AS player_id, game_date FROM games
   ), stats AS (
     SELECT player_id,
            COUNT(*)::int AS total_games,
            MAX(game_date) AS last_game
     FROM appearances
     GROUP BY player_id
   )
   SELECT p.player_id,
          p.full_name,
          p.fide_id,
          COALESCE(s.total_games, 0),
          s.last_game,
          r.standard_elo
   FROM players p
   LEFT JOIN stats s ON s.player_id = p.player_id
   LEFT JOIN mv_latest_ratings r ON r.player_id = p.player_id
   WHERE lower(p.full_name) LIKE lower('%' || ? || '%')
   ORDER BY COALESCE(s.total_games, 0) DESC, p.created_at DESC
   LIMIT ?
  |sql}

let games_page_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 int int)
  -->* Caqti_type.(
         t7 uuid (option date) (option string) string string string int))
  @:- {sql|
   WITH move_counts AS (
     SELECT game_id, COUNT(*)::int AS move_count
     FROM games_positions
     GROUP BY game_id
   )
   SELECT
     g.game_id,
     g.game_date,
     g.event,
     w.full_name AS white_name,
     b.full_name AS black_name,
     g.result,
     COALESCE(mc.move_count, 0)
   FROM games g
   JOIN players w ON g.white_id = w.player_id
   JOIN players b ON g.black_id = b.player_id
   LEFT JOIN move_counts mc ON mc.game_id = g.game_id
   ORDER BY g.ingested_at DESC, g.game_id DESC
   LIMIT ?
   OFFSET ?
  |sql}

let batches_by_label_query =
  let open Caqti_request.Infix in
  (Caqti_type.(t2 string int)
  -->* Caqti_type.(t5 uuid string string string ptime))
  @:- {sql|
   SELECT batch_id, label, source_path, checksum, ingested_at
   FROM ingestion_batches
   WHERE lower(label) LIKE lower('%' || ? || '%')
   ORDER BY ingested_at DESC
   LIMIT ?
  |sql}

let get_fen_details pool ~fen_id =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let open Lwt.Infix in
      Db.find_opt fetch_fen_query fen_id >>= function
      | Error err -> Lwt.return (Error err)
      | Ok None -> Lwt.return (Ok None)
      | Ok
          (Some
             ( fen_text,
               side_to_move_str,
               castling,
               en_passant,
               material_signature )) -> (
          let side_to_move = char_of_string side_to_move_str in
          Db.find fen_usage_query fen_id >>= function
          | Error err -> Lwt.return (Error err)
          | Ok usage_count -> (
              Db.find_opt get_fen_embedding_query fen_id >>= function
              | Error err -> Lwt.return (Error err)
              | Ok embedding_row ->
                  let embedding, embedding_version =
                    match embedding_row with
                    | None -> (None, None)
                    | Some (embedding, version) -> (Some embedding, Some version)
                  in
                  let record =
                    {
                      fen_id;
                      fen_text;
                      side_to_move;
                      castling;
                      en_passant;
                      material_signature;
                      embedding_version;
                      embedding;
                      usage_count;
                    }
                  in
                  Lwt.return (Ok (Some record)))))

let get_fen_embedding_version pool ~fen_id =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find_opt get_embedding_version_query fen_id)

let get_position_motifs pool ~game_id ~ply_number =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find_opt position_motifs_query (game_id, ply_number))

let get_fen_by_text pool ~fen_text =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let open Lwt.Infix in
      Db.find_opt find_fen_id_by_text_query fen_text >>= function
      | Error err -> Lwt.return (Error err)
      | Ok None -> Lwt.return (Ok None)
      | Ok (Some fen_id) -> get_fen_details pool ~fen_id)

let find_similar_fens pool ~fen_id ~limit =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let* rows_res = Db.collect_list similar_fens_query (fen_id, limit) in
      Lwt.return
        (Result.map rows_res ~f:(fun rows ->
             List.map rows
               ~f:(fun (fen_id, fen_text, version, distance, usage_count) ->
                 {
                   fen_id;
                   fen_text;
                   embedding_version = version;
                   distance;
                   usage_count;
                 }))))

let get_game_detail pool ~game_id =
  let open Lwt.Infix in
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      Db.find_opt game_metadata_query game_id >>= function
      | Error err -> Lwt.return (Error err)
      | Ok None -> Lwt.return (Ok None)
      | Ok
          (Some
             ( ((white_name, white_fide), (black_name, black_fide)),
               ( (event, site, round, game_date),
                 (eco, opening, result),
                 (termination, white_elo, black_elo) ),
               (batch_id_opt, batch_label, ingested_at) )) -> (
          let game_date_ptime =
            Option.bind game_date ~f:(fun date_tuple ->
                match Ptime.of_date date_tuple with
                | Some t -> Some t
                | None -> None)
          in
          Db.find_opt game_source_query game_id >>= function
          | Error err -> Lwt.return (Error err)
          | Ok None -> Lwt.return (Ok None)
          | Ok (Some source_pgn) -> (
              Db.find game_move_count_query game_id >>= function
              | Error err -> Lwt.return (Error err)
              | Ok move_count ->
                  let header : Types.Game_header.t =
                    {
                      event;
                      site;
                      game_date = game_date_ptime;
                      round;
                      eco;
                      opening;
                      white_player = white_name;
                      black_player = black_name;
                      white_elo;
                      black_elo;
                      white_fide_id = white_fide;
                      black_fide_id = black_fide;
                      result;
                      termination;
                    }
                  in
                  let batch_label =
                    match batch_id_opt with
                    | None -> batch_label
                    | Some _ -> batch_label
                  in
                  let detail : game_detail =
                    {
                      game_id;
                      header;
                      source_pgn;
                      batch_label;
                      ingested_at;
                      move_count;
                    }
                  in
                  Lwt.return (Ok (Some detail)))))

let search_players pool ~query ~limit =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let open Lwt.Infix in
      Db.collect_list player_search_query (query, limit) >>= function
      | Error err -> Lwt.return (Error err)
      | Ok rows ->
          let overviews =
            List.map rows
              ~f:(fun
                  ( player_id,
                    full_name,
                    fide_id,
                    total_games,
                    last_game,
                    latest_elo )
                ->
                let last_played =
                  Option.bind last_game ~f:(fun date_tuple ->
                      match Ptime.of_date date_tuple with
                      | Some t -> Some t
                      | None -> None)
                in
                {
                  player_id;
                  full_name;
                  fide_id;
                  total_games;
                  last_played;
                  latest_standard_elo = latest_elo;
                })
          in
          Lwt.return (Ok overviews))

let list_games pool ~limit ~offset =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let open Lwt.Infix in
      Db.collect_list games_page_query (limit, offset) >>= function
      | Error err -> Lwt.return (Error err)
      | Ok rows ->
          let games =
            List.map rows
              ~f:(fun
                  ( game_id,
                    game_date,
                    event,
                    white_player,
                    black_player,
                    result,
                    move_count )
                ->
                let game_date_ptime =
                  Option.bind game_date ~f:(fun date_tuple ->
                      match Ptime.of_date date_tuple with
                      | Some t -> Some t
                      | None -> None)
                in
                {
                  game_id;
                  game_date = game_date_ptime;
                  event;
                  white_player;
                  black_player;
                  result;
                  move_count;
                })
          in
          Lwt.return (Ok games))

let find_batches_by_label pool ~label ~limit =
  Pool.use pool (fun (module Db : Caqti_lwt.CONNECTION) ->
      let* rows_res = Db.collect_list batches_by_label_query (label, limit) in
      Lwt.return
        (Result.map rows_res ~f:(fun rows ->
             List.map rows
               ~f:(fun (batch_id, label, source_path, checksum, ingested_at) ->
                 { batch_id; label; source_path; checksum; ingested_at }))))

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
