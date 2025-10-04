open! Base
open Cmdliner
open Chessbuddy
open Lwt.Infix
module Fmt = Stdlib.Format
module Yojson = Yojson.Safe

let uri_conv : Uri.t Arg.conv =
  let parse s =
    try Ok (Uri.of_string s)
    with exn ->
      let msg =
        Fmt.asprintf "invalid URI %S (%s)" s (Stdlib.Printexc.to_string exn)
      in
      Error (`Msg msg)
  in
  let print fmt uri = Fmt.pp_print_string fmt (Uri.to_string uri) in
  Arg.conv ~docv:"URI" (parse, print)

let uuid_conv : Uuidm.t Arg.conv =
  let parse s =
    match Uuidm.of_string s with
    | Some uuid -> Ok uuid
    | None -> Error (`Msg (Fmt.asprintf "invalid UUID %S" s))
  in
  let print fmt uuid = Fmt.pp_print_string fmt (Uuidm.to_string uuid) in
  Arg.conv ~docv:"UUID" (parse, print)

let color_conv : Chess_engine.color Arg.conv =
  let parse = function
    | "white" | "w" -> Ok Chess_engine.White
    | "black" | "b" -> Ok Chess_engine.Black
    | s -> Error (`Msg (Fmt.asprintf "invalid color %S (use white|black)" s))
  in
  let print fmt = function
    | Chess_engine.White -> Fmt.pp_print_string fmt "white"
    | Chess_engine.Black -> Fmt.pp_print_string fmt "black"
  in
  Arg.conv ~docv:"COLOR" (parse, print)

let color_to_string = function
  | Chess_engine.White -> "white"
  | Chess_engine.Black -> "black"

let date_conv : Ptime.t Arg.conv =
  let parse s =
    try
      Stdlib.Scanf.sscanf s "%d-%d-%d" (fun year month day ->
          match Ptime.of_date (year, month, day) with
          | Some t -> Ok t
          | None ->
              Error
                (`Msg (Fmt.asprintf "invalid date %S (expect YYYY-MM-DD)" s)))
    with _ ->
      Error (`Msg (Fmt.asprintf "invalid date %S (expect YYYY-MM-DD)" s))
  in
  let print fmt t =
    let year, month, day = Ptime.to_date t in
    Fmt.fprintf fmt "%04d-%02d-%02d" year month day
  in
  Arg.conv ~docv:"YYYY-MM-DD" (parse, print)

let result_conv : string Arg.conv =
  let parse s =
    match String.strip s with
    | ("1-0" | "0-1" | "1/2-1/2" | "*") as r -> Ok r
    | other ->
        Error
          (`Msg
             (Fmt.asprintf "invalid result %S (use 1-0, 0-1, 1/2-1/2, or *)"
                other))
  in
  let print fmt r = Fmt.pp_print_string fmt r in
  Arg.conv ~docv:"RESULT" (parse, print)

type output_format = Table | Json | Csv

