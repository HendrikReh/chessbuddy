(** Chess engine for board state tracking and FEN generation *)

open! Base

type piece = King | Queen | Rook | Bishop | Knight | Pawn
type color = White | Black
type square = Empty | Piece of { piece_type : piece; color : color }

type castling_rights = {
  white_kingside : bool;
  white_queenside : bool;
  black_kingside : bool;
  black_queenside : bool;
}

(* Utility functions *)

let color_to_fen_char = function White -> 'w' | Black -> 'b'

let color_of_fen_char = function
  | 'w' -> Ok White
  | 'b' -> Ok Black
  | c -> Error (Printf.sprintf "Invalid FEN side-to-move: '%c'" c)

let piece_to_fen_char piece color =
  let base_char =
    match piece with
    | King -> 'k'
    | Queen -> 'q'
    | Rook -> 'r'
    | Bishop -> 'b'
    | Knight -> 'n'
    | Pawn -> 'p'
  in
  match color with White -> Char.uppercase base_char | Black -> base_char

let piece_of_fen_char c =
  let piece =
    match Char.lowercase c with
    | 'k' -> Ok King
    | 'q' -> Ok Queen
    | 'r' -> Ok Rook
    | 'b' -> Ok Bishop
    | 'n' -> Ok Knight
    | 'p' -> Ok Pawn
    | _ -> Error (Printf.sprintf "Invalid FEN piece character: '%c'" c)
  in
  Result.bind piece ~f:(fun p ->
      let color = if Char.is_uppercase c then White else Black in
      Ok (p, color))

let square_notation_to_indices notation =
  if String.length notation <> 2 then
    Error (Printf.sprintf "Invalid square notation: '%s'" notation)
  else
    let file_char = String.get notation 0 in
    let rank_char = String.get notation 1 in
    match (file_char, rank_char) with
    | f, r
      when Char.( >= ) f 'a' && Char.( <= ) f 'h' && Char.( >= ) r '1'
           && Char.( <= ) r '8' ->
        let file = Char.to_int f - Char.to_int 'a' in
        let rank = Char.to_int r - Char.to_int '1' in
        Ok (file, rank)
    | _ -> Error (Printf.sprintf "Invalid square notation: '%s'" notation)

let indices_to_square_notation file rank =
  if file < 0 || file > 7 || rank < 0 || rank > 7 then
    Error
      (Printf.sprintf "Square indices out of bounds: file=%d, rank=%d" file rank)
  else
    let file_char = Char.of_int_exn (Char.to_int 'a' + file) in
    let rank_char = Char.of_int_exn (Char.to_int '1' + rank) in
    Ok (String.of_char_list [ file_char; rank_char ])

(* Board module *)

