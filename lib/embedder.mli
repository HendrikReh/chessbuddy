(** FEN position embedders for semantic search.

    This module provides implementations of the {!PROVIDER} signature for converting
    FEN strings to 768-dimensional vectors. Embeddings enable position similarity search
    via pgvector cosine distance.

    {1 Module Signatures} *)

open! Base

module type PROVIDER = Ingestion_pipeline.EMBEDDER
(** Alias for the embedder interface defined in {!Ingestion_pipeline.EMBEDDER}.

    Embedders must implement:
    - [version : string] - Model version identifier for cache invalidation
    - [embed : fen:string -> float array Lwt.t] - FEN → 768D vector conversion *)

(** {1 Implementations} *)

module Constant : PROVIDER
(** Placeholder embedder that returns zero vectors.

    - [version = "constant-0"]
    - [embed ~fen] returns [Array.create ~len:768 0.]

    Use cases:
    - Testing without external dependencies
    - Development when embedding service unavailable
    - Baseline for benchmarking real embedders

    Limitations:
    - All positions map to identical vectors
    - Similarity search returns arbitrary results
    - Not suitable for production

    Example:
    {[
      let embedder = (module Embedder.Constant : Ingestion_pipeline.EMBEDDER) in
      let%lwt vec = Embedder.Constant.embed ~fen:"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" in
      (* vec = [|0.; 0.; ...; 0.|] (768 zeros) *)
    ]} *)

(** {1 Future Implementations}

    Planned embedders for production use:

    {[
      module Neural : PROVIDER
      (** Neural network-based embedder using trained chess position encoder.
          Requires model weights and inference runtime. *)

      module Hybrid : PROVIDER
      (** Combines handcrafted features (material, pawn structure) with learned representations.
          Balances accuracy and interpretability. *)
    ]}

    See {!Ingestion_pipeline.EMBEDDER} for interface requirements. *)