let output_format_conv : output_format Arg.conv =
  let parse = function
    | "table" -> Ok Table
    | "json" -> Ok Json
    | "csv" -> Ok Csv
    | other ->
        Error
          (`Msg
             (Fmt.asprintf "invalid output format %S (use table|json|csv)" other))
  in
  let print fmt = function
    | Table -> Fmt.pp_print_string fmt "table"
    | Json -> Fmt.pp_print_string fmt "json"
    | Csv -> Fmt.pp_print_string fmt "csv"
  in
  Arg.conv ~docv:"FORMAT" (parse, print)

let format_exn = function
  | Failure msg -> msg
  | exn -> Stdlib.Printexc.to_string exn

let run_lwt action =
  let open Lwt.Infix in
  Lwt_main.run
    (Lwt.catch
       (fun () -> action () >|= fun () -> `Ok ())
       (fun exn ->
         let msg = Fmt.asprintf "error: %s" (format_exn exn) in
         Lwt.return (`Error (false, msg))))

let pp_timestamp ts = Ptime.to_rfc3339 ~tz_offset_s:0 ts

let format_date_opt = function
  | None -> "-"
  | Some date ->
      let year, month, day = Ptime.to_date date in
      Fmt.asprintf "%04d-%02d-%02d" year month day

let truncate max_len s =
  if String.length s <= max_len then s
  else
    let usable = if max_len > 1 then max_len - 1 else max_len in
    String.prefix s usable ^ "…"

let with_raw_mode f =
  let fd = Unix.descr_of_in_channel Stdlib.stdin in
  if not (Unix.isatty fd) then f ()
  else
    let original = Unix.tcgetattr fd in
    let raw = { original with Unix.c_echo = false; c_icanon = false } in
    let set attrs =
      try Unix.tcsetattr fd Unix.TCSADRAIN attrs with Unix.Unix_error _ -> ()
    in
    Lwt.finalize
      (fun () ->
        set raw;
        f ())
      (fun () ->
        set original;
        Lwt.return_unit)

let fail_on_error = function
  | Ok v -> Lwt.return v
  | Error err -> Lwt.fail_with (Caqti_error.show err)

let ( let* ) = Lwt.bind

let print_fen_info (info : Database.fen_info) =
  Fmt.printf "FEN: %s@." info.fen_text;
  Fmt.printf "  ID: %s@." (Uuidm.to_string info.fen_id);
  Fmt.printf "  Side to move: %c@." info.side_to_move;
  Fmt.printf "  Castling: %s@." info.castling;
  (match info.en_passant with
  | None -> Fmt.printf "  En passant: -@."
  | Some ep -> Fmt.printf "  En passant: %s@." ep);
  Fmt.printf "  Material signature: %s@." info.material_signature;
  Fmt.printf "  Usage count: %d@." info.usage_count;
  match info.embedding_version with
  | None -> Fmt.printf "  Embedding: (missing)@."
  | Some version ->
      Fmt.printf "  Embedding version: %s@." version;
      Option.iter info.embedding ~f:(fun emb ->
          let preview =
            if String.length emb > 80 then String.prefix emb 80 ^ "…" else emb
          in
          Fmt.printf "  Embedding preview: %s@." preview)

let similar_action uri fen_text limit =
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool ->
        let* fen_res = Database.get_fen_by_text pool ~fen_text in
        let* fen_opt = fail_on_error fen_res in
        match fen_opt with
        | None ->
            Fmt.printf "No stored embedding found for FEN: %s@." fen_text;
            Lwt.return_unit
        | Some base_fen -> (
            print_fen_info base_fen;
            match base_fen.embedding_version with
            | None ->
                Fmt.printf "Cannot compute similarities without an embedding.@.";
                Lwt.return_unit
            | Some _ ->
                let sample_limit = Int.max 1 limit in
                let* sims_res =
                  Database.find_similar_fens pool ~fen_id:base_fen.fen_id
                    ~limit:sample_limit
                in
                let* sims = fail_on_error sims_res in
                let filtered =
                  List.filter sims ~f:(fun s ->
                      not (Uuidm.equal s.Database.fen_id base_fen.fen_id))
                in
                (match filtered with
                | [] -> Fmt.printf "No similar FENs found.@."
                | _ ->
                    Fmt.printf "Similar FENs:@.";
                    List.iteri filtered ~f:(fun idx sim ->
                        Fmt.printf
                          "  %d. %s (distance %.4f, usage %d, version %s)@."
                          (idx + 1) sim.Database.fen_text sim.Database.distance
                          sim.Database.usage_count
                          sim.Database.embedding_version));
                Lwt.return_unit))
  in
  run_lwt action

let game_action uri game_id show_pgn =
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool ->
        let* detail_res = Database.get_game_detail pool ~game_id in
        let* detail_opt = fail_on_error detail_res in
        match detail_opt with
        | None ->
            Fmt.printf "No game found for %s@." (Uuidm.to_string game_id);
            Lwt.return_unit
        | Some detail ->
            let header = detail.Database.header in
            Fmt.printf "%s vs %s (%s)@." header.white_player header.black_player
              header.result;
            Option.iter header.event ~f:(fun event ->
                Fmt.printf "  Event: %s@." event);
            Option.iter header.site ~f:(fun site ->
                Fmt.printf "  Site: %s@." site);
            Option.iter header.game_date ~f:(fun date ->
                Fmt.printf "  Date: %s@." (pp_timestamp date));
            Option.iter header.round ~f:(fun round ->
                Fmt.printf "  Round: %s@." round);
            Option.iter header.eco ~f:(fun eco -> Fmt.printf "  ECO: %s@." eco);
            Option.iter header.opening ~f:(fun opening ->
                Fmt.printf "  Opening: %s@." opening);
            (match (header.white_elo, header.black_elo) with
            | Some w, Some b -> Fmt.printf "  Elos: %d vs %d@." w b
            | Some w, None -> Fmt.printf "  White Elo: %d@." w
            | None, Some b -> Fmt.printf "  Black Elo: %d@." b
            | _ -> ());
            Option.iter header.white_fide_id ~f:(fun fid ->
                Fmt.printf "  White FIDE: %s@." fid);
            Option.iter header.black_fide_id ~f:(fun fid ->
                Fmt.printf "  Black FIDE: %s@." fid);
            Option.iter header.termination ~f:(fun term ->
                Fmt.printf "  Termination: %s@." term);
            Option.iter detail.batch_label ~f:(fun label ->
                Fmt.printf "  Batch: %s@." label);
            Fmt.printf "  Ingested: %s@." (pp_timestamp detail.ingested_at);
            Fmt.printf "  Moves stored: %d@." detail.move_count;
            if show_pgn then Fmt.printf "@[%s@]@." detail.source_pgn
            else Fmt.printf "  (use --pgn to print full PGN record)@.";
            Lwt.return_unit)
  in
  run_lwt action

let games_action uri page page_size interactive =
  let action () =
    let initial_page = Int.max 1 page in
    let size = Int.min 200 (Int.max 1 page_size) in
    let print_page pool current_page =
      let offset = (current_page - 1) * size in
      let* games_res = Database.list_games pool ~limit:size ~offset in
      let* games = fail_on_error games_res in
      let* () =
        if List.is_empty games then (
          Fmt.printf "No games found for page %d.@." current_page;
          Lwt.return_unit)
        else (
          Fmt.printf "%-10s  %-24s  %-20s  %-20s  %-5s  %-6s  %-36s@." "Date"
            "Event" "White" "Black" "Moves" "Result" "Game ID";
          List.iter games ~f:(fun game ->
              let date_str = format_date_opt game.game_date in
              let event =
                match game.event with None -> "-" | Some e -> truncate 24 e
              in
              let white = truncate 20 game.white_player in
              let black = truncate 20 game.black_player in
              Fmt.printf "%-10s  %-24s  %-20s  %-20s  %5d  %-6s  %s@." date_str
                event white black game.move_count game.result
                (Uuidm.to_string game.game_id));
          Lwt.return_unit)
      in
      Fmt.printf "Page %d (page size %d).@." current_page size;
      Fmt.printf "@?";
      Lwt.return games
    in
    let rec prompt_navigation () =
      let* () =
        Lwt_io.write Lwt_io.stdout "Command ([n]ext, [p]rev, [q]uit): "
      in
      let* () = Lwt_io.flush Lwt_io.stdout in
      let* char_opt = Lwt_io.read_char_opt Lwt_io.stdin in
      match char_opt with
      | None -> Lwt.return `Quit
      | Some ch -> (
          let lower = Stdlib.Char.lowercase_ascii ch in
          let to_echo = match lower with '\n' | '\r' -> None | _ -> Some ch in
          let* () =
            match to_echo with
            | None -> Lwt.return_unit
            | Some c -> Lwt_io.write_char Lwt_io.stdout c
          in
          let* () = Lwt_io.write_char Lwt_io.stdout '\n' in
          let* () = Lwt_io.flush Lwt_io.stdout in
          match lower with
          | 'n' | '\n' -> Lwt.return `Next
          | 'p' -> Lwt.return `Prev
          | 'q' -> Lwt.return `Quit
          | _ ->
              Fmt.printf "Unrecognized command %S.@." (String.of_char ch);
              Fmt.printf "@?";
              prompt_navigation ())
    in
    let rec loop pool current_page =
      let* games = print_page pool current_page in
      let empty_page = List.is_empty games in
      if not interactive then Lwt.return_unit
      else if empty_page && current_page = 1 then Lwt.return_unit
      else (
        if empty_page then (
          Fmt.printf
            "Reached an empty page. Use [p] to go back or [q] to quit.@.";
          Fmt.printf "@?");
        let* command = prompt_navigation () in
        match command with
        | `Quit -> Lwt.return_unit
        | `Next -> loop pool (current_page + 1)
        | `Prev when current_page = 1 ->
            Fmt.printf "Already at the first page.@.";
            Fmt.printf "@?";
            loop pool current_page
        | `Prev -> loop pool (current_page - 1))
    in
    Ingestion_pipeline.with_pool uri (fun pool ->
        let run () = loop pool initial_page in
        if interactive then with_raw_mode run else run ())
  in
  run_lwt action

let search_action uri query entities limit model =
  let action () =
    let* entity_filters =
      match Search_service.ensure_entity_filters entities with
      | Ok filters -> Lwt.return filters
      | Error msg -> Lwt.fail_with msg
    in
    match Search_embedder.Openai.make ~model () with
    | Error msg -> Lwt.fail_with msg
    | Ok embedder ->
        let* hits =
          Ingestion_pipeline.with_pool uri (fun pool ->
              Search_service.search pool ~embedder ~query ~entity_filters ~limit)
        in
        if List.is_empty hits then Fmt.printf "No matches for %S.@." query
        else (
          Fmt.printf "%-10s  %-8s  %-12s  %-36s  %s@." "Type" "Score" "Model"
            "Entity ID" "Preview";
          List.iter hits ~f:(fun hit ->
              let preview = truncate 80 hit.Database.content in
              let label = String.capitalize hit.Database.entity_type in
              Fmt.printf "%-10s  %-8.4f  %-12s  %-36s  %s@." label
                hit.Database.score hit.Database.model
                (Uuidm.to_string hit.Database.entity_id)
                preview));
        Lwt.return_unit
  in
  run_lwt action

let fen_action uri fen_id =
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool ->
        let* fen_res = Database.get_fen_details pool ~fen_id in
        let* fen_opt = fail_on_error fen_res in
        match fen_opt with
        | None ->
            Fmt.printf "No FEN found for %s@." (Uuidm.to_string fen_id);
            Lwt.return_unit
        | Some info ->
            print_fen_info info;
            Lwt.return_unit)
  in
  run_lwt action

let player_action uri name limit =
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool ->
        let* players_res = Database.search_players pool ~query:name ~limit in
        let* players = fail_on_error players_res in
        match players with
        | [] ->
            Fmt.printf "No players matched %S@." name;
            Lwt.return_unit
        | players ->
            Fmt.printf "Players matching %S:@." name;
            List.iter players ~f:(fun p ->
                Fmt.printf "- %s (%s)@." p.Database.full_name
                  (Uuidm.to_string p.Database.player_id);
                Option.iter p.Database.fide_id ~f:(fun fid ->
                    Fmt.printf "    FIDE: %s@." fid);
                Fmt.printf "    Games: %d@." p.Database.total_games;
                Option.iter p.Database.last_played ~f:(fun last ->
                    Fmt.printf "    Last played: %s@." (pp_timestamp last));
                Option.iter p.Database.latest_standard_elo ~f:(fun elo ->
                    Fmt.printf "    Latest standard Elo: %d@." elo));
            Lwt.return_unit)
  in
  run_lwt action

let option_to_yojson f = function None -> `Null | Some v -> f v

let with_output_channel output_file ~binary f =
  match output_file with
  | None ->
      let* () = f Stdlib.stdout in
      Stdlib.flush Stdlib.stdout;
      Lwt.return_unit
  | Some path ->
      let oc = if binary then Stdlib.open_out_bin path else Stdlib.open_out path in
      Lwt.finalize
        (fun () ->
          let* () = f oc in
          Stdlib.flush oc;
          Lwt.return_unit)
        (fun () ->
          Stdlib.close_out_noerr oc;
          Lwt.return_unit)

let summarize (games : Database.pattern_game list) =
  let count = List.length games in
  let total_confidence =
    List.fold games ~init:0.0 ~f:(fun acc game -> acc +. game.confidence)
  in
  let avg_confidence =
    if Int.equal count 0 then 0.0 else total_confidence /. Float.of_int count
  in
  let white_count =
    List.count games ~f:(fun game -> Poly.equal game.detected_by Chess_engine.White)
  in
  let black_count = count - white_count in
  let color_summary =
    Stdlib.Printf.sprintf "white=%d, black=%d" white_count black_count
  in
  let dates = List.filter_map games ~f:(fun game -> game.game_date) in
  let date_summary =
    match
      ( List.min_elt dates ~compare:Ptime.compare,
        List.max_elt dates ~compare:Ptime.compare )
    with
    | None, _ -> ""
    | Some first, Some last when Ptime.compare first last = 0 ->
        Stdlib.Printf.sprintf ", date %s" (format_date_opt (Some first))
    | Some first, Some last ->
        Stdlib.Printf.sprintf ", dates %s→%s"
          (format_date_opt (Some first)) (format_date_opt (Some last))
    | _ -> ""
  in
  Stdlib.Printf.sprintf
    "Matched %d game(s). Avg confidence %.2f. Detected by %s%s."
    count avg_confidence color_summary date_summary

let pattern_action uri pattern_ids detected_by success min_confidence
    max_confidence eco_prefix opening_substring min_white_elo max_white_elo
    min_black_elo max_black_elo min_rating_diff min_move_count max_move_count
    start_date end_date white_name_substring black_name_substring result_filter
    output_format output_file include_metadata count_only suppress_summary limit
    offset =
  let action () =
    if List.is_empty pattern_ids then (
      Fmt.printf "Provide at least one --pattern identifier.@.";
      Lwt.return_unit)
    else
      Ingestion_pipeline.with_pool uri (fun pool ->
          let* games_res =
            Database.query_games_with_pattern pool ~pattern_ids ~detected_by
              ~success ~min_confidence ~max_confidence ~eco_prefix
              ~opening_substring ~min_white_elo ~max_white_elo ~min_black_elo
              ~max_black_elo ~min_rating_difference:min_rating_diff
              ~min_move_count ~max_move_count ~start_date ~end_date
              ~white_name_substring ~black_name_substring ~result_filter ~limit
              ~offset
          in
          let* games = fail_on_error games_res in
          let summary_text = summarize games in
          if List.is_empty games then (
            if not suppress_summary then Fmt.printf "%s@." summary_text;
            Lwt.return_unit)
          else if count_only then (
            (match output_file with
            | Some path ->
                Fmt.eprintf
                  "Ignoring --output-file=%s in count-only mode.@." path
            | None -> ());
            if not suppress_summary then Fmt.printf "%s@." summary_text;
            Lwt.return_unit)
          else
            let count = List.length games in
            let* () =
              match output_format with
              | Table ->
                  (match output_file with
                  | Some path ->
                      Fmt.eprintf
                        "Ignoring --output-file=%s for table output; use --output json or --output csv.@."
                        path
                  | None -> ());
                  Fmt.printf
                    "%-10s  %-20s  %-5s  %-18s  %-18s  %-5s  %-5s  %-6s  %-8s  %-36s@."
                    "Date" "Event" "ECO" "White" "Black" "Res" "Moves"
                    "Color" "Conf" "Game ID";
                  List.iter games ~f:(fun game ->
                      let date_str = format_date_opt game.game_date in
                      let event =
                        match game.event with
                        | None -> "-"
                        | Some e -> truncate 20 e
                      in
                      let eco = Option.value ~default:"-" game.eco in
                      let white = truncate 18 game.white_player in
                      let black = truncate 18 game.black_player in
                      let conf = Stdlib.Printf.sprintf "%.2f" game.confidence in
                      let outcome = Option.value ~default:"-" game.outcome in
                      Fmt.printf
                        "%-10s  %-20s  %-5s  %-18s  %-18s  %-5s  %-5d  %-6s  %-8s  %-36s@."
                        date_str event eco white black game.result
                        game.move_count
                        (color_to_string game.detected_by)
                        (Stdlib.Printf.sprintf "%s/%s" conf outcome)
                        (Uuidm.to_string game.game_id);
                      Option.iter game.opening ~f:(fun opening ->
                          Fmt.printf "            Opening: %s@."
                            (truncate 80 opening));
                      Option.iter game.start_ply ~f:(fun sp ->
                          Fmt.printf "            Start ply: %d@." sp);
                      Option.iter game.end_ply ~f:(fun ep ->
                          Fmt.printf "            End ply: %d@." ep);
                      if include_metadata then
                        Fmt.printf "            Metadata: %s@."
                          (Yojson.to_string game.metadata);
                      Fmt.printf "@.")
                  |> Lwt.return
              | Json ->
                  let json =
                    `List
                      (List.map games ~f:(fun game ->
                           `Assoc
                             [
                               ( "game_id",
                                 `String (Uuidm.to_string game.game_id) );
                               ( "game_date",
                                 option_to_yojson
                                   (fun t ->
                                     let year, month, day = Ptime.to_date t in
                                     `String
                                       (Stdlib.Printf.sprintf "%04d-%02d-%02d" year month
                                          day))
                                   game.game_date );
                               ( "event",
                                 option_to_yojson (fun s -> `String s) game.event
                               );
                               ( "eco",
                                 option_to_yojson (fun s -> `String s) game.eco );
                               ( "opening",
                                 option_to_yojson (fun s -> `String s) game.opening
                               );
                               ("white_player", `String game.white_player);
                               ("black_player", `String game.black_player);
                               ("result", `String game.result);
                               ("move_count", `Int game.move_count);
                               ( "detected_by",
                                 `String (color_to_string game.detected_by) );
                               ("confidence", `Float game.confidence);
                               ( "outcome",
                                 option_to_yojson (fun s -> `String s) game.outcome
                               );
                               ( "start_ply",
                                 option_to_yojson (fun i -> `Int i) game.start_ply
                               );
                               ( "end_ply",
                                 option_to_yojson (fun i -> `Int i) game.end_ply );
                               ("metadata", game.metadata);
                             ]))
                  in
                  with_output_channel output_file ~binary:true (fun oc ->
                      Yojson.pretty_to_channel oc json;
                      Stdlib.output_char oc '\n';
                      Lwt.return_unit)
                  >>= fun () ->
                  (match output_file with
                  | Some path ->
                      Fmt.printf "Wrote %d game(s) to %s@." count path
                  | None -> ());
                  Lwt.return_unit
              | Csv ->
                  let escape_csv s =
                    String.substr_replace_all s ~pattern:"\"" ~with_:"\"\""
                  in
                  let header =
                    "date,event,eco,opening,white,black,result,moves,detected_by,confidence,outcome,start_ply,end_ply"
                    ^
                    (if include_metadata then ",metadata" else "")
                    ^ ",game_id"
                  in
                  with_output_channel output_file ~binary:false (fun oc ->
                      Stdlib.output_string oc header;
                      Stdlib.output_char oc '\n';
                      List.iter games ~f:(fun game ->
                          let date_str = format_date_opt game.game_date in
                          let event = Option.value ~default:"" game.event in
                          let opening = Option.value ~default:"" game.opening in
                          let eco = Option.value ~default:"" game.eco in
                          let outcome = Option.value ~default:"" game.outcome in
                          let start_ply_str =
                            Option.value_map game.start_ply ~default:""
                              ~f:Int.to_string
                          in
                          let end_ply_str =
                            Option.value_map game.end_ply ~default:""
                              ~f:Int.to_string
                          in
                          let metadata_str =
                            if include_metadata then
                              Yojson.to_string game.metadata
                            else ""
                          in
                          Stdlib.Printf.fprintf oc
                            "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",%d,\"%s\",%.4f,\"%s\",%s,%s%s\"%s\"@."
                            (escape_csv date_str) (escape_csv event)
                            (escape_csv eco) (escape_csv opening)
                            (escape_csv game.white_player)
                            (escape_csv game.black_player)
                            (escape_csv game.result) game.move_count
                            (escape_csv (color_to_string game.detected_by))
                            game.confidence (escape_csv outcome)
                            start_ply_str end_ply_str
                            (if include_metadata then
                               "," ^ escape_csv metadata_str
                             else ",")
                            (escape_csv (Uuidm.to_string game.game_id)));
                      Lwt.return_unit)
                  >>= fun () ->
                  (match output_file with
                  | Some path ->
                      Fmt.printf "Wrote %d game(s) to %s@." count path
                  | None -> ());
                  Lwt.return_unit
            in
            if not suppress_summary then Fmt.printf "%s@." summary_text;
            Lwt.return_unit)
  in
  run_lwt action