module Board = struct
  type t = square array array

  let empty = Array.init 8 ~f:(fun _ -> Array.init 8 ~f:(fun _ -> Empty))

  let initial =
    let board = Array.init 8 ~f:(fun _ -> Array.init 8 ~f:(fun _ -> Empty)) in
    (* Set up white pieces (rank 0 = rank 1) *)
    board.(0).(0) <- Piece { piece_type = Rook; color = White };
    board.(1).(0) <- Piece { piece_type = Knight; color = White };
    board.(2).(0) <- Piece { piece_type = Bishop; color = White };
    board.(3).(0) <- Piece { piece_type = Queen; color = White };
    board.(4).(0) <- Piece { piece_type = King; color = White };
    board.(5).(0) <- Piece { piece_type = Bishop; color = White };
    board.(6).(0) <- Piece { piece_type = Knight; color = White };
    board.(7).(0) <- Piece { piece_type = Rook; color = White };
    (* White pawns (rank 1 = rank 2) *)
    for file = 0 to 7 do
      board.(file).(1) <- Piece { piece_type = Pawn; color = White }
    done;
    (* Black pawns (rank 6 = rank 7) *)
    for file = 0 to 7 do
      board.(file).(6) <- Piece { piece_type = Pawn; color = Black }
    done;
    (* Set up black pieces (rank 7 = rank 8) *)
    board.(0).(7) <- Piece { piece_type = Rook; color = Black };
    board.(1).(7) <- Piece { piece_type = Knight; color = Black };
    board.(2).(7) <- Piece { piece_type = Bishop; color = Black };
    board.(3).(7) <- Piece { piece_type = Queen; color = Black };
    board.(4).(7) <- Piece { piece_type = King; color = Black };
    board.(5).(7) <- Piece { piece_type = Bishop; color = Black };
    board.(6).(7) <- Piece { piece_type = Knight; color = Black };
    board.(7).(7) <- Piece { piece_type = Rook; color = Black };
    board

  let get board ~file ~rank =
    if file < 0 || file > 7 || rank < 0 || rank > 7 then
      raise
        (Invalid_argument
           (Printf.sprintf "Board indices out of bounds: file=%d, rank=%d" file
              rank));
    board.(file).(rank)

  let set board ~file ~rank square =
    if file < 0 || file > 7 || rank < 0 || rank > 7 then
      raise
        (Invalid_argument
           (Printf.sprintf "Board indices out of bounds: file=%d, rank=%d" file
              rank));
    let new_board = Array.map board ~f:(fun rank_arr -> Array.copy rank_arr) in
    new_board.(file).(rank) <- square;
    new_board

  let to_fen_board board =
    let buf = Buffer.create 64 in
    for rank = 7 downto 0 do
      let empty_count = ref 0 in
      for file = 0 to 7 do
        match board.(file).(rank) with
        | Empty -> empty_count := !empty_count + 1
        | Piece { piece_type; color } ->
            if !empty_count > 0 then (
              Buffer.add_string buf (Int.to_string !empty_count);
              empty_count := 0);
            Buffer.add_char buf (piece_to_fen_char piece_type color)
      done;
      if !empty_count > 0 then
        Buffer.add_string buf (Int.to_string !empty_count);
      if rank > 0 then Buffer.add_char buf '/'
    done;
    Buffer.contents buf

  let of_fen_board fen_board =
    let board = Array.init 8 ~f:(fun _ -> Array.init 8 ~f:(fun _ -> Empty)) in
    let ranks = String.split ~on:'/' fen_board in
    if List.length ranks <> 8 then
      Error
        (Printf.sprintf "Invalid FEN board: expected 8 ranks, got %d"
           (List.length ranks))
    else
      let rec process_ranks ranks_list rank_idx =
        match ranks_list with
        | [] -> Ok board
        | rank_str :: rest -> (
            let file_idx = ref 0 in
            let rank = 7 - rank_idx in
            let rec process_chars chars =
              match chars with
              | [] -> Ok ()
              | c :: chars_rest -> (
                  if Char.is_digit c then (
                    let skip = Char.to_int c - Char.to_int '0' in
                    file_idx := !file_idx + skip;
                    process_chars chars_rest)
                  else
                    match piece_of_fen_char c with
                    | Error msg -> Error msg
                    | Ok (piece_type, color) ->
                        if !file_idx > 7 then
                          Error
                            (Printf.sprintf "FEN board rank too long: %s"
                               rank_str)
                        else (
                          board.(!file_idx).(rank) <-
                            Piece { piece_type; color };
                          file_idx := !file_idx + 1;
                          process_chars chars_rest))
            in
            match process_chars (String.to_list rank_str) with
            | Error msg -> Error msg
            | Ok () ->
                if !file_idx <> 8 then
                  Error
                    (Printf.sprintf "FEN board rank incomplete: %s (file=%d)"
                       rank_str !file_idx)
                else process_ranks rest (rank_idx + 1))
      in
      process_ranks ranks 0

  let to_string board =
    let buf = Buffer.create 256 in
    Buffer.add_string buf "  a b c d e f g h\n";
    for rank = 7 downto 0 do
      Buffer.add_string buf (Printf.sprintf "%d " (rank + 1));
      for file = 0 to 7 do
        let square_repr =
          match board.(file).(rank) with
          | Empty -> "."
          | Piece { piece_type; color } ->
              String.of_char (piece_to_fen_char piece_type color)
        in
        Buffer.add_string buf square_repr;
        Buffer.add_char buf ' '
      done;
      Buffer.add_string buf (Printf.sprintf "%d\n" (rank + 1))
    done;
    Buffer.add_string buf "  a b c d e f g h\n";
    Buffer.contents buf
