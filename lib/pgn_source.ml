open Lwt.Infix
open Ingestion_pipeline

module String_map = Map.Make (String)

let sanitize value =
  value |> String.trim |> String.lowercase_ascii

let string_has predicate s =
  let rec loop i =
    if i >= String.length s then false
    else if predicate s.[i] then true
    else loop (i + 1)
  in
  loop 0

let parse_header_line map line =
  let line = String.trim line in
  if line = "" || line.[0] <> '[' then map
  else
    let inside =
      let len = String.length line in
      if len < 2 then "" else String.sub line 1 (len - 2)
    in
    match String.split_on_char '"' inside with
    | before :: value :: _ ->
        let key = before |> String.trim |> sanitize in
        String_map.add key value map
    | _ -> map

let parse_headers lines =
  List.fold_left parse_header_line String_map.empty lines

let parse_date value =
  match String.split_on_char '.' value with
  | [ yyyy; mm; dd ] ->
      (try
         let year = int_of_string yyyy in
         let month = int_of_string mm in
         let day = int_of_string dd in
         Ptime.of_date (year, month, day)
       with _ -> None)
  | _ -> None

let header_value headers key =
  match String_map.find_opt (sanitize key) headers with
  | None -> None
  | Some v -> if v = "?" then None else Some v

let required headers key =
  match header_value headers key with
  | Some v -> v
  | None -> failwith (Printf.sprintf "Missing PGN header %s" key)

let build_header headers =
  let open Types.Game_header in
  {
    event = header_value headers "Event";
    site = header_value headers "Site";
    game_date = Option.bind (header_value headers "Date") parse_date;
    round = header_value headers "Round";
    eco = header_value headers "ECO";
    opening = header_value headers "Opening";
    white_player = required headers "White";
    black_player = required headers "Black";
    white_elo = Option.bind (header_value headers "WhiteElo") int_of_string_opt;
    black_elo = Option.bind (header_value headers "BlackElo") int_of_string_opt;
    result = Option.value (header_value headers "Result") ~default:"*";
    termination = header_value headers "Termination";
  }

let game_from_block block =
  let lines = block |> String.split_on_char '\n' |> List.filter (fun l -> String.trim l <> "") in
  let header_lines, move_lines =
    List.partition (fun line -> String.length line > 0 && line.[0] = '[') lines
  in
  let headers = parse_headers header_lines in
  let header = build_header headers in
  let source_pgn = String.concat "\n" lines in
  let moves =
    let is_result token =
      match token with
      | "1-0" | "0-1" | "1/2-1/2" | "*" -> true
      | _ -> false
    in
    match move_lines with
    | [] -> []
    | xs ->
        let concatenated = String.concat " " xs in
        let tokens = String.split_on_char ' ' concatenated in
        let rec build acc ply side = function
          | [] -> List.rev acc
          | token :: rest ->
              let token = String.trim token in
              if token = "" then build acc ply side rest
              else if String.contains token '.' || is_result token then
                build acc ply side rest
              else
                let move =
                  {
                    Types.Move_feature.ply_number = ply;
                    san = token;
                    uci = None;
                    fen_before = "";
                    fen_after = "";
                    side_to_move = side;
                    eval_cp = None;
                    is_capture = String.contains token 'x';
                    is_check = string_has (fun c -> c = '+' || c = '#') token;
                    is_mate = String.contains token '#';
                    motifs = [];
                  }
                in
                let next_side = if side = 'w' then 'b' else 'w' in
                build (move :: acc) (ply + 1) next_side rest
        in
        build [] 1 'w' tokens
  in
  { Types.Game.header; moves; source_pgn }

let fold_games path ~init ~f =
  let%lwt contents = Lwt_io.(with_file ~mode:Input path read) in
  let blocks = String.split_on_char '\n' contents in
  let rec accumulate acc current = function
    | [] -> List.rev (current :: acc)
    | line :: rest ->
        if String.trim line = "" then accumulate (current :: acc) "" rest
        else
          let current = if current = "" then line else current ^ "\n" ^ line in
          accumulate acc current rest
  in
  let blocks =
    blocks
    |> accumulate [] ""
    |> List.filter (fun block -> String.trim block <> "")
  in
  Lwt_list.fold_left_s
    (fun acc block ->
      let game = game_from_block block in
      f acc game)
    init blocks

module Default : Ingestion_pipeline.PGN_SOURCE = struct
  let fold_games = fold_games
end
