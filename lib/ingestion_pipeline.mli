(** Ingestion pipeline for PGN chess games.

    This module orchestrates the full ingestion workflow: parsing PGN files,
    extracting players and games, generating FENs for each position, computing
    embeddings, and persisting everything to PostgreSQL with deduplication.

    {1 Module Signatures}

    Pluggable interfaces for embedders and PGN sources. *)

open! Base

(** FEN position embedder interface.

    Implementations may use neural networks, hand-crafted features, or
    placeholder values. See {!Embedder.Constant} for a stub implementation. *)
module type EMBEDDER = sig
  val version : string
  (** Embedding model version identifier (e.g., ["v1"],
      ["openai-text-embedding-3-small"]) *)

  val embed : fen:string -> float array Lwt.t
  (** [embed ~fen] converts a FEN string to a 768-dimensional vector.

      The result should be deterministic for the same FEN and version. *)
end

module type TEXT_EMBEDDER = Search_indexer.TEXT_EMBEDDER
(** Natural language text embedder interface (1536-dimensional vectors).

    Delegates to {!Search_indexer.TEXT_EMBEDDER} for consistency. *)

(** PGN file parser interface.

    See {!Pgn_source} for the default implementation. *)
module type PGN_SOURCE = sig
  val fold_games :
    string -> init:'a -> f:('a -> Types.Game.t -> 'a Lwt.t) -> 'a Lwt.t
  (** [fold_games path ~init ~f] streams games from a PGN file.

      @param path Filesystem path to the PGN file
      @param init Initial accumulator value
      @param f Reduction function called for each parsed game

      Implementations should handle multi-game PGN files, preserve move
      annotations (comments, variations, NAGs), and detect game boundaries
      correctly. *)
end

(** {1 Type Definitions} *)

type inspection_summary = {
  total_games : int;
  total_moves : int;
  unique_players : int;
  players : (string * string option) list;
      (** List of [(full_name, fide_id)] tuples *)
}
(** Summary statistics from dry-run inspection *)

(** {1 Checksum & Deduplication} *)

val compute_checksum : string -> string
(** [compute_checksum path] calculates SHA256 hash of a file.

    Used for batch deduplication - files with identical checksums are skipped.

    Raises: [Sys_error] if file cannot be read *)

(** {1 Player Management} *)

val record_player :
  Database.Pool.t ->
  name:string ->
  fide_id:string option ->
  search_embedder:(module TEXT_EMBEDDER) option ->
  Uuidm.t Lwt.t
(** [record_player pool ~name ~fide_id ~search_embedder] upserts a player and
    indexes for search.

    - Deduplicates by FIDE ID (if present) or normalized name
    - Indexes player text for natural language search (when [search_embedder]
      provided)

    Returns: Player UUID

    Raises: [Failure] on database errors (via {!or_fail}) *)

val sync_players_from_pgn :
  (module PGN_SOURCE) -> Database.Pool.t -> pgn_path:string -> int Lwt.t
(** [sync_players_from_pgn source pool ~pgn_path] extracts unique players
    without storing games.

    Useful for pre-populating the players table before full ingestion.

    Returns: Number of players upserted *)

(** {1 FEN & Position Management} *)

val material_signature : string -> string
(** [material_signature fen] computes a piece-count fingerprint from FEN board
    state.

    Example: ["P8,N2,B2,R2,Q1,K1,p8,n2,b2,r2,q1,k1"] for starting position

    Used for quick material-based position filtering. *)

val fen_components : string -> char * string * string option
(** [fen_components fen] extracts [(side_to_move, castling_rights, en_passant)]
    from FEN.

    Returns: [('w' | 'b', castling_string, en_passant_square option)]

    Defaults to [('w', "-", None)] if FEN is malformed. *)

val motifs_for_move : Types.Move_feature.t -> string list
(** [motifs_for_move move] extracts tactical motifs from move features.

    Currently returns [[]] (placeholder). Future versions will detect pins,
    forks, etc. *)

(** {1 Core Ingestion Functions} *)

val process_move :
  Database.Pool.t ->
  game_id:Uuidm.t ->
  embedder:(module EMBEDDER) ->
  move:Types.Move_feature.t ->
  search_embedder:(module TEXT_EMBEDDER) option ->
  unit Lwt.t
(** [process_move pool ~game_id ~embedder ~move ~search_embedder] persists a
    single move.

    Workflow: 1. Extract FEN components (side to move, castling, en passant) 2.
    Compute material signature 3. Upsert FEN position (deduplicates by FEN text)
    4. Record position in [games_positions] table 5. Generate and store
    embedding if missing or version changed 6. Index FEN for natural language
    search

    Raises: [Failure] on database errors *)

val process_game :
  Database.Pool.t ->
  embedder:(module EMBEDDER) ->
  batch_id:Uuidm.t ->
  game:Types.Game.t ->
  source_path:string ->
  batch_label:string ->
  search_embedder:(module TEXT_EMBEDDER) option ->
  unit Lwt.t
(** [process_game pool ~embedder ~batch_id ~game ~source_path ~batch_label
     ~search_embedder] ingests a single game.

    Workflow: 1. Upsert white and black players 2. Record game metadata 3.
    Process each move sequentially (see {!process_move})

    Raises: [Failure] on database errors *)

val ingest_file :
  (module PGN_SOURCE) ->
  Database.Pool.t ->
  embedder:(module EMBEDDER) ->
  pgn_path:string ->
  batch_label:string ->
  search_embedder:(module TEXT_EMBEDDER) option ->
  unit ->
  unit Lwt.t
(** [ingest_file source pool ~embedder ~pgn_path ~batch_label ~search_embedder
     ()] executes the full ingestion pipeline.

    Workflow: 1. Ensure [ingestion_batches] and [search_documents] tables exist
    2. Compute PGN file checksum 3. Create or retrieve batch (deduplicates by
    checksum) 4. Stream games from PGN file 5. Process each game (players,
    positions, embeddings)

    Example:
    {[
      let pool = Database.Pool.create (Uri.of_string db_uri) in
      let embedder = (module Embedder.Constant : EMBEDDER) in
      let search_embedder =
        Some (module Search_embedder.Stub : TEXT_EMBEDDER)
      in
      let%lwt () =
        ingest_file
          (module Pgn_source)
          pool ~embedder ~pgn_path:"data/games/twic1611.pgn"
          ~batch_label:"twic-1611" ~search_embedder ()
      in
      Lwt.return_unit
    ]}

    Raises: [Failure] on database errors or file I/O failures *)

val inspect_file :
  (module PGN_SOURCE) -> pgn_path:string -> inspection_summary Lwt.t
(** [inspect_file source ~pgn_path] performs dry-run analysis without database
    writes.

    Returns summary with game count, move count, and unique player list. Useful
    for previewing PGN contents before ingestion. *)

(** {1 Utilities} *)

val or_fail : ('a, Caqti_error.t) Result.t -> 'a Lwt.t
(** [or_fail result] converts Caqti result to Lwt promise.

    Raises: [Failure] with formatted error message on [Error] *)

val with_pool : Uri.t -> (Database.Pool.t -> 'a Lwt.t) -> 'a Lwt.t
(** [with_pool uri f] creates a connection pool and executes [f].

    Raises: [Failure] if pool creation fails *)
