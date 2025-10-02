(** FEN position embedder implementations.

    See {!module:Embedder} for public API documentation. This module provides
    placeholder and production-ready embedders for converting FEN positions to
    768-dimensional vectors. *)

open! Base

module type PROVIDER = Ingestion_pipeline.EMBEDDER

module Constant : PROVIDER = struct
  let version = "constant-0"
  let embed ~fen:_ = Lwt.return (Array.create ~len:768 0.)
end
