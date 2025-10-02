(** Database persistence layer for ChessBuddy.

    This module provides high-level database operations using Caqti 2.x with
    PostgreSQL and pgvector. It abstracts SQL queries, connection pooling, and
    type conversions for chess-specific data structures.

    {1 Connection Management} *)

open! Base

module Pool : sig
  (** Database connection pool backed by Caqti_lwt_unix.Pool *)

  type t = (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t

  val create :
    ?max_size:int ->
    Uri.t ->
    ((Caqti_lwt.connection, [> Caqti_error.connect ]) Caqti_lwt_unix.Pool.t,
     [> Caqti_error.load ])
    Result.t
  (** [create ?max_size uri] creates a connection pool for the given database URI.

      @param max_size Maximum concurrent connections (default: 10)
      @param uri PostgreSQL connection string (e.g., [postgresql://user:pass@host/db])

      Example:
      {[
        let pool = Pool.create ~max_size:20
          (Uri.of_string "postgresql://chess:chess@localhost:5433/chessbuddy")
      ]} *)

  val use :
    t ->
    ((module Caqti_lwt.CONNECTION) -> ('a, Caqti_error.t) Result.t Lwt.t) ->
    ('a, Caqti_error.t) Result.t Lwt.t
  (** [use pool f] executes [f] with a connection from the pool.
      The connection is automatically returned to the pool after use. *)
end

(** {1 Type Definitions}

    Record types for database queries and CLI reporting. *)

type batch_overview = {
  batch_id : Uuidm.t;
  label : string;  (** Human-readable batch identifier *)
  source_path : string;  (** Path to the ingested PGN file *)
  checksum : string;  (** SHA256 checksum for deduplication *)
  ingested_at : Ptime.t;
}
(** Metadata for an ingestion batch *)

type batch_summary = {
  overview : batch_overview;
  games_count : int;
  position_count : int;
  unique_fens : int;
  embedding_count : int;
}
(** Detailed statistics for a batch *)

type health_report = {
  server_version : string;
  database_name : string;
  extensions : (string * bool) list;
      (** Required PostgreSQL extensions and their availability status *)
}
(** Database health check results *)

type fen_info = {
  fen_id : Uuidm.t;
  fen_text : string;
  side_to_move : char;  (** 'w' or 'b' *)
  castling : string;  (** Castling rights (e.g., "KQkq", "-") *)
  en_passant : string option;  (** En passant target square if available *)
  material_signature : string;
  embedding_version : string option;
  embedding : string option;  (** Serialized vector if available *)
  usage_count : int;  (** Number of games using this position *)
}
(** Complete information about a FEN position *)

type fen_similarity = {
  fen_id : Uuidm.t;
  fen_text : string;
  embedding_version : string;
  distance : float;  (** Cosine distance from query FEN *)
  usage_count : int;
}
(** FEN similarity search result *)

type game_detail = {
  game_id : Uuidm.t;
  header : Types.Game_header.t;
  source_pgn : string;
  batch_label : string option;
  ingested_at : Ptime.t;
  move_count : int;
}
(** Detailed game metadata *)

type game_overview = {
  game_id : Uuidm.t;
  game_date : Ptime.t option;
  event : string option;
  white_player : string;
  black_player : string;
  result : string;
  move_count : int;
}
(** Summary view for game listings *)

type player_overview = {
  player_id : Uuidm.t;
  full_name : string;
  fide_id : string option;
  total_games : int;
  last_played : Ptime.t option;
  latest_standard_elo : int option;
}
(** Player statistics *)

type search_hit = {
  entity_type : string;  (** "game", "player", "fen", "batch", or "embedding" *)
  entity_id : Uuidm.t;
  content : string;  (** Indexed text content *)
  score : float;  (** Relevance score (0.0 to 1.0) *)
  model : string;  (** Embedding model version *)
}
(** Natural language search result *)

(** {1 Error Handling} *)

val or_fail : ('a, Caqti_error.t) Result.t -> 'a Lwt.t
(** [or_fail result] converts Caqti errors to exceptions.

    Raises: [Failure] with formatted error message on [Error] *)

(** {1 Player Management} *)

val normalize_name : string -> string
(** [normalize_name name] converts to lowercase and strips whitespace for matching *)

val upsert_player :
  Pool.t ->
  full_name:string ->
  fide_id:string option ->
  (Uuidm.t, Caqti_error.t) Result.t Lwt.t
(** [upsert_player pool ~full_name ~fide_id] inserts or updates a player.

    - If [fide_id] is provided: matches by FIDE ID, updates name if changed
    - If [fide_id] is [None]: matches by normalized name, uses [ON CONFLICT] to handle duplicates

    Returns: Player UUID *)

val record_rating :
  Pool.t ->
  player_id:Uuidm.t ->
  date:int * int * int ->
  ?standard:int ->
  ?rapid:int ->
  unit ->
  (unit, Caqti_error.t) Result.t Lwt.t
(** [record_rating pool ~player_id ~date ?standard ?rapid ()] stores a rating snapshot.

    Uses [ON CONFLICT] to update existing ratings for the same date. *)

val search_players :
  Pool.t ->
  query:string ->
  limit:int ->
  (player_overview list, Caqti_error.t) Result.t Lwt.t
(** [search_players pool ~query ~limit] searches by partial name match.

    Results ordered by total games (descending), then creation date. *)

(** {1 Batch Management} *)

val ensure_ingestion_batches :
  Pool.t -> (unit, Caqti_error.t) Result.t Lwt.t
(** [ensure_ingestion_batches pool] creates the [ingestion_batches] table if missing.
    Adds migration columns/indexes as needed. Safe to call multiple times. *)

val create_batch :
  Pool.t ->
  source_path:string ->
  label:string ->
  checksum:string ->
  (Uuidm.t, Caqti_error.t) Result.t Lwt.t
(** [create_batch pool ~source_path ~label ~checksum] inserts a new batch.

    Uses [ON CONFLICT (checksum)] to prevent duplicate ingestion.
    Returns existing batch_id if checksum matches. *)

val list_batches :
  Pool.t -> limit:int -> (batch_overview list, Caqti_error.t) Result.t Lwt.t
(** [list_batches pool ~limit] retrieves recent batches, newest first *)

val find_batches_by_label :
  Pool.t ->
  label:string ->
  limit:int ->
  (batch_overview list, Caqti_error.t) Result.t Lwt.t
(** [find_batches_by_label pool ~label ~limit] searches batches by label substring *)

val get_batch_summary :
  Pool.t ->
  batch_id:Uuidm.t ->
  (batch_summary option, Caqti_error.t) Result.t Lwt.t
(** [get_batch_summary pool ~batch_id] computes aggregate statistics for a batch *)

(** {1 Game Management} *)

val record_game :
  Pool.t ->
  white_id:Uuidm.t ->
  black_id:Uuidm.t ->
  header:Types.Game_header.t ->
  source_pgn:string ->
  batch_id:Uuidm.t ->
  (Uuidm.t, Caqti_error.t) Result.t Lwt.t
(** [record_game pool ~white_id ~black_id ~header ~source_pgn ~batch_id] stores a game.

    Deduplicates using: [(white_id, black_id, game_date, round, pgn_hash)]
    The PGN hash prevents index size issues with large game texts. *)

val get_game_detail :
  Pool.t ->
  game_id:Uuidm.t ->
  (game_detail option, Caqti_error.t) Result.t Lwt.t
(** [get_game_detail pool ~game_id] retrieves full game metadata with move count *)

val list_games :
  Pool.t ->
  limit:int ->
  offset:int ->
  (game_overview list, Caqti_error.t) Result.t Lwt.t
(** [list_games pool ~limit ~offset] paginates through games, newest first *)

(** {1 Position & FEN Management} *)

val upsert_fen :
  Pool.t ->
  fen_text:string ->
  side_to_move:char ->
  castling:string ->
  en_passant:string option ->
  material_signature:string ->
  (Uuidm.t, Caqti_error.t) Result.t Lwt.t
(** [upsert_fen pool ~fen_text ~side_to_move ~castling ~en_passant ~material_signature]
    inserts or retrieves a FEN position.

    Deduplicates by [fen_text] using [ON CONFLICT]. Returns existing [fen_id] if present. *)

val record_position :
  Pool.t ->
  game_id:Uuidm.t ->
  move:Types.Move_feature.t ->
  fen_id:Uuidm.t ->
  side_to_move:char ->
  (unit, Caqti_error.t) Result.t Lwt.t
(** [record_position pool ~game_id ~move ~fen_id ~side_to_move] stores a move in [games_positions].

    Links to both game and FEN, preserving SAN, UCI, evaluations, and motif flags. *)

val get_fen_details :
  Pool.t ->
  fen_id:Uuidm.t ->
  (fen_info option, Caqti_error.t) Result.t Lwt.t
(** [get_fen_details pool ~fen_id] retrieves FEN metadata, embedding status, and usage count *)

val get_fen_by_text :
  Pool.t ->
  fen_text:string ->
  (fen_info option, Caqti_error.t) Result.t Lwt.t
(** [get_fen_by_text pool ~fen_text] looks up FEN by exact text match *)

val get_position_motifs :
  Pool.t ->
  game_id:Uuidm.t ->
  ply_number:int ->
  (string array option, Caqti_error.t) Result.t Lwt.t
(** [get_position_motifs pool ~game_id ~ply_number] retrieves tactical motif flags for a move *)

(** {1 Embedding Management} *)

val record_embedding :
  Pool.t ->
  fen_id:Uuidm.t ->
  embedding:float array ->
  version:string ->
  (unit, Caqti_error.t) Result.t Lwt.t
(** [record_embedding pool ~fen_id ~embedding ~version] stores a 768-dimensional vector.

    Uses [ON CONFLICT] to update existing embeddings (last write wins).

    Raises: Constraint violation if embedding dimension ≠ 768 *)

val get_fen_embedding_version :
  Pool.t ->
  fen_id:Uuidm.t ->
  (string option, Caqti_error.t) Result.t Lwt.t
(** [get_fen_embedding_version pool ~fen_id] retrieves the embedding model version *)

val find_similar_fens :
  Pool.t ->
  fen_id:Uuidm.t ->
  limit:int ->
  (fen_similarity list, Caqti_error.t) Result.t Lwt.t
(** [find_similar_fens pool ~fen_id ~limit] performs vector similarity search.

    Uses cosine distance ([<=>]) operator from pgvector.
    Results ordered by distance (ascending). *)

(** {1 Natural Language Search} *)

val ensure_search_documents :
  Pool.t -> (unit, Caqti_error.t) Result.t Lwt.t
(** [ensure_search_documents pool] creates the [search_documents] table and indexes.
    Handles 768→1536 dimension migration. Safe to call multiple times. *)

val upsert_search_document :
  Pool.t ->
  entity_type:string ->
  entity_id:Uuidm.t ->
  content:string ->
  embedding:float array ->
  model:string ->
  (unit, Caqti_error.t) Result.t Lwt.t
(** [upsert_search_document pool ~entity_type ~entity_id ~content ~embedding ~model]
    indexes text for natural language search.

    Updates [updated_at] timestamp on conflict. *)

val search_documents :
  Pool.t ->
  query_embedding:float array ->
  entity_types:string array ->
  limit:int ->
  (search_hit list, Caqti_error.t) Result.t Lwt.t
(** [search_documents pool ~query_embedding ~entity_types ~limit] performs hybrid search.

    Filters by entity types and ranks by cosine similarity.
    Score normalized to [0.0, 1.0] range using [1.0 / (1.0 + distance)]. *)

(** {1 Health Checks} *)

val health_check :
  ?extensions:string list ->
  Pool.t ->
  (health_report, Caqti_error.t) Result.t Lwt.t
(** [health_check ?extensions pool] verifies database connectivity and requirements.

    @param extensions Extensions to check (default: ["vector"; "pgcrypto"; "uuid-ossp"])

    Returns server version, database name, and extension availability status. *)