let batch_action uri batch_id label limit =
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool ->
        let print_summary summary =
          Fmt.printf "Batch %s@."
            (Uuidm.to_string summary.Database.overview.batch_id);
          Fmt.printf "  Label: %s@." summary.Database.overview.label;
          Fmt.printf "  Source: %s@." summary.Database.overview.source_path;
          Fmt.printf "  Checksum: %s@." summary.Database.overview.checksum;
          Fmt.printf "  Ingested at: %s@."
            (pp_timestamp summary.Database.overview.ingested_at);
          Fmt.printf "  Games: %d@." summary.Database.games_count;
          Fmt.printf "  Positions: %d@." summary.Database.position_count;
          Fmt.printf "  Unique FENs: %d@." summary.Database.unique_fens;
          Fmt.printf "  Embeddings: %d@." summary.Database.embedding_count
        in
        match (batch_id, label) with
        | Some id, _ ->
            let* summary_res = Database.get_batch_summary pool ~batch_id:id in
            let* summary_opt = fail_on_error summary_res in
            (match summary_opt with
            | None -> Fmt.printf "No batch found for %s@." (Uuidm.to_string id)
            | Some summary -> print_summary summary);
            Lwt.return_unit
        | None, Some label_text ->
            let* batches_res =
              Database.find_batches_by_label pool ~label:label_text ~limit
            in
            let* batches = fail_on_error batches_res in
            if List.is_empty batches then
              Fmt.printf "No batches match %S@." label_text
            else ();
            let rec iterate = function
              | [] -> Lwt.return_unit
              | overview :: rest ->
                  let* summary_res =
                    Database.get_batch_summary pool
                      ~batch_id:overview.Database.batch_id
                  in
                  let* summary_opt = fail_on_error summary_res in
                  let* () =
                    match summary_opt with
                    | None -> Lwt.return_unit
                    | Some summary ->
                        print_summary summary;
                        Lwt.return_unit
                  in
                  iterate rest
            in
            let* () = iterate batches in
            Lwt.return_unit
        | None, None ->
            Fmt.printf "Provide either --id or --label to select a batch.@.";
            Lwt.return_unit)
  in
  run_lwt action

