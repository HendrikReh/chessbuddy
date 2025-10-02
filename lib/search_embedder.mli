(** Text embedder implementations for search.

    This module provides concrete implementations of the {!Search_indexer.TEXT_EMBEDDER}
    interface for converting text to 1536-dimensional vectors. Currently supports
    OpenAI's text-embedding models. *)

open! Base

module type PROVIDER = Search_indexer.TEXT_EMBEDDER
(** Alias for the text embedder interface.

    Embedders must provide:
    - [model : string] - Model identifier for versioning
    - [embed : text:string -> (float array, string) Result.t Lwt.t] - Text → 1536D vector *)

(** {1 Implementations} *)

module Openai : sig
  val make :
    ?api_key:string ->
    ?model:string ->
    unit ->
    ((module PROVIDER), string) Result.t
  (** [make ?api_key ?model ()] creates an OpenAI text embedder.

      @param api_key OpenAI API key (defaults to [OPENAI_API_KEY] env var)
      @param model Model name (defaults to ["text-embedding-3-small"])

      Returns:
      - [Ok embedder] if initialization succeeds
      - [Error message] if API key is missing or model is invalid

      Example:
      {[
        match Search_embedder.Openai.make ~api_key:"sk-..." () with
        | Error msg -> Printf.eprintf "Failed: %s\n" msg
        | Ok embedder ->
            let module E = (val embedder : Search_indexer.TEXT_EMBEDDER) in
            let%lwt result = E.embed ~text:"chess opening" in
            ...
      ]}

      The returned module implements {!Search_indexer.TEXT_EMBEDDER} and can be
      passed to indexing functions in {!Search_indexer}. *)
end
(** OpenAI text embedding provider.

    Uses the OpenAI API to generate 1536-dimensional embeddings via the
    text-embedding-3-small model (or custom model if specified).

    Requires:
    - Valid OpenAI API key
    - Internet connectivity
    - Rate limiting compliance (handled internally by {!Openai_client})

    See {!Openai_client} for low-level API details. *)