end

(* Move parser module *)

module Move_parser = struct
  type move_result = {
    board : Board.t;
    captured : piece option;
    castling_rights : castling_rights;
    en_passant_square : string option;
  }

  (* Parse SAN move notation *)
  type parsed_move = {
    piece : piece;
    from_file : int option;
    from_rank : int option;
    to_file : int;
    to_rank : int;
    is_capture : bool;
    promotion : piece option;
  }

  let parse_san san ~side_to_move:_ =
    (* Remove check (+) and checkmate (#) annotations *)
    let san =
      String.filter san ~f:(fun c -> not (Char.equal c '+' || Char.equal c '#'))
    in

    (* Handle castling *)
    if String.equal san "O-O" || String.equal san "0-0" then Ok `Kingside_castle
    else if String.equal san "O-O-O" || String.equal san "0-0-0" then
      Ok `Queenside_castle
    else
      (* Parse regular move *)
      let len = String.length san in
      if len < 2 then Error (Printf.sprintf "Invalid SAN: too short '%s'" san)
      else
        (* Check for promotion (e8=Q) *)
        let san_result, promotion =
          if len >= 4 && Char.equal (String.get san (len - 2)) '=' then
            let promo_char = String.get san (len - 1) in
            match Char.uppercase promo_char with
            | 'Q' -> (Ok (String.sub san ~pos:0 ~len:(len - 2)), Some Queen)
            | 'R' -> (Ok (String.sub san ~pos:0 ~len:(len - 2)), Some Rook)
            | 'B' -> (Ok (String.sub san ~pos:0 ~len:(len - 2)), Some Bishop)
            | 'N' -> (Ok (String.sub san ~pos:0 ~len:(len - 2)), Some Knight)
            | c -> (Error (Printf.sprintf "Invalid promotion piece: %c" c), None)
          else (Ok san, None)
        in
        Result.bind san_result ~f:(fun san ->
            let len = String.length san in
            (* Last 2 chars are destination square *)
            let to_square = String.sub san ~pos:(len - 2) ~len:2 in
            Result.bind (square_notation_to_indices to_square)
              ~f:(fun (to_file, to_rank) ->
                let rest = String.sub san ~pos:0 ~len:(len - 2) in

                (* Check for capture (x) *)
                let is_capture = String.contains rest 'x' in
                let rest =
                  String.filter rest ~f:(fun c -> not (Char.equal c 'x'))
                in

                (* First char might be piece type *)
                if String.is_empty rest then
                  (* Pawn move (e4) *)
                  Ok
                    (`Move
                       {
                         piece = Pawn;
                         from_file = None;
                         from_rank = None;
                         to_file;
                         to_rank;
                         is_capture;
                         promotion;
                       })
                else
                  let first_char = String.get rest 0 in
                  match first_char with
                  | 'K' | 'Q' | 'R' | 'B' | 'N' ->
                      (* Piece move (Nf3, Nbd7, R1e2) *)
                      let piece =
                        match first_char with
                        | 'K' -> King
                        | 'Q' -> Queen
                        | 'R' -> Rook
                        | 'B' -> Bishop
                        | 'N' -> Knight
                        | _ -> failwith "unreachable"
                      in
                      let disambig =
                        String.sub rest ~pos:1 ~len:(String.length rest - 1)
                      in
                      let from_file, from_rank =
                        if String.is_empty disambig then (None, None)
                        else if String.length disambig = 1 then
                          let c = String.get disambig 0 in
                          if Char.is_digit c then
                            (None, Some (Char.to_int c - Char.to_int '1'))
                          else (Some (Char.to_int c - Char.to_int 'a'), None)
                        else
                          (* Full square disambiguation (Qh4e1) *)
                          match square_notation_to_indices disambig with
                          | Ok (f, r) -> (Some f, Some r)
                          | Error _ -> (None, None)
                      in
                      Ok
                        (`Move
                           {
                             piece;
                             from_file;
                             from_rank;
                             to_file;
                             to_rank;
                             is_capture;
                             promotion;
                           })
                  | _ ->
                      (* Pawn move with file disambiguation (exd5) *)
                      let from_file =
                        Some (Char.to_int first_char - Char.to_int 'a')
                      in
                      Ok
                        (`Move
                           {
                             piece = Pawn;
                             from_file;
                             from_rank = None;
                             to_file;
                             to_rank;
                             is_capture;
                             promotion;
                           })))

  let find_piece board ~piece ~color ~to_file ~to_rank ~from_file ~from_rank =
    (* Find the piece that can move to the destination *)
    let candidates = ref [] in
    for file = 0 to 7 do
      for rank = 0 to 7 do
        match Board.get board ~file ~rank with
        | Piece { piece_type; color = piece_color }
          when phys_equal piece_type piece && phys_equal piece_color color ->
            (* Check disambiguation *)
            let file_match =
              match from_file with None -> true | Some f -> f = file
            in
            let rank_match =
              match from_rank with None -> true | Some r -> r = rank
            in
            (* Check if this piece can actually reach the destination *)
            let can_reach =
              match piece with
              | Pawn ->
                  (* Pawn move: must be on same file and move forward *)
                  let direction =
                    match piece_color with White -> 1 | Black -> -1
                  in
                  let is_capture = Option.is_some from_file in
                  if is_capture then
                    (* Capture: file must match from_file, rank must be one forward *)
                    file_match && to_rank = rank + direction
                  else
                    (* Non-capture: must be on destination file, move 1 or 2 forward *)
                    file = to_file
                    && (to_rank = rank + direction
                       || to_rank = rank + (2 * direction)
                          && ((phys_equal piece_color White && rank = 1)
                             || (phys_equal piece_color Black && rank = 6)))
              | Knight ->
                  (* Knight moves: L-shape (2,1) or (1,2) *)
                  let df = Int.abs (to_file - file) in
                  let dr = Int.abs (to_rank - rank) in
                  (df = 2 && dr = 1) || (df = 1 && dr = 2)
              | King ->
                  (* King moves: one square in any direction *)
                  let df = Int.abs (to_file - file) in
                  let dr = Int.abs (to_rank - rank) in
                  df <= 1 && dr <= 1 && (df > 0 || dr > 0)
              | Queen | Rook | Bishop ->
                  (* TODO: Add proper sliding piece logic (check for blockers) *)
                  (* For now, just check if move is along valid line *)
                  true
            in
            if file_match && rank_match && can_reach then
              candidates := (file, rank) :: !candidates
        | _ -> ()
      done
    done;
    match !candidates with
    | [ (f, r) ] -> Ok (f, r)
    | [] ->
        Error
          (Printf.sprintf "No %s found to move to %c%d"
             (match piece with
             | King -> "king"
             | Queen -> "queen"
             | Rook -> "rook"
             | Bishop -> "bishop"
             | Knight -> "knight"
             | Pawn -> "pawn")
             (Char.of_int_exn (Char.to_int 'a' + to_file))
             (to_rank + 1))
    | _ -> Error "Ambiguous move: multiple pieces can move to destination"

  (* Helper: Update castling rights based on move coordinates *)
  let update_castling_rights ~piece_moved ~from_file ~from_rank ~captured
      ~to_file ~to_rank ~side_to_move ~castling_rights ~is_castling =
    let rights = ref castling_rights in

    (* King moves disable both sides for that color *)
    (match (piece_moved, side_to_move) with
    | King, White ->
        rights :=
          { !rights with white_kingside = false; white_queenside = false }
    | King, Black ->
        rights :=
          { !rights with black_kingside = false; black_queenside = false }
    | _ -> ());

    (* Rook moves from initial squares disable corresponding castling *)
    (match (piece_moved, from_file, from_rank, side_to_move) with
    | Rook, 0, 0, White ->
        (* a1 *)
        rights := { !rights with white_queenside = false }
    | Rook, 7, 0, White ->
        (* h1 *)
        rights := { !rights with white_kingside = false }
    | Rook, 0, 7, Black ->
        (* a8 *)
        rights := { !rights with black_queenside = false }
    | Rook, 7, 7, Black ->
        (* h8 *)
        rights := { !rights with black_kingside = false }
    | _ -> ());

    (* Rook captured on initial square disables corresponding castling *)
    (match (captured, to_file, to_rank) with
    | Some Rook, 0, 0 -> rights := { !rights with white_queenside = false }
    | Some Rook, 7, 0 -> rights := { !rights with white_kingside = false }
    | Some Rook, 0, 7 -> rights := { !rights with black_queenside = false }
    | Some Rook, 7, 7 -> rights := { !rights with black_kingside = false }
    | _ -> ());

    (* Castling move disables both sides for that color *)
    (if is_castling then
       match side_to_move with
       | White ->
           rights :=
             { !rights with white_kingside = false; white_queenside = false }
       | Black ->
           rights :=
             { !rights with black_kingside = false; black_queenside = false });

    !rights

  let apply_san board ~san ~side_to_move ~castling_rights ~en_passant_target =
    Result.bind (parse_san san ~side_to_move) ~f:(function
      | `Kingside_castle ->
          let rank = match side_to_move with White -> 0 | Black -> 7 in
          let king_from_file = 4 in
          let king_to_file = 6 in
          let rook_from_file = 7 in
          let rook_to_file = 5 in

          let board = Board.set board ~file:king_from_file ~rank Empty in
          let board = Board.set board ~file:rook_from_file ~rank Empty in
          let board =
            Board.set board ~file:king_to_file ~rank
              (Piece { piece_type = King; color = side_to_move })
          in
          let board =
            Board.set board ~file:rook_to_file ~rank
              (Piece { piece_type = Rook; color = side_to_move })
          in

          let new_castling =
            update_castling_rights ~piece_moved:King ~from_file:king_from_file
              ~from_rank:rank ~captured:None ~to_file:king_to_file ~to_rank:rank
              ~side_to_move ~castling_rights ~is_castling:true
          in

          Ok
            {
              board;
              captured = None;
              castling_rights = new_castling;
              en_passant_square = None;
            }
      | `Queenside_castle ->
          let rank = match side_to_move with White -> 0 | Black -> 7 in
          let king_from_file = 4 in
          let king_to_file = 2 in
          let rook_from_file = 0 in
          let rook_to_file = 3 in

          let board = Board.set board ~file:king_from_file ~rank Empty in
          let board = Board.set board ~file:rook_from_file ~rank Empty in
          let board =
            Board.set board ~file:king_to_file ~rank
              (Piece { piece_type = King; color = side_to_move })
          in
          let board =
            Board.set board ~file:rook_to_file ~rank
              (Piece { piece_type = Rook; color = side_to_move })
          in

          let new_castling =
            update_castling_rights ~piece_moved:King ~from_file:king_from_file
              ~from_rank:rank ~captured:None ~to_file:king_to_file ~to_rank:rank
              ~side_to_move ~castling_rights ~is_castling:true
          in

          Ok
            {
              board;
              captured = None;
              castling_rights = new_castling;
              en_passant_square = None;
            }
      | `Move
          {
            piece;
            from_file;
            from_rank;
            to_file;
            to_rank;
            is_capture;
            promotion;
          } ->
          (* Find source square *)
          Result.bind
            (find_piece board ~piece ~color:side_to_move ~to_file ~to_rank
               ~from_file ~from_rank) ~f:(fun (src_file, src_rank) ->
              (* Check if this is en passant capture *)
              let is_en_passant_capture =
                phys_equal piece Pawn && is_capture
                &&
                match en_passant_target with
                | Some ep_square -> (
                    match square_notation_to_indices ep_square with
                    | Ok (ep_file, ep_rank) ->
                        to_file = ep_file && to_rank = ep_rank
                    | Error _ -> false)
                | None -> false
              in

              (* Apply move with en passant handling *)
              let board, captured =
                if is_en_passant_capture then
                  (* En passant: remove captured pawn from different rank *)
                  let captured_pawn_rank =
                    if phys_equal side_to_move White then to_rank - 1
                    else to_rank + 1
                  in
                  let board =
                    Board.set board ~file:to_file ~rank:captured_pawn_rank Empty
                  in
                  let board =
                    Board.set board ~file:src_file ~rank:src_rank Empty
                  in
                  let board =
                    Board.set board ~file:to_file ~rank:to_rank
                      (Piece { piece_type = Pawn; color = side_to_move })
                  in
                  (board, Some Pawn)
                else
                  (* Normal move/capture *)
                  let captured =
                    match Board.get board ~file:to_file ~rank:to_rank with
                    | Piece { piece_type; _ } -> Some piece_type
                    | Empty -> None
                  in
                  let moved_piece =
                    match promotion with
                    | Some promo_piece -> promo_piece
                    | None -> piece
                  in
                  let board =
                    Board.set board ~file:src_file ~rank:src_rank Empty
                  in
                  let board =
                    Board.set board ~file:to_file ~rank:to_rank
                      (Piece { piece_type = moved_piece; color = side_to_move })
                  in
                  (board, captured)
              in

              (* Compute en passant target for NEXT move *)
              let new_en_passant =
                if phys_equal piece Pawn && Int.abs (to_rank - src_rank) = 2
                then
                  let ep_rank = (src_rank + to_rank) / 2 in
                  match indices_to_square_notation to_file ep_rank with
                  | Ok sq -> Some sq
                  | Error _ -> None
                else None
              in

              (* Compute new castling rights *)
              let new_castling =
                update_castling_rights ~piece_moved:piece ~from_file:src_file
                  ~from_rank:src_rank ~captured ~to_file ~to_rank ~side_to_move
                  ~castling_rights ~is_castling:false
              in

              Ok
                {
                  board;
                  captured;
                  castling_rights = new_castling;
                  en_passant_square = new_en_passant;
                }))
end

(* FEN module *)

module Fen = struct
  type position_metadata = {
    side_to_move : color;
    castling_rights : castling_rights;
    en_passant_square : string option;
    halfmove_clock : int;
    fullmove_number : int;
  }

  let generate ~board ~metadata =
    let board_part = Board.to_fen_board board in
    let side_part = String.of_char (color_to_fen_char metadata.side_to_move) in
    let castling_part =
      let rights = metadata.castling_rights in
      let parts = [] in
      let parts = if rights.white_kingside then "K" :: parts else parts in
      let parts = if rights.white_queenside then "Q" :: parts else parts in
      let parts = if rights.black_kingside then "k" :: parts else parts in
      let parts = if rights.black_queenside then "q" :: parts else parts in
      if List.is_empty parts then "-"
      else String.concat ~sep:"" (List.rev parts)
    in
    let en_passant_part =
      match metadata.en_passant_square with None -> "-" | Some sq -> sq
    in
    let halfmove_part = Int.to_string metadata.halfmove_clock in
    let fullmove_part = Int.to_string metadata.fullmove_number in
    String.concat ~sep:" "
      [
        board_part;
        side_part;
        castling_part;
        en_passant_part;
        halfmove_part;
        fullmove_part;
      ]

  let parse fen =
    let parts = String.split ~on:' ' fen in
    match parts with
    | [
     board_part;
     side_part;
     castling_part;
     en_passant_part;
     halfmove_part;
     fullmove_part;
    ] ->
        Result.bind (Board.of_fen_board board_part) ~f:(fun board ->
            Result.bind
              (if String.length side_part = 1 then
                 color_of_fen_char (String.get side_part 0)
               else Error "Invalid side-to-move field")
              ~f:(fun side_to_move ->
                let castling_rights =
                  {
                    white_kingside = String.contains castling_part 'K';
                    white_queenside = String.contains castling_part 'Q';
                    black_kingside = String.contains castling_part 'k';
                    black_queenside = String.contains castling_part 'q';
                  }
                in
                let en_passant_square =
                  if String.equal en_passant_part "-" then None
                  else Some en_passant_part
                in
                match
                  ( Int.of_string_opt halfmove_part,
                    Int.of_string_opt fullmove_part )
                with
                | Some halfmove_clock, Some fullmove_number ->
                    let metadata =
                      {
                        side_to_move;
                        castling_rights;
                        en_passant_square;
                        halfmove_clock;
                        fullmove_number;
                      }
                    in
                    Ok (board, metadata)
                | _ -> Error "Invalid halfmove or fullmove number"))
    | _ ->
        Error
          (Printf.sprintf "Invalid FEN format: expected 6 fields, got %d"
             (List.length parts))

  let validate fen =
    match parse fen with Ok _ -> Ok () | Error msg -> Error msg
end