let export_fen_action uri fen_id output_path limit =
  let action () =
    Ingestion_pipeline.with_pool uri (fun pool ->
        let* fen_res = Database.get_fen_details pool ~fen_id in
        let* fen_opt = fail_on_error fen_res in
        match fen_opt with
        | None ->
            Fmt.printf "No FEN found for %s@." (Uuidm.to_string fen_id);
            Lwt.return_unit
        | Some info ->
            let* sims_res = Database.find_similar_fens pool ~fen_id ~limit in
            let* sims = fail_on_error sims_res in
            let json =
              `Assoc
                [
                  ("fen_id", `String (Uuidm.to_string info.Database.fen_id));
                  ("fen_text", `String info.fen_text);
                  ("side_to_move", `String (String.of_char info.side_to_move));
                  ("castling", `String info.castling);
                  ( "en_passant",
                    match info.en_passant with
                    | None -> `Null
                    | Some ep -> `String ep );
                  ("material_signature", `String info.material_signature);
                  ( "embedding_version",
                    match info.embedding_version with
                    | None -> `Null
                    | Some v -> `String v );
                  ( "embedding",
                    match info.embedding with
                    | None -> `Null
                    | Some e -> `String e );
                  ("usage_count", `Int info.usage_count);
                  ( "similar",
                    `List
                      (List.map sims ~f:(fun sim ->
                           `Assoc
                             [
                               ( "fen_id",
                                 `String (Uuidm.to_string sim.Database.fen_id)
                               );
                               ("fen_text", `String sim.fen_text);
                               ("distance", `Float sim.distance);
                               ("usage_count", `Int sim.usage_count);
                               ( "embedding_version",
                                 `String sim.embedding_version );
                             ])) );
                ]
            in
            let oc = Stdlib.open_out_bin output_path in
            let finally () = Stdlib.close_out_noerr oc in
            Lwt.finalize
              (fun () ->
                Yojson.pretty_to_channel oc json;
                Stdlib.output_char oc '\n';
                Fmt.printf "Written FEN export to %s@." output_path;
                Lwt.return_unit)
              (fun () ->
                finally ();
                Lwt.return_unit))
  in
  run_lwt action

