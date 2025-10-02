(** Text indexing for natural language search.

    This module converts chess entities (games, players, FENs, batches, embeddings)
    into searchable text documents with 1536-dimensional embeddings. It handles text
    summarization, truncation, and persistence to the search_documents table. *)

open! Base

(** {1 Text Embedder Interface} *)

module type TEXT_EMBEDDER = sig
  val model : string
  (** Model identifier (e.g., ["text-embedding-3-small"], ["stub-v1"]) *)

  val embed : text:string -> (float array, string) Result.t Lwt.t
  (** [embed ~text] converts text to a 1536-dimensional embedding vector.

      Returns:
      - [Ok embedding] with float array of dimension 1536
      - [Error message] on API failures or invalid input

      The embedding should be deterministic for the same text and model version. *)
end
(** Text embedder interface for 1536D vectors.

    Implementations may use OpenAI's API, local models, or stubs for testing.
    See {!Search_embedder} for concrete implementations. *)

(** {1 Entity Type Constants} *)

val entity_type_game : string
(** Entity type identifier for games: ["game"] *)

val entity_type_fen : string
(** Entity type identifier for FEN positions: ["fen"] *)

val entity_type_player : string
(** Entity type identifier for players: ["player"] *)

val entity_type_batch : string
(** Entity type identifier for ingestion batches: ["batch"] *)

val entity_type_embedding : string
(** Entity type identifier for FEN embeddings: ["embedding"] *)

(** {1 Table Management} *)

val ensure_tables : Database.Pool.t -> unit Lwt.t
(** [ensure_tables pool] creates the [search_documents] table and indexes if missing.

    Safe to call multiple times. Handles schema migrations transparently.

    Raises: [Failure] on database errors *)

(** {1 Text Processing} *)

val truncate : string -> max_len:int -> string
(** [truncate str ~max_len] limits string length with ellipsis.

    If [str] is longer than [max_len], returns first [max_len - 1] characters
    plus "…". Otherwise returns [str] unchanged. *)

val sanitize_for_embedding : string -> string
(** [sanitize_for_embedding text] prepares text for embedding API.

    - Strips leading/trailing whitespace
    - Truncates to 4000 characters max (typical embedding API limit)
    - Returns empty string if input is blank

    Used internally before calling embedder. *)

(** {1 Summarization Functions} *)

val summarize_game :
  Types.Game.t -> batch_label:string -> source_path:string -> string
(** [summarize_game game ~batch_label ~source_path] creates searchable text.

    Includes:
    - Player names and result
    - Event, site, date, round
    - ECO code and opening name
    - Termination reason
    - First 40 moves
    - Batch label and source filename

    Example output:
    {v
    Game: Magnus Carlsen vs Hikaru Nakamura
    Event: Tata Steel Masters
    Date: 2024-01-15
    ECO: B90
    Opening: Sicilian Defense, Najdorf
    Result: 1-0
    Moves: e4 c5 Nf3 d6 d4 cxd4 Nxd4...
    v} *)

val summarize_fen :
  fen_text:string ->
  side_to_move:char ->
  castling:string ->
  en_passant:string option ->
  material_signature:string ->
  string
(** [summarize_fen ~fen_text ~side_to_move ~castling ~en_passant ~material_signature]
    creates FEN description.

    Example:
    {v
    FEN: rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1
    Side to move: b
    Castling rights: KQkq
    En passant square: e3
    Material signature: P8,N2,B2,R2,Q1,K1...
    v} *)

val summarize_player : name:string -> fide_id:string option -> string
(** [summarize_player ~name ~fide_id] creates player description.

    Example:
    {v
    Player: Magnus Carlsen
    FIDE ID: 1503014
    v} *)

val summarize_batch :
  label:string -> source_path:string -> checksum:string -> string
(** [summarize_batch ~label ~source_path ~checksum] creates batch description.

    Example:
    {v
    Batch label: twic-1611
    Source path: /data/games/twic1611.pgn
    Checksum: a3f7b2e...
    v} *)

val summarize_embedding : fen_summary:string -> version:string -> string
(** [summarize_embedding ~fen_summary ~version] creates embedding description.

    Combines FEN summary with embedding model version. *)

(** {1 Indexing Functions} *)

val index_game :
  Database.Pool.t ->
  game_id:Uuidm.t ->
  game:Types.Game.t ->
  batch_label:string ->
  source_path:string ->
  embedder:(module TEXT_EMBEDDER) option ->
  unit Lwt.t
(** [index_game pool ~game_id ~game ~batch_label ~source_path ~embedder]
    indexes a game for search.

    If [embedder] is [None], skips indexing (used when search is disabled).
    Otherwise generates summary, embeds it, and persists to [search_documents].

    Raises: [Failure] on embedding or database errors *)

val index_fen :
  Database.Pool.t ->
  fen_id:Uuidm.t ->
  fen_text:string ->
  side_to_move:char ->
  castling:string ->
  en_passant:string option ->
  material_signature:string ->
  embedder:(module TEXT_EMBEDDER) option ->
  unit Lwt.t
(** [index_fen pool ~fen_id ...] indexes a FEN position for search. *)

val index_player :
  Database.Pool.t ->
  player_id:Uuidm.t ->
  name:string ->
  fide_id:string option ->
  embedder:(module TEXT_EMBEDDER) option ->
  unit Lwt.t
(** [index_player pool ~player_id ~name ~fide_id ~embedder] indexes a player for search. *)

val index_batch :
  Database.Pool.t ->
  batch_id:Uuidm.t ->
  label:string ->
  source_path:string ->
  checksum:string ->
  embedder:(module TEXT_EMBEDDER) option ->
  unit Lwt.t
(** [index_batch pool ~batch_id ...] indexes an ingestion batch for search. *)

val index_embedding :
  Database.Pool.t ->
  fen_id:Uuidm.t ->
  fen_text:string ->
  side_to_move:char ->
  castling:string ->
  en_passant:string option ->
  material_signature:string ->
  version:string ->
  embedder:(module TEXT_EMBEDDER) option ->
  unit Lwt.t
(** [index_embedding pool ~fen_id ... ~version ~embedder] indexes a FEN embedding
    for search.

    Creates searchable text combining FEN description with embedding model version. *)
