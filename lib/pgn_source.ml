(** PGN parser implementation.

    See {!module:Pgn_source} for public API documentation. This parser handles
    multi-game PGN files, preserves all move annotations, and generates placeholder
    FENs with accurate metadata. It uses a stateful scanner to detect game boundaries
    and build structured game records. *)

open! Base

module String_key = struct
  type t = string

  let compare = String.compare
end

module String_map = Stdlib.Map.Make (String_key)

type header_map = string String_map.t

let sanitize value = value |> String.strip |> String.lowercase

let string_has predicate s =
  let rec loop i =
    if i >= String.length s then false
    else if predicate s.[i] then true
    else loop (i + 1)
  in
  loop 0

let starts_with str idx prefix =
  let len = String.length prefix in
  idx + len <= String.length str
  && String.equal (String.sub str ~pos:idx ~len) prefix

let parse_header_line map line =
  let line = String.strip line in
  if String.is_empty line || not (Char.equal (String.get line 0) '[') then map
  else
    let inside =
      let len = String.length line in
      if len < 2 then "" else String.sub line ~pos:1 ~len:(len - 2)
    in
    match String.split inside ~on:'"' with
    | before :: value :: _ ->
        let key = before |> String.strip |> sanitize in
        String_map.add key value map
    | _ -> map

let parse_headers lines =
  List.fold lines ~init:String_map.empty ~f:parse_header_line

let parse_date value =
  match String.split value ~on:'.' with
  | [ yyyy; mm; dd ] -> (
      try
        let year = Int.of_string yyyy in
        let month = Int.of_string mm in
        let day = Int.of_string dd in
        Ptime.of_date (year, month, day)
      with _ -> None)
  | _ -> None

let header_value headers key =
  match String_map.find_opt (sanitize key) headers with
  | None -> None
  | Some v -> if String.equal v "?" then None else Some v

let required headers key =
  match header_value headers key with
  | Some v -> v
  | None -> failwith (Stdlib.Printf.sprintf "Missing PGN header %s" key)

let build_header headers =
  let open Types.Game_header in
  {
    event = header_value headers "Event";
    site = header_value headers "Site";
    game_date = Option.bind (header_value headers "Date") ~f:parse_date;
    round = header_value headers "Round";
    eco = header_value headers "ECO";
    opening = header_value headers "Opening";
    white_player = required headers "White";
    black_player = required headers "Black";
    white_elo =
      Option.bind (header_value headers "WhiteElo") ~f:Stdlib.int_of_string_opt;
    black_elo =
      Option.bind (header_value headers "BlackElo") ~f:Stdlib.int_of_string_opt;
    white_fide_id = header_value headers "WhiteFideId";
    black_fide_id = header_value headers "BlackFideId";
    result = Option.value (header_value headers "Result") ~default:"*";
    termination = header_value headers "Termination";
  }

let sanitize_utf8 str =
  let decoder = Uutf.decoder ~encoding:`UTF_8 (`String str) in
  let rec has_malformed () =
    match Uutf.decode decoder with
    | `Uchar _ -> has_malformed ()
    | `End -> false
    | `Await -> has_malformed ()
    | `Malformed _ -> true
  in
  if not (has_malformed ()) then str
  else
    let buf = Stdlib.Buffer.create (String.length str) in
    String.iter str ~f:(fun c ->
        let code = Char.to_int c in
        if (code >= 32 && code < 127) || code = 9 || code = 10 || code = 13 then
          Stdlib.Buffer.add_char buf c);
    Stdlib.Buffer.contents buf

