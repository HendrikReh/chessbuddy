open! Base
open Lwt.Infix
module Db = Database

let all_entity_types =
  [
    ("game", Search_indexer.entity_type_game);
    ("player", Search_indexer.entity_type_player);
    ("fen", Search_indexer.entity_type_fen);
    ("batch", Search_indexer.entity_type_batch);
    ("embedding", Search_indexer.entity_type_embedding);
  ]

let entity_names = List.map all_entity_types ~f:fst
let available_entity_names () = entity_names
let default_entity_filters = List.map all_entity_types ~f:snd

let resolve_entity_filter raw =
  let normalized = String.lowercase (String.strip raw) in
  List.Assoc.find ~equal:String.equal all_entity_types normalized

let ensure_entity_filters names =
  match names with
  | [] -> Ok default_entity_filters
  | _ ->
      let unknown =
        List.filter names ~f:(fun name ->
            Option.is_none (resolve_entity_filter name))
      in
      if not (List.is_empty unknown) then
        Error
          (Fmt.str "Unknown entity type(s): %s"
             (String.concat ~sep:", " unknown))
      else
        let resolved =
          names
          |> List.filter_map ~f:(fun name -> resolve_entity_filter name)
          |> List.fold_left ~init:[] ~f:(fun acc item ->
                 if List.mem acc item ~equal:String.equal then acc
                 else acc @ [ item ])
        in
        Ok resolved

let search pool ~(embedder : (module Search_indexer.TEXT_EMBEDDER)) ~query
    ~entity_filters ~limit =
  let module Embedder = (val embedder : Search_indexer.TEXT_EMBEDDER) in
  let query = String.strip query in
  if String.is_empty query then Lwt.fail_with "Query must not be empty"
  else
    let limit = Int.max 1 (Int.min 200 limit) in
    let%lwt () = Search_indexer.ensure_tables pool in
    Embedder.embed ~text:query >>= function
    | Error msg -> Lwt.fail_with msg
    | Ok embedding ->
        let entity_array = Array.of_list entity_filters in
        let%lwt hits_res =
          Db.search_documents pool ~query_embedding:embedding
            ~entity_types:entity_array ~limit
        in
        Db.or_fail hits_res
