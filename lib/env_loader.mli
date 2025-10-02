(** Environment variable loader with .env file support.

    This module provides unified access to configuration from environment
    variables and .env files. Environment variables take precedence over .env
    file values. *)

open! Base

(** {1 Environment Variable Lookup} *)

val lookup : ?path:string -> string -> string option
(** [lookup ?path key] retrieves a configuration value.

    Lookup order: 1. System environment variable (via [Sys.getenv]) 2. .env file
    at [path] (defaults to [".env"])

    @param path Path to .env file (default: [".env"])
    @param key Environment variable name

    Returns:
    - [Some value] if key is found
    - [None] if key is not in environment or .env file

    Example:
    {[
      match Env_loader.lookup "OPENAI_API_KEY" with
      | Some key -> Printf.printf "Found API key\n"
      | None -> Printf.eprintf "API key not configured\n"
    ]}

    .env file format:
    {v
    # Comments start with #
    API_KEY=sk-1234567890
    DB_URI=postgresql://localhost/db

    # Empty lines and whitespace are ignored
    TIMEOUT=30
    v}

    The .env file is only read when the environment variable is not set,
    providing local development overrides without modifying system environment.
*)

(** {1 .env File Parsing} *)

val read_env_file : string -> (string * string) list
(** [read_env_file path] parses a .env file into key-value pairs.

    @param path Filesystem path to .env file

    Returns: List of [(key, value)] tuples

    Parsing rules:
    - Lines starting with [#] are comments (ignored)
    - Empty lines and whitespace-only lines are skipped
    - Format: [KEY=VALUE] (whitespace around [=] is trimmed)
    - Keys must be non-empty after trimming

    Example:
    {[
      let pairs = Env_loader.read_env_file ".env.production" in
      List.iter pairs ~f:(fun (k, v) -> Printf.printf "%s = %s\n" k v)
    ]}

    Returns empty list if file doesn't exist. *)

(** {1 Internal Helpers} *)

val sanitize : string -> string option
(** [sanitize line] filters out comments and empty lines.

    Returns:
    - [None] for comments (lines starting with [#])
    - [None] for empty or whitespace-only lines
    - [Some trimmed_line] otherwise *)

val split_kv : string -> (string * string) option
(** [split_kv line] parses a "KEY=VALUE" line.

    Returns:
    - [Some (key, value)] if line contains [=] and key is non-empty
    - [None] if no [=] or key is empty after trimming

    Both key and value are stripped of leading/trailing whitespace. *)