let parse_moves lines =
  let text = String.concat ~sep:"\n" lines in
  let len = String.length text in
  let moves = ref [] in
  let pending_comments = ref [] in
  let pending_variations = ref [] in
  let pending_nags = ref [] in
  let ply = ref 1 in
  let side = ref 'w' in
  let last_token_was_move = ref false in

  let update_last f =
    match !moves with [] -> () | m :: rest -> moves := f m :: rest
  in

  let add_comment comment =
    let comment = String.strip comment in
    if String.is_empty comment then ()
    else if !last_token_was_move && not (List.is_empty !moves) then
      update_last (fun m ->
          {
            m with
            Types.Move_feature.comments_after =
              m.Types.Move_feature.comments_after @ [ comment ];
          })
    else pending_comments := comment :: !pending_comments
  in

  let add_variation variation =
    let variation = String.strip variation in
    if String.is_empty variation then ()
    else if !last_token_was_move && not (List.is_empty !moves) then
      update_last (fun m ->
          {
            m with
            Types.Move_feature.variations =
              m.Types.Move_feature.variations @ [ variation ];
          })
    else pending_variations := variation :: !pending_variations
  in

  let add_nag nag =
    if !last_token_was_move && not (List.is_empty !moves) then
      update_last (fun m ->
          {
            m with
            Types.Move_feature.nags = m.Types.Move_feature.nags @ [ nag ];
          })
    else pending_nags := nag :: !pending_nags
  in

  let rec skip_whitespace i =
    if i < len then
      match String.get text i with
      | ' ' | '\t' | '\n' | '\r' -> skip_whitespace (i + 1)
      | _ -> i
    else i
  in

  let skip_move_number i =
    if i >= len then i
    else
      let j = ref i in
      while !j < len && Char.is_digit (String.get text !j) do
        Int.incr j
      done;
      if !j < len && Char.equal (String.get text !j) '.' then (
        while !j < len && Char.equal (String.get text !j) '.' do
          Int.incr j
        done;
        skip_whitespace !j)
      else i
  in

  let parse_comment i =
    let buf = Stdlib.Buffer.create 64 in
    let rec loop idx =
      if idx >= len then (Stdlib.Buffer.contents buf, idx)
      else
        let c = String.get text idx in
        if Char.equal c '}' then (Stdlib.Buffer.contents buf, idx + 1)
        else (
          Stdlib.Buffer.add_char buf c;
          loop (idx + 1))
    in
    loop i
  in

  let parse_variation i =
    let buf = Stdlib.Buffer.create 128 in
    let rec loop depth idx =
      if idx >= len then (Stdlib.Buffer.contents buf, idx)
      else
        let c = String.get text idx in
        match c with
        | '(' ->
            Stdlib.Buffer.add_char buf c;
            loop (depth + 1) (idx + 1)
        | ')' ->
            if depth = 1 then (Stdlib.Buffer.contents buf, idx + 1)
            else (
              Stdlib.Buffer.add_char buf c;
              loop (depth - 1) (idx + 1))
        | _ ->
            Stdlib.Buffer.add_char buf c;
            loop depth (idx + 1)
    in
    loop 1 i
  in

  let parse_token i =
    let buf = Stdlib.Buffer.create 32 in
    let rec loop idx =
      if idx >= len then (Stdlib.Buffer.contents buf, idx)
      else
        match String.get text idx with
        | ' ' | '\t' | '\n' | '\r' -> (Stdlib.Buffer.contents buf, idx)
        | '{' | '}' | '(' | ')' -> (Stdlib.Buffer.contents buf, idx)
        | _ ->
            Stdlib.Buffer.add_char buf (String.get text idx);
            loop (idx + 1)
    in
    loop i
  in

  let parse_nag i =
    let j = ref (i + 1) in
    while !j < len && Char.is_digit (String.get text !j) do
      Int.incr j
    done;
    if !j = i + 1 then (None, i + 1)
    else
      let value = String.sub text ~pos:(i + 1) ~len:(!j - (i + 1)) in
      (Stdlib.int_of_string_opt value, !j)
  in

  let add_move san =
    let san = String.strip san in
    if String.is_empty san then ()
    else
      let fen_before =
        if Int.equal !ply 1 then Fen_generator.starting_position_fen
        else
          Fen_generator.placeholder_fen ~ply_number:(!ply - 1)
            ~side_to_move:!side
      in
      let next_side = if Char.equal !side 'w' then 'b' else 'w' in
      let fen_after =
        Fen_generator.placeholder_fen ~ply_number:!ply ~side_to_move:next_side
      in
      let move =
        {
          Types.Move_feature.ply_number = !ply;
          san;
          uci = None;
          fen_before;
          fen_after;
          side_to_move = !side;
          eval_cp = None;
          is_capture = Stdlib.String.contains san 'x';
          is_check =
            string_has (fun c -> Char.equal c '+' || Char.equal c '#') san;
          is_mate = Stdlib.String.contains san '#';
          motifs = [];
          comments_before = List.rev !pending_comments;
          comments_after = [];
          variations = List.rev !pending_variations;
          nags = List.rev !pending_nags;
        }
      in
      moves := move :: !moves;
      pending_comments := [];
      pending_variations := [];
      pending_nags := [];
      side := next_side;
      Int.incr ply;
      last_token_was_move := true
  in

  let rec loop i =
    let i = skip_whitespace i in
    if i >= len then ()
    else if starts_with text i "1-0" then ()
    else if starts_with text i "0-1" then ()
    else if starts_with text i "1/2-1/2" then ()
    else if Char.equal (String.get text i) '*' then ()
    else
      match String.get text i with
      | '{' ->
          let comment, next_i = parse_comment (i + 1) in
          add_comment comment;
          loop next_i
      | '(' ->
          let variation, next_i = parse_variation (i + 1) in
          add_variation variation;
          loop next_i
      | '$' ->
          let nag_opt, next_i = parse_nag i in
          (match nag_opt with Some nag -> add_nag nag | None -> ());
          loop next_i
      | '0' .. '9' ->
          let next_i = skip_move_number i in
          if next_i = i then
            let token, next_i = parse_token i in
            if String.is_empty token then loop (i + 1)
            else if String.equal token "..." then (
              last_token_was_move := false;
              loop next_i)
            else (
              add_move token;
              loop next_i)
          else (
            last_token_was_move := false;
            loop next_i)
      | _ ->
          let token, next_i = parse_token i in
          let token = String.strip token in
          if String.is_empty token then loop next_i
          else if String.equal token "..." then (
            last_token_was_move := false;
            loop next_i)
          else (
            add_move token;
            loop next_i)
  in

  loop 0;

  if (not (List.is_empty !pending_comments)) && not (List.is_empty !moves) then (
    let trailing = List.rev !pending_comments in
    pending_comments := [];
    update_last (fun m ->
        {
          m with
          Types.Move_feature.comments_after =
            m.Types.Move_feature.comments_after @ trailing;
        }));
  if (not (List.is_empty !pending_variations)) && not (List.is_empty !moves)
  then (
    let trailing = List.rev !pending_variations in
    pending_variations := [];
    update_last (fun m ->
        {
          m with
          Types.Move_feature.variations =
            m.Types.Move_feature.variations @ trailing;
        }));
  if (not (List.is_empty !pending_nags)) && not (List.is_empty !moves) then (
    let trailing = List.rev !pending_nags in
    pending_nags := [];
    update_last (fun m ->
        {
          m with
          Types.Move_feature.nags = m.Types.Move_feature.nags @ trailing;
        }));

  List.rev !moves