let similar_cmd =
  let doc = "Find FENs similar to an existing embedding" in
  let info = Cmd.info "similar" ~doc in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:"PostgreSQL connection URI")
  in
  let fen =
    Arg.(
      required
      & opt (some string) None
      & info [ "fen" ] ~doc:"FEN text to search for")
  in
  let limit =
    Arg.(
      value & opt int 5
      & info [ "k" ] ~doc:"Number of neighbours to display" ~docv:"K")
  in
  let term = Term.(ret (const similar_action $ db_uri $ fen $ limit)) in
  Cmd.v info term

let search_cmd =
  let doc = "Search indexed entities with natural language" in
  let info = Cmd.info "search" ~doc in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:"PostgreSQL connection URI")
  in
  let query =
    Arg.(
      required
      & opt (some string) None
      & info [ "query" ] ~doc:"Free-text query" ~docv:"TEXT")
  in
  let limit =
    Arg.(value & opt int 20 & info [ "limit" ] ~doc:"Maximum results" ~docv:"N")
  in
  let entity_doc =
    let options =
      String.concat ~sep:", " (Search_service.available_entity_names ())
    in
    Printf.sprintf "Restrict to an entity type (%s); repeat to combine filters"
      options
  in
  let entities =
    Arg.(
      value & opt_all string [] & info [ "entity" ] ~doc:entity_doc ~docv:"TYPE")
  in
  let model_doc = "OpenAI embedding model identifier" in
  let model =
    Arg.(
      value & opt string "gpt-5" & info [ "model" ] ~doc:model_doc ~docv:"MODEL")
  in
  let term =
    Term.(ret (const search_action $ db_uri $ query $ entities $ limit $ model))
  in
  Cmd.v info term

