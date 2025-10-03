open! Base
open Lwt.Infix
module Db = Database

module type TEXT_EMBEDDER = sig
  val model : string
  val embed : text:string -> (float array, string) Result.t Lwt.t
end

let entity_type_game = "game"
let entity_type_fen = "fen"
let entity_type_player = "player"
let entity_type_batch = "batch"
let entity_type_embedding = "embedding"
let ensure_tables pool = Db.ensure_search_documents pool >>= Database.or_fail

let truncate str ~max_len =
  if String.length str <= max_len then str
  else String.prefix str (max_len - 1) ^ "…"

let join_nonempty parts =
  parts
  |> List.filter_map ~f:(function
       | None -> None
       | Some value ->
           let trimmed = String.strip value in
           if String.is_empty trimmed then None else Some trimmed)
  |> String.concat ~sep:"\n"

let summarize_game (game : Types.Game.t) ~batch_label ~source_path =
  let header = game.header in
  let moves =
    game.moves
    |> (fun moves -> List.take moves 40)
    |> List.map ~f:(fun move -> move.Types.Move_feature.san)
    |> String.concat ~sep:" "
  in
  join_nonempty
    [
      Some
        (Printf.sprintf "Game: %s vs %s" header.white_player header.black_player);
      Option.map header.event ~f:(fun ev -> "Event: " ^ ev);
      Option.map header.site ~f:(fun site -> "Site: " ^ site);
      Option.map header.game_date ~f:(fun date ->
          let year, month, day = Ptime.to_date date in
          Printf.sprintf "Date: %04d-%02d-%02d" year month day);
      Option.map header.round ~f:(fun round -> "Round: " ^ round);
      Option.map header.eco ~f:(fun eco -> "ECO: " ^ eco);
      Option.map header.opening ~f:(fun opening -> "Opening: " ^ opening);
      Some (Printf.sprintf "Result: %s" header.result);
      Option.map header.termination ~f:(fun term -> "Termination: " ^ term);
      Some ("Batch label: " ^ batch_label);
      Some ("Source: " ^ Stdlib.Filename.basename source_path);
      (if String.is_empty moves then None else Some ("Moves: " ^ moves));
    ]

let summarize_fen ~fen_text ~side_to_move ~castling ~en_passant
    ~material_signature =
  join_nonempty
    [
      Some ("FEN: " ^ fen_text);
      Some (Printf.sprintf "Side to move: %c" side_to_move);
      Some ("Castling rights: " ^ castling);
      Option.map en_passant ~f:(fun ep -> "En passant square: " ^ ep);
      Some ("Material signature: " ^ material_signature);
    ]

let summarize_player ~name ~fide_id =
  join_nonempty
    [
      Some ("Player: " ^ name);
      Option.map fide_id ~f:(fun id -> "FIDE ID: " ^ id);
    ]

let summarize_batch ~label ~source_path ~checksum =
  join_nonempty
    [
      Some ("Batch label: " ^ label);
      Some ("Source path: " ^ source_path);
      Some ("Checksum: " ^ checksum);
    ]

let summarize_embedding ~fen_summary ~version =
  join_nonempty
    [
      Some "FEN embedding";
      Some fen_summary;
      Some ("Embedding version: " ^ version);
    ]

let sanitize_for_embedding text =
  let trimmed = String.strip text in
  let truncated =
    if String.length trimmed > 4000 then truncate trimmed ~max_len:4000
    else trimmed
  in
  truncated

let index_document pool ~entity_type ~entity_id ~content
    ~(embedder : (module TEXT_EMBEDDER) option) =
  match embedder with
  | None -> Lwt.return_unit
  | Some (module Embed) -> (
      let prepared = sanitize_for_embedding content in
      if String.is_empty prepared then Lwt.return_unit
      else
        Embed.embed ~text:prepared >>= function
        | Error msg -> Lwt.fail_with msg
        | Ok embedding ->
            Db.upsert_search_document pool ~entity_type ~entity_id
              ~content:prepared ~embedding ~model:Embed.model
            >>= Database.or_fail)

let index_game pool ~(game_id : Uuidm.t) ~(game : Types.Game.t) ~batch_label
    ~source_path ~embedder =
  let content = summarize_game game ~batch_label ~source_path in
  index_document pool ~entity_type:entity_type_game ~entity_id:game_id ~content
    ~embedder

let index_fen pool ~(fen_id : Uuidm.t) ~fen_text ~side_to_move ~castling
    ~en_passant ~material_signature ~embedder =
  let content =
    summarize_fen ~fen_text ~side_to_move ~castling ~en_passant
      ~material_signature
  in
  index_document pool ~entity_type:entity_type_fen ~entity_id:fen_id ~content
    ~embedder

let index_player pool ~(player_id : Uuidm.t) ~name ~fide_id ~embedder =
  let content = summarize_player ~name ~fide_id in
  index_document pool ~entity_type:entity_type_player ~entity_id:player_id
    ~content ~embedder

let index_batch pool ~(batch_id : Uuidm.t) ~label ~source_path ~checksum
    ~embedder =
  let content = summarize_batch ~label ~source_path ~checksum in
  index_document pool ~entity_type:entity_type_batch ~entity_id:batch_id
    ~content ~embedder

let index_embedding pool ~(fen_id : Uuidm.t) ~fen_text ~side_to_move ~castling
    ~en_passant ~material_signature ~version ~embedder =
  let fen_summary =
    summarize_fen ~fen_text ~side_to_move ~castling ~en_passant
      ~material_signature
  in
  let content = summarize_embedding ~fen_summary ~version in
  index_document pool ~entity_type:entity_type_embedding ~entity_id:fen_id
    ~content ~embedder
