module Db = Database

module type EMBEDDER = sig
  val version : string
  val embed : fen:string -> float array Lwt.t
end

module type PGN_SOURCE = sig
  val fold_games :
    string ->
    init:'a ->
    f:('a -> Types.Game.t -> 'a Lwt.t) ->
    'a Lwt.t
end

let compute_checksum path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let chunk = Bytes.create 4096 in
      let rec loop ctx =
        match input ic chunk 0 (Bytes.length chunk) with
        | 0 -> ctx
        | len ->
            let data = Bytes.sub_string chunk 0 len in
            let ctx = Digestif.SHA256.feed_string ctx data in
            loop ctx
      in
      Digestif.SHA256.(loop (init ()) |> get |> to_hex))

let or_fail = function
  | Ok v -> Lwt.return v
  | Error err -> Lwt.fail_with (Caqti_error.show err)

let record_player pool ~name ~fide_id =
  let%lwt res = Db.upsert_player pool ~full_name:name ~fide_id in
  or_fail res

let record_game pool ~batch_id ~white_id ~black_id ~(game : Types.Game.t) =
  let%lwt res =
    Db.record_game pool ~white_id ~black_id ~header:game.header ~source_pgn:game.source_pgn ~batch_id
  in
  or_fail res

let ensure_fen pool ~fen_text ~side_to_move ~castling ~en_passant ~material_signature =
  let%lwt res =
    Db.upsert_fen pool ~fen_text ~side_to_move ~castling ~en_passant ~material_signature
  in
  or_fail res

let material_signature board =
  (* Placeholder for a richer material signature derived from ocamlchess. *)
  Digestif.SHA1.(to_hex (digest_string board))

let motifs_for_move (_move : Types.Move_feature.t) =
  []

let fen_components fen =
  match String.split_on_char ' ' fen with
  | _board :: active :: castling :: en_passant :: _halfmove :: _fullmove :: _ ->
      let side_to_move = if String.length active > 0 then active.[0] else 'w' in
      let en_passant = if en_passant = "-" then None else Some en_passant in
      (side_to_move, castling, en_passant)
  | _ -> ('w', "-", None)

let process_move pool ~game_id ~(embedder : (module EMBEDDER)) ~(move : Types.Move_feature.t) =
  let module Embedder = (val embedder : EMBEDDER) in
  let side_to_move, castling, en_passant = fen_components move.fen_after in
  let%lwt fen_id =
    ensure_fen pool
      ~fen_text:move.Types.Move_feature.fen_after
      ~side_to_move
      ~castling
      ~en_passant
      ~material_signature:(material_signature move.fen_after)
  in
  let%lwt res = Db.record_position pool ~game_id ~move ~fen_id ~side_to_move in
  let%lwt () = or_fail res in
  let%lwt embedding = Embedder.embed ~fen:move.fen_after in
  let%lwt res = Db.record_embedding pool ~fen_id ~embedding ~version:Embedder.version in
  or_fail res

let process_game pool ~(embedder : (module EMBEDDER)) ~batch_id ~(game : Types.Game.t) =
  let%lwt white_id = record_player pool ~name:game.header.white_player ~fide_id:game.header.white_fide_id in
  let%lwt black_id = record_player pool ~name:game.header.black_player ~fide_id:game.header.black_fide_id in
  let%lwt game_id = record_game pool ~batch_id ~white_id ~black_id ~game in
  Lwt_list.iter_s (fun move -> process_move pool ~game_id ~embedder ~move) game.moves

let ingest_file (module Source : PGN_SOURCE) pool ~(embedder : (module EMBEDDER)) ~pgn_path ~batch_label =
  let checksum = compute_checksum pgn_path in
  let%lwt res = Db.create_batch pool ~source_path:pgn_path ~label:batch_label ~checksum in
  let%lwt batch_id = or_fail res in
  Source.fold_games pgn_path ~init:() ~f:(fun () game ->
      process_game pool ~embedder ~batch_id ~game)

let with_pool uri f =
  match Db.Pool.create uri with
  | Error err -> Lwt.fail_with (Caqti_error.show err)
  | Ok pool -> f pool
