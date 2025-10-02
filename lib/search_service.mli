(** Natural language search service for ChessBuddy.

    This module provides semantic search over indexed chess entities (games, players,
    FENs, batches, embeddings) using text embeddings and vector similarity. It handles
    query embedding, entity filtering, and result ranking.

    {1 Entity Types} *)

open! Base

val available_entity_names : unit -> string list
(** [available_entity_names ()] returns supported entity types for filtering.

    Returns: [["game"; "player"; "fen"; "batch"; "embedding"]]

    Used by CLI to validate user input and display available options. *)

val resolve_entity_filter : string -> string option
(** [resolve_entity_filter raw] normalizes and resolves an entity type name.

    Accepts case-insensitive input with whitespace (e.g., [" Game "] → ["game"]).

    Returns:
    - [Some entity_id] if recognized
    - [None] if unknown

    Example:
    {[
      resolve_entity_filter "PLAYER" = Some "chessbuddy_player"
      resolve_entity_filter "unknown" = None
    ]} *)

val ensure_entity_filters : string list -> (string list, string) Result.t
(** [ensure_entity_filters names] validates and normalizes entity type filters.

    @param names List of entity type names (e.g., [["game"; "player"]])

    Returns:
    - [Ok entity_ids] if all names are valid (deduplicated)
    - [Ok default_filters] if [names] is empty (searches all types)
    - [Error message] if any name is unrecognized

    Example:
    {[
      ensure_entity_filters [] = Ok ["game_id"; "player_id"; "fen_id"; ...]
      ensure_entity_filters ["game"; "player"] = Ok ["game_id"; "player_id"]
      ensure_entity_filters ["game"; "invalid"] = Error "Unknown entity type(s): invalid"
    ]} *)

(** {1 Search Functions} *)

val search :
  Database.Pool.t ->
  embedder:(module Search_indexer.TEXT_EMBEDDER) ->
  query:string ->
  entity_filters:string list ->
  limit:int ->
  Database.search_hit list Lwt.t
(** [search pool ~embedder ~query ~entity_filters ~limit] performs natural language search.

    Workflow:
    1. Validate query is non-empty (stripped)
    2. Clamp limit to [1, 200] range
    3. Ensure [search_documents] table exists
    4. Embed query text to 1536-dimensional vector
    5. Execute vector similarity search filtered by entity types
    6. Return ranked results with relevance scores

    @param pool Database connection pool
    @param embedder Text embedding model (e.g., OpenAI, stub)
    @param query Natural language search string
    @param entity_filters List of entity type IDs from {!ensure_entity_filters}
    @param limit Maximum results to return (clamped to 1-200)

    Returns: List of {!Database.search_hit} ordered by similarity (descending score)

    Raises:
    - [Failure "Query must not be empty"] if query is blank after stripping
    - [Failure] on embedding errors or database failures

    Example:
    {[
      let pool = Database.Pool.create (Uri.of_string db_uri) in
      let embedder = (module Search_embedder.OpenAI : Search_indexer.TEXT_EMBEDDER) in
      let%lwt hits =
        match ensure_entity_filters ["game"; "player"] with
        | Error msg -> Lwt.fail_with msg
        | Ok filters ->
            search pool ~embedder ~query:"Sicilian Defense games by Kasparov"
              ~entity_filters:filters ~limit:10
      in
      List.iter hits ~f:(fun hit ->
        Printf.printf "%s (score: %.3f): %s\n"
          hit.entity_type hit.score hit.content)
    ]} *)