let game_from_block block =
  let lines =
    block |> String.split ~on:'\n'
    |> List.filter ~f:(fun l -> not (String.is_empty (String.strip l)))
  in
  let header_lines, move_lines =
    List.partition_tf lines ~f:(fun line ->
        (not (String.is_empty line)) && Char.equal (String.get line 0) '[')
  in
  let headers = parse_headers header_lines in
  let header = build_header headers in
  let source_pgn = sanitize_utf8 (String.concat ~sep:"\n" lines) in
  let moves = parse_moves move_lines in
  { Types.Game.header; moves; source_pgn }

let fold_games path ~init ~f =
  let%lwt contents = Lwt_io.(with_file ~mode:Input path read) in
  let lines = String.split contents ~on:'\n' in
  let rec accumulate acc current in_moves = function
    | [] ->
        let acc = if String.is_empty current then acc else current :: acc in
        List.rev acc
    | line :: rest ->
        let trimmed = String.strip line in
        if String.is_empty trimmed then accumulate acc current in_moves rest
        else if
          (not (String.is_empty trimmed))
          && Char.equal (String.get trimmed 0) '['
        then
          if
            (* Header line *)
            (not (String.is_empty current)) && in_moves
          then
            (* New game starting - save current and start new *)
            accumulate (current :: acc) line false rest
          else
            (* Continue current game headers *)
            let current =
              if String.is_empty current then line else current ^ "\n" ^ line
            in
            accumulate acc current false rest
        else
          (* Move line *)
          let current =
            if String.is_empty current then line else current ^ "\n" ^ line
          in
          accumulate acc current true rest
  in
  let has_required_headers block =
    (* Check if block has at least White and Black headers *)
    let has_substring str sub =
      let rec search pos =
        if pos > String.length str - String.length sub then false
        else if String.equal (String.sub str ~pos ~len:(String.length sub)) sub
        then true
        else
          let slice = String.sub str ~pos ~len:(String.length sub) in
          if String.equal slice sub then true else search (pos + 1)
      in
      try search 0 with Invalid_argument _ -> false
    in
    has_substring block "[White " && has_substring block "[Black "
  in
  let blocks =
    lines |> accumulate [] "" false
    |> List.filter ~f:(fun block ->
           let trimmed = String.strip block in
           (not (String.is_empty trimmed)) && has_required_headers trimmed)
  in
  Lwt_list.fold_left_s
    (fun acc block ->
      let game = game_from_block block in
      f acc game)
    init blocks

module Default : Ingestion_pipeline.PGN_SOURCE = struct
  let fold_games = fold_games
end
