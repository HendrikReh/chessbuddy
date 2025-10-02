(** OpenAI API client for text embeddings.

    Low-level HTTP client for OpenAI's text-embedding API. Handles authentication,
    request formatting, response parsing, and error handling. *)

open! Base

(** {1 Client Type} *)

type t
(** OpenAI API client handle.

    Contains:
    - API key for authentication
    - Model identifier (e.g., "text-embedding-3-small")
    - API endpoint URI

    Create with {!create}. *)

(** {1 Client Creation} *)

val create :
  ?api_key:string ->
  ?model:string ->
  ?endpoint:Uri.t ->
  unit ->
  (t, string) Result.t
(** [create ?api_key ?model ?endpoint ()] initializes an OpenAI client.

    @param api_key OpenAI API key. If not provided, reads from [OPENAI_API_KEY] env var.
    @param model Model name. Defaults to ["gpt-5"]. For embeddings use ["text-embedding-3-small"]
    or ["text-embedding-3-large"].
    @param endpoint API endpoint URI. Defaults to [https://api.openai.com/v1/embeddings].

    Returns:
    - [Ok client] if API key is available
    - [Error "OPENAI_API_KEY is not set"] if API key missing

    Example:
    {[
      match Openai_client.create ~model:"text-embedding-3-small" () with
      | Error msg -> Printf.eprintf "Error: %s\n" msg
      | Ok client ->
          let%lwt result = Openai_client.embed client "Hello world" in
          ...
    ]} *)

(** {1 Client Operations} *)

val model : t -> string
(** [model client] returns the configured model identifier. *)

val embed : t -> string -> (float array, string) Result.t Lwt.t
(** [embed client text] generates a 1536-dimensional embedding vector.

    Makes HTTP POST request to OpenAI's embeddings API with:
    - Bearer token authentication
    - JSON payload: [{"model": "...", "input": "..."}]

    Returns:
    - [Ok vector] with float array (typically 1536 dimensions)
    - [Error message] on:
      - HTTP errors (4xx, 5xx)
      - API errors (rate limits, invalid input)
      - JSON parsing failures
      - Network issues

    Example response handling:
    {[
      let%lwt result = embed client "chess opening theory" in
      match result with
      | Ok embedding ->
          Printf.printf "Generated %d-dimensional vector\n" (Array.length embedding)
      | Error msg ->
          Printf.eprintf "Embedding failed: %s\n" msg
    ]}

    Note: The default model parameter in {!create} is ["gpt-5"] which is incorrect
    for embeddings. Always specify [~model:"text-embedding-3-small"] or similar. *)

(** {1 Internal Functions} *)

val fetch_api_key : unit -> (string, string) Result.t
(** [fetch_api_key ()] retrieves API key from [OPENAI_API_KEY] environment variable.

    Exposed for testing. Normally called internally by {!create}. *)

val parse_embedding : string -> (float array, string) Result.t
(** [parse_embedding json_body] extracts embedding vector from API response.

    Exposed for testing. Handles:
    - Error responses: [{"error": {"message": "..."}}]
    - Success responses: [{"data": [{"embedding": [...]}]}]

    Raises: Type errors if JSON structure is unexpected. *)