let game_cmd =
  let doc = "Show metadata and PGN for a stored game" in
  let info = Cmd.info "game" ~doc in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:"PostgreSQL connection URI")
  in
  let game_id =
    Arg.(required & opt (some uuid_conv) None & info [ "id" ] ~doc:"Game UUID")
  in
  let show_pgn =
    Arg.(value & flag & info [ "pgn" ] ~doc:"Print full PGN source")
  in
  let term = Term.(ret (const game_action $ db_uri $ game_id $ show_pgn)) in
  Cmd.v info term

let games_cmd =
  let doc = "List stored games with pagination" in
  let info = Cmd.info "games" ~doc in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:"PostgreSQL connection URI")
  in
  let page =
    Arg.(
      value & opt int 1
      & info [ "page" ] ~doc:"Page number (1-based)" ~docv:"PAGE")
  in
  let page_size =
    Arg.(
      value & opt int 10
      & info [ "page-size" ] ~doc:"Games per page (max 200)" ~docv:"N")
  in
  let interactive =
    Arg.(
      value & flag
      & info [ "interactive"; "i" ]
          ~doc:"Interactive paging with next/previous prompts")
  in
  let term =
    Term.(ret (const games_action $ db_uri $ page $ page_size $ interactive))
  in
  Cmd.v info term

