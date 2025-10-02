(** PGN (Portable Game Notation) parser for chess games.

    This module streams games from PGN files, extracting headers (players, event,
    date, ECO codes) and moves (SAN notation, comments, variations, NAGs). It handles
    multi-game files, UTF-8 sanitization, and preserves all annotations for downstream
    analysis.

    {1 Core Functions} *)

open! Base

val fold_games :
  string -> init:'a -> f:('a -> Types.Game.t -> 'a Lwt.t) -> 'a Lwt.t
(** [fold_games path ~init ~f] parses a PGN file and folds over games.

    @param path Filesystem path to the PGN file
    @param init Initial accumulator value
    @param f Reduction function called for each parsed game

    The parser:
    - Detects game boundaries by tracking header vs. move context
    - Preserves move annotations (comments [{text}], variations [(...)], NAGs [$n])
    - Generates placeholder FENs with accurate side-to-move and move numbers
    - Sanitizes malformed UTF-8 to ASCII-safe characters

    Example:
    {[
      let%lwt count =
        fold_games "games.pgn" ~init:0 ~f:(fun acc _game ->
          Lwt.return (acc + 1))
      in
      Printf.printf "Parsed %d games\n" count
    ]}

    Raises:
    - [Sys_error] if file cannot be opened
    - [Failure] if required PGN headers (White, Black) are missing *)

(** {1 Header Parsing} *)

type header_map
(** Internal map type for PGN headers *)

val parse_headers : string list -> header_map
(** [parse_headers lines] extracts PGN header tags into a map.

    Each line should match [[Tag "Value"]] format.
    Returns normalized (lowercase) keys mapping to raw values.

    Example:
    {[
      let headers = parse_headers [
        "[Event \"FIDE World Cup\"]";
        "[White \"Carlsen, Magnus\"]"
      ] in
      (* headers contains: {event -> "FIDE World Cup", white -> "Carlsen, Magnus"} *)
    ]} *)

val build_header : header_map -> Types.Game_header.t
(** [build_header map] constructs a typed game header from raw PGN headers.

    Parses dates (YYYY.MM.DD format), ELO ratings (integers), and FIDE IDs.
    Missing optional fields become [None].

    Raises: [Failure] if required headers [White] or [Black] are missing *)

(** {1 Move Parsing} *)

val parse_moves : string list -> Types.Move_feature.t list
(** [parse_moves lines] extracts moves with annotations from PGN move text.

    Recognizes:
    - Move tokens: SAN notation (e.g., [e4], [Nf3], [O-O])
    - Comments: [{This is brilliant!}]
    - Variations: [(1...e5 2.Nf3)]
    - NAGs: [$1] (good move), [$2] (mistake), etc.

    Returns moves with:
    - Accurate ply numbering (1, 2, 3, ...)
    - Side-to-move alternation
    - Placeholder FENs (starting position board, correct move numbers)
    - All annotations attached to appropriate moves

    Example PGN:
    {v
    1. e4 {Excellent opening} e5 2. Nf3 $1 Nc6 (2...Nf6 3.Nc3) 3. Bb5
    v}

    Produces 5 moves with:
    - Move 1 (e4): [comments_after = ["Excellent opening"]]
    - Move 2 (e5): no annotations
    - Move 3 (Nf3): [nags = [1]]
    - Move 4 (Nc6): [variations = ["2...Nf6 3.Nc3"]]
    - Move 5 (Bb5): no annotations *)

(** {1 Utilities} *)

val sanitize_utf8 : string -> string
(** [sanitize_utf8 str] removes malformed UTF-8 sequences.

    Keeps only:
    - ASCII printable characters (32-126)
    - Whitespace (tab, newline, carriage return)

    Used to handle legacy PGN files with encoding issues. *)

val parse_date : string -> Ptime.t option
(** [parse_date str] converts PGN date format to [Ptime.t].

    Accepts: [YYYY.MM.DD] (e.g., ["2024.01.15"])
    Returns: [None] if format is invalid or uses [?] placeholders *)

(** {1 Internal Helpers}

    Exposed for testing purposes. *)

val header_value : header_map -> string -> string option
(** [header_value map key] looks up a normalized header key.

    Returns [None] if key is missing or value is ["?"] (PGN unknown marker). *)

val required : header_map -> string -> string
(** [required map key] retrieves a mandatory header value.

    Raises: [Failure] if key is missing *)

val starts_with : string -> int -> string -> bool
(** [starts_with str idx prefix] checks if [str] has [prefix] at position [idx] *)

val string_has : (char -> bool) -> string -> bool
(** [string_has predicate str] returns [true] if any character satisfies [predicate] *)

val sanitize : string -> string
(** [sanitize value] normalizes to lowercase and strips whitespace *)

module Default : Ingestion_pipeline.PGN_SOURCE
(** Default PGN source implementation.

    Implements the {!Ingestion_pipeline.PGN_SOURCE} interface with full support for:
    - Multi-game PGN files
    - UTF-8 sanitization
    - Move annotations (comments, variations, NAGs)
    - Placeholder FEN generation

    This is the primary parser used by the ingestion pipeline. *)