let fen_cmd =
  let doc = "Inspect a stored FEN" in
  let info = Cmd.info "fen" ~doc in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:"PostgreSQL connection URI")
  in
  let fen_id =
    Arg.(required & opt (some uuid_conv) None & info [ "id" ] ~doc:"FEN UUID")
  in
  let term = Term.(ret (const fen_action $ db_uri $ fen_id)) in
  Cmd.v info term

let player_cmd =
  let doc = "Search players by name" in
  let info = Cmd.info "player" ~doc in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:"PostgreSQL connection URI")
  in
  let player_name =
    Arg.(
      required
      & opt (some string) None
      & info [ "name" ] ~doc:"Player name substring")
  in
  let limit =
    Arg.(value & opt int 5 & info [ "limit" ] ~doc:"Maximum results to display")
  in
  let term = Term.(ret (const player_action $ db_uri $ player_name $ limit)) in
  Cmd.v info term

let pattern_cmd =
  let doc = "Filter games by detected strategic or tactical patterns" in
  let info = Cmd.info "pattern" ~doc in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:"PostgreSQL connection URI")
  in
  let patterns =
    Arg.(
      value & opt_all string []
      & info [ "pattern" ]
          ~doc:"Pattern identifier (repeat to match multiple patterns)"
          ~docv:"ID")
  in
  let detected_by =
    Arg.(
      value
      & opt (some color_conv) None
      & info [ "detected-by" ]
          ~doc:"Restrict to detections initiated by a color (white|black)"
          ~docv:"COLOR")
  in
  let success_flag =
    Arg.(
      value & opt bool true
      & info [ "success" ]
          ~doc:"Require successful execution of the pattern (default: true)")
  in
  let min_confidence =
    Arg.(
      value
      & opt (some float) None
      & info [ "min-confidence" ] ~doc:"Minimum detector confidence threshold"
          ~docv:"FLOAT")
  in
  let max_confidence =
    Arg.(
      value
      & opt (some float) None
      & info [ "max-confidence" ] ~doc:"Maximum detector confidence threshold"
          ~docv:"FLOAT")
  in
  let eco_prefix =
    Arg.(
      value
      & opt (some string) None
      & info [ "eco-prefix" ] ~doc:"ECO prefix to filter openings (e.g. E6, D4)"
          ~docv:"ECO")
  in
  let opening_contains =
    Arg.(
      value
      & opt (some string) None
      & info [ "opening-contains" ]
          ~doc:"Substring to match against opening names" ~docv:"TEXT")
  in
  let min_white_elo =
    Arg.(
      value
      & opt (some int) None
      & info [ "min-white-elo" ] ~doc:"Minimum white Elo rating required"
          ~docv:"ELO")
  in
  let max_white_elo =
    Arg.(
      value
      & opt (some int) None
      & info [ "max-white-elo" ] ~doc:"Maximum white Elo rating allowed"
          ~docv:"ELO")
  in
  let min_black_elo =
    Arg.(
      value
      & opt (some int) None
      & info [ "min-black-elo" ] ~doc:"Minimum black Elo rating required"
          ~docv:"ELO")
  in
  let max_black_elo =
    Arg.(
      value
      & opt (some int) None
      & info [ "max-black-elo" ] ~doc:"Maximum black Elo rating allowed"
          ~docv:"ELO")
  in
  let min_rating_diff =
    Arg.(
      value
      & opt (some int) None
      & info [ "min-elo-diff" ] ~doc:"Minimum rating advantage (white - black)"
          ~docv:"POINTS")
  in
  let min_move_count =
    Arg.(
      value
      & opt (some int) None
      & info [ "min-move-count" ]
          ~doc:"Minimum number of recorded moves (plies)" ~docv:"N")
  in
  let max_move_count =
    Arg.(
      value
      & opt (some int) None
      & info [ "max-move-count" ]
          ~doc:"Maximum number of recorded moves (plies)" ~docv:"N")
  in
  let start_date =
    Arg.(
      value
      & opt (some date_conv) None
      & info [ "start-date" ] ~doc:"Earliest game date (YYYY-MM-DD)"
          ~docv:"DATE")
  in
  let end_date =
    Arg.(
      value
      & opt (some date_conv) None
      & info [ "end-date" ] ~doc:"Latest game date (YYYY-MM-DD)" ~docv:"DATE")
  in
  let white_name_contains =
    Arg.(
      value
      & opt (some string) None
      & info [ "white-name-contains" ]
          ~doc:"Substring to match against white player name" ~docv:"TEXT")
  in
  let black_name_contains =
    Arg.(
      value
      & opt (some string) None
      & info [ "black-name-contains" ]
          ~doc:"Substring to match against black player name" ~docv:"TEXT")
  in
  let result_filter =
    Arg.(
      value
      & opt (some result_conv) None
      & info [ "result" ] ~doc:"Match exact PGN result (1-0, 0-1, 1/2-1/2, *)"
          ~docv:"RESULT")
  in
  let output_format =
    Arg.(
      value
      & opt output_format_conv Table
      & info [ "output" ] ~doc:"Output format: table (default), json, or csv"
          ~docv:"FORMAT")
  in
  let output_file =
    Arg.(
      value
      & opt (some file) None
      & info [ "output-file" ]
          ~doc:
            "Write results to file (supported for json or csv output formats)"
          ~docv:"PATH")
  in
  let include_metadata =
    Arg.(
      value
      & flag
      & info [ "include-metadata" ]
          ~doc:"Include detector metadata column/details in outputs")
  in
  let count_only =
    Arg.(
      value
      & flag
      & info [ "count-only" ]
          ~doc:"Only report summary statistics (skip individual game rows)")
  in
  let suppress_summary =
    Arg.(
      value
      & flag
      & info [ "no-summary" ]
          ~doc:"Suppress summary footer (useful for scripting)")
  in
  let limit =
    Arg.(value & opt int 10 & info [ "limit" ] ~doc:"Maximum games to return")
  in
  let offset =
    Arg.(value & opt int 0 & info [ "offset" ] ~doc:"Result offset" ~docv:"N")
  in
  let term =
    Term.(
      ret
        (const pattern_action $ db_uri $ patterns $ detected_by $ success_flag
       $ min_confidence $ max_confidence $ eco_prefix $ opening_contains
       $ min_white_elo $ max_white_elo $ min_black_elo $ max_black_elo
       $ min_rating_diff $ min_move_count $ max_move_count $ start_date
       $ end_date $ white_name_contains $ black_name_contains $ result_filter
       $ output_format $ output_file $ include_metadata $ count_only
       $ suppress_summary $ limit $ offset))
  in
  Cmd.v info term

let batch_cmd =
  let doc = "Summarize ingestion batches" in
  let info = Cmd.info "batch" ~doc in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:"PostgreSQL connection URI")
  in
  let id =
    Arg.(value & opt (some uuid_conv) None & info [ "id" ] ~doc:"Batch UUID")
  in
  let label =
    Arg.(
      value
      & opt (some string) None
      & info [ "label" ] ~doc:"Batch label filter")
  in
  let limit =
    Arg.(
      value & opt int 5
      & info [ "limit" ] ~doc:"Maximum label matches to summarize")
  in
  let term = Term.(ret (const batch_action $ db_uri $ id $ label $ limit)) in
  Cmd.v info term

let export_cmd =
  let doc = "Export a FEN and optional neighbours to JSON" in
  let info = Cmd.info "export" ~doc in
  let db_uri =
    Arg.(
      required
      & opt (some uri_conv) None
      & info [ "db-uri" ] ~doc:"PostgreSQL connection URI")
  in
  let fen_id =
    Arg.(
      required
      & opt (some uuid_conv) None
      & info [ "id" ] ~doc:"FEN UUID to export")
  in
  let output =
    Arg.(
      required
      & opt (some file) None
      & info [ "out" ] ~doc:"Destination JSON file")
  in
  let limit =
    Arg.(
      value & opt int 5 & info [ "k" ] ~doc:"Similar FENs to include" ~docv:"K")
  in
  let term =
    Term.(ret (const export_fen_action $ db_uri $ fen_id $ output $ limit))
  in
  Cmd.v info term

let commands =
  [
    search_cmd;
    similar_cmd;
    game_cmd;
    games_cmd;
    pattern_cmd;
    fen_cmd;
    player_cmd;
    batch_cmd;
    export_cmd;
  ]

let root_command =
  Cmd.group (Cmd.info "retrieve" ~doc:"Chess retrieval CLI") commands

let command_names () = List.map commands ~f:Cmd.name

let eval_value ?help ?err ?catch ?env ?argv () =
  Cmd.eval_value ?help ?err ?catch ?env ?argv root_command

let run ?help ?err ?catch ?env ?argv () =
  Cmd.eval ?help ?err ?catch ?env ?argv root_command
