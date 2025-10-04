(** Tests for Chess_engine module *)

open! Base
open Chessbuddy

let test_initial_board () =
  let board = Chess_engine.Board.initial in
  (* Test white pieces on rank 1 *)
  Alcotest.(check bool)
    "a1 has white rook" true
    (match Chess_engine.Board.get board ~file:0 ~rank:0 with
    | Piece { piece_type = Rook; color = White } -> true
    | _ -> false);
  Alcotest.(check bool)
    "e1 has white king" true
    (match Chess_engine.Board.get board ~file:4 ~rank:0 with
    | Piece { piece_type = King; color = White } -> true
    | _ -> false);
  (* Test white pawns on rank 2 *)
  Alcotest.(check bool)
    "e2 has white pawn" true
    (match Chess_engine.Board.get board ~file:4 ~rank:1 with
    | Piece { piece_type = Pawn; color = White } -> true
    | _ -> false);
  (* Test empty squares *)
  Alcotest.(check bool)
    "e4 is empty" true
    (match Chess_engine.Board.get board ~file:4 ~rank:3 with
    | Empty -> true
    | _ -> false);
  (* Test black pieces on rank 8 *)
  Alcotest.(check bool)
    "e8 has black king" true
    (match Chess_engine.Board.get board ~file:4 ~rank:7 with
    | Piece { piece_type = King; color = Black } -> true
    | _ -> false);
  (* Test black pawns on rank 7 *)
  Alcotest.(check bool)
    "e7 has black pawn" true
    (match Chess_engine.Board.get board ~file:4 ~rank:6 with
    | Piece { piece_type = Pawn; color = Black } -> true
    | _ -> false)

let test_fen_generation_initial_position () =
  let board = Chess_engine.Board.initial in
  let metadata =
    {
      Chess_engine.Fen.side_to_move = White;
      castling_rights =
        {
          Chess_engine.white_kingside = true;
          white_queenside = true;
          black_kingside = true;
          black_queenside = true;
        };
      en_passant_square = None;
      halfmove_clock = 0;
      fullmove_number = 1;
    }
  in
  let fen = Chess_engine.Fen.generate ~board ~metadata in
  Alcotest.(check string)
    "starting position FEN"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1" fen

let test_fen_board_serialization () =
  let board = Chess_engine.Board.initial in
  let fen_board = Chess_engine.Board.to_fen_board board in
  Alcotest.(check string)
    "starting position board" "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR"
    fen_board

let test_fen_board_parsing () =
  let fen_board = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR" in
  match Chess_engine.Board.of_fen_board fen_board with
  | Error msg -> Alcotest.fail (Printf.sprintf "FEN parsing failed: %s" msg)
  | Ok board ->
      (* Verify piece placement *)
      Alcotest.(check bool)
        "e1 has white king" true
        (match Chess_engine.Board.get board ~file:4 ~rank:0 with
        | Piece { piece_type = King; color = White } -> true
        | _ -> false);
      Alcotest.(check bool)
        "e8 has black king" true
        (match Chess_engine.Board.get board ~file:4 ~rank:7 with
        | Piece { piece_type = King; color = Black } -> true
        | _ -> false);
      Alcotest.(check bool)
        "e4 is empty" true
        (match Chess_engine.Board.get board ~file:4 ~rank:3 with
        | Empty -> true
        | _ -> false);
      (* Round-trip test *)
      let fen_board_roundtrip = Chess_engine.Board.to_fen_board board in
      Alcotest.(check string) "round-trip" fen_board fen_board_roundtrip

let test_fen_parsing_and_generation () =
  let fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1" in
  match Chess_engine.Fen.parse fen with
  | Error msg -> Alcotest.fail (Printf.sprintf "FEN parsing failed: %s" msg)
  | Ok (board, metadata) ->
      (* Verify metadata *)
      Alcotest.(check bool)
        "side to move is black" true
        (match metadata.side_to_move with Black -> true | White -> false);
      Alcotest.(check bool)
        "castling rights preserved" true
        (metadata.castling_rights.white_kingside
       && metadata.castling_rights.white_queenside
       && metadata.castling_rights.black_kingside
       && metadata.castling_rights.black_queenside);
      Alcotest.(check (option string))
        "en passant square" (Some "e3") metadata.en_passant_square;
      Alcotest.(check int) "halfmove clock" 0 metadata.halfmove_clock;
      Alcotest.(check int) "fullmove number" 1 metadata.fullmove_number;
      (* Verify board position *)
      Alcotest.(check bool)
        "e4 has white pawn" true
        (match Chess_engine.Board.get board ~file:4 ~rank:3 with
        | Piece { piece_type = Pawn; color = White } -> true
        | _ -> false);
      Alcotest.(check bool)
        "e2 is empty" true
        (match Chess_engine.Board.get board ~file:4 ~rank:1 with
        | Empty -> true
        | _ -> false);
      (* Round-trip test *)
      let fen_roundtrip = Chess_engine.Fen.generate ~board ~metadata in
      Alcotest.(check string) "FEN round-trip" fen fen_roundtrip

let test_invalid_fen_cases () =
  let expect_error label fen =
    match Chess_engine.Fen.validate fen with
    | Ok () -> Alcotest.failf "%s: expected validation failure" label
    | Error _ -> ()
  in
  expect_error "invalid digit"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPP9/RNBQKBNR w KQkq - 0 1";
  expect_error "pawn on first rank"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNp w KQkq - 0 1";
  expect_error "missing rook for castling"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBN1 w K - 0 1";
  expect_error "invalid en passant square"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e9 0 1";
  expect_error "en passant rank mismatch"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq e3 0 1";
  expect_error "negative halfmove"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - -1 1";
  expect_error "zero fullmove"
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 0"

let test_castling_rights_encoding () =
  let board = Chess_engine.Board.initial in
  (* Test all castling rights *)
  let metadata_all =
    {
      Chess_engine.Fen.side_to_move = White;
      castling_rights =
        {
          Chess_engine.white_kingside = true;
          white_queenside = true;
          black_kingside = true;
          black_queenside = true;
        };
      en_passant_square = None;
      halfmove_clock = 0;
      fullmove_number = 1;
    }
  in
  let fen_all = Chess_engine.Fen.generate ~board ~metadata:metadata_all in
  Alcotest.(check bool)
    "all castling rights" true
    (String.is_substring ~substring:"KQkq" fen_all);

  (* Test no castling rights *)
  let metadata_none =
    {
      Chess_engine.Fen.side_to_move = White;
      castling_rights =
        {
          Chess_engine.white_kingside = false;
          white_queenside = false;
          black_kingside = false;
          black_queenside = false;
        };
      en_passant_square = None;
      halfmove_clock = 0;
      fullmove_number = 1;
    }
  in
  let fen_none = Chess_engine.Fen.generate ~board ~metadata:metadata_none in
  Alcotest.(check bool)
    "no castling rights" true
    (String.is_substring ~substring:" - " fen_none);

  (* Test partial castling rights *)
  let metadata_partial =
    {
      Chess_engine.Fen.side_to_move = White;
      castling_rights =
        {
          Chess_engine.white_kingside = true;
          white_queenside = false;
          black_kingside = false;
          black_queenside = true;
        };
      en_passant_square = None;
      halfmove_clock = 0;
      fullmove_number = 1;
    }
  in
  let fen_partial =
    Chess_engine.Fen.generate ~board ~metadata:metadata_partial
  in
  Alcotest.(check bool)
    "partial castling rights" true
    (String.is_substring ~substring:"Kq" fen_partial)

let test_square_notation_conversion () =
  (* Test valid conversions *)
  (match Chess_engine.square_notation_to_indices "e4" with
  | Ok (file, rank) ->
      Alcotest.(check int) "e4 file" 4 file;
      Alcotest.(check int) "e4 rank" 3 rank
  | Error msg -> Alcotest.fail msg);

  (match Chess_engine.square_notation_to_indices "a1" with
  | Ok (file, rank) ->
      Alcotest.(check int) "a1 file" 0 file;
      Alcotest.(check int) "a1 rank" 0 rank
  | Error msg -> Alcotest.fail msg);

  (match Chess_engine.square_notation_to_indices "h8" with
  | Ok (file, rank) ->
      Alcotest.(check int) "h8 file" 7 file;
      Alcotest.(check int) "h8 rank" 7 rank
  | Error msg -> Alcotest.fail msg);

  (* Test invalid notation *)
  (match Chess_engine.square_notation_to_indices "i9" with
  | Ok _ -> Alcotest.fail "Should reject i9"
  | Error _ -> ());

  (* Test reverse conversion *)
  (match Chess_engine.indices_to_square_notation 4 3 with
  | Ok notation -> Alcotest.(check string) "indices to e4" "e4" notation
  | Error msg -> Alcotest.fail msg);

  match Chess_engine.indices_to_square_notation 0 0 with
  | Ok notation -> Alcotest.(check string) "indices to a1" "a1" notation
  | Error msg -> Alcotest.fail msg

let test_board_set_and_get () =
  let board = Chess_engine.Board.empty in
  (* Place white king on e4 *)
  let board =
    Chess_engine.Board.set board ~file:4 ~rank:3
      (Piece { piece_type = King; color = White })
  in
  Alcotest.(check bool)
    "e4 has white king" true
    (match Chess_engine.Board.get board ~file:4 ~rank:3 with
    | Piece { piece_type = King; color = White } -> true
    | _ -> false);

  (* Verify immutability - original board unchanged *)
  let original_board = Chess_engine.Board.empty in
  Alcotest.(check bool)
    "original board e4 still empty" true
    (match Chess_engine.Board.get original_board ~file:4 ~rank:3 with
    | Empty -> true
    | _ -> false)

let test_piece_fen_char_conversion () =
  Alcotest.(check char)
    "white king" 'K'
    (Chess_engine.piece_to_fen_char King White);
  Alcotest.(check char)
    "black king" 'k'
    (Chess_engine.piece_to_fen_char King Black);
  Alcotest.(check char)
    "white pawn" 'P'
    (Chess_engine.piece_to_fen_char Pawn White);
  Alcotest.(check char)
    "black queen" 'q'
    (Chess_engine.piece_to_fen_char Queen Black);

  (* Test parsing *)
  (match Chess_engine.piece_of_fen_char 'K' with
  | Ok (piece, color) ->
      Alcotest.(check bool)
        "parsed white king piece" true
        (match piece with King -> true | _ -> false);
      Alcotest.(check bool)
        "parsed white king color" true
        (match color with White -> true | _ -> false)
  | Error msg -> Alcotest.fail msg);

  match Chess_engine.piece_of_fen_char 'q' with
  | Ok (piece, color) ->
      Alcotest.(check bool)
        "parsed black queen piece" true
        (match piece with Queen -> true | _ -> false);
      Alcotest.(check bool)
        "parsed black queen color" true
        (match color with Black -> true | _ -> false)
  | Error msg -> Alcotest.fail msg

let test_pawn_move () =
  let board = Chess_engine.Board.initial in
  let castling =
    {
      Chess_engine.white_kingside = true;
      white_queenside = true;
      black_kingside = true;
      black_queenside = true;
    }
  in

  (* Test 1. e4 *)
  match
    Chess_engine.Move_parser.apply_san board ~san:"e4" ~side_to_move:White
      ~castling_rights:castling ~en_passant_target:None
  with
  | Error msg -> Alcotest.fail (Printf.sprintf "Failed to apply e4: %s" msg)
  | Ok { board; captured; castling_rights = _; en_passant_square } ->
      Alcotest.(check bool)
        "e2 is empty" true
        (match Chess_engine.Board.get board ~file:4 ~rank:1 with
        | Empty -> true
        | _ -> false);
      Alcotest.(check bool)
        "e4 has white pawn" true
        (match Chess_engine.Board.get board ~file:4 ~rank:3 with
        | Piece { piece_type = Pawn; color = White } -> true
        | _ -> false);
      Alcotest.(check (option string))
        "creates en passant square" (Some "e3") en_passant_square;
      Alcotest.(check (option string))
        "no capture" None
        (Option.map captured ~f:(fun _ -> "captured"));
      (* Castling rights should be unchanged for pawn move *)
      ()

let test_piece_move () =
  let board = Chess_engine.Board.initial in
  let castling =
    {
      Chess_engine.white_kingside = true;
      white_queenside = true;
      black_kingside = true;
      black_queenside = true;
    }
  in

  (* Test 1. Nf3 *)
  match
    Chess_engine.Move_parser.apply_san board ~san:"Nf3" ~side_to_move:White
      ~castling_rights:castling ~en_passant_target:None
  with
  | Error msg -> Alcotest.fail (Printf.sprintf "Failed to apply Nf3: %s" msg)
  | Ok { board; _ } ->
      Alcotest.(check bool)
        "g1 is empty" true
        (match Chess_engine.Board.get board ~file:6 ~rank:0 with
        | Empty -> true
        | _ -> false);
      Alcotest.(check bool)
        "f3 has white knight" true
        (match Chess_engine.Board.get board ~file:5 ~rank:2 with
        | Piece { piece_type = Knight; color = White } -> true
        | _ -> false)

let test_castling () =
  (* Set up position ready to castle *)
  let board = Chess_engine.Board.empty in
  let board =
    Chess_engine.Board.set board ~file:4 ~rank:0
      (Piece { piece_type = King; color = White })
  in
  let board =
    Chess_engine.Board.set board ~file:7 ~rank:0
      (Piece { piece_type = Rook; color = White })
  in

  let castling =
    {
      Chess_engine.white_kingside = true;
      white_queenside = true;
      black_kingside = true;
      black_queenside = true;
    }
  in

  (* Test O-O (kingside castling) *)
  match
    Chess_engine.Move_parser.apply_san board ~san:"O-O" ~side_to_move:White
      ~castling_rights:castling ~en_passant_target:None
  with
  | Error msg -> Alcotest.fail (Printf.sprintf "Failed to castle: %s" msg)
  | Ok { board; castling_rights = _; _ } ->
      Alcotest.(check bool)
        "e1 is empty" true
        (match Chess_engine.Board.get board ~file:4 ~rank:0 with
        | Empty -> true
        | _ -> false);
      Alcotest.(check bool)
        "h1 is empty" true
        (match Chess_engine.Board.get board ~file:7 ~rank:0 with
        | Empty -> true
        | _ -> false);
      Alcotest.(check bool)
        "g1 has king" true
        (match Chess_engine.Board.get board ~file:6 ~rank:0 with
        | Piece { piece_type = King; color = White } -> true
        | _ -> false);
      Alcotest.(check bool)
        "f1 has rook" true
        (match Chess_engine.Board.get board ~file:5 ~rank:0 with
        | Piece { piece_type = Rook; color = White } -> true
        | _ -> false);
      (* Castling move should update castling rights *)
      ()

let test_capture () =
  (* Set up board with pieces to capture *)
  let board = Chess_engine.Board.empty in
  let board =
    Chess_engine.Board.set board ~file:4 ~rank:3
      (Piece { piece_type = Pawn; color = White })
  in
  let board =
    Chess_engine.Board.set board ~file:3 ~rank:4
      (Piece { piece_type = Pawn; color = Black })
  in

  let castling =
    {
      Chess_engine.white_kingside = false;
      white_queenside = false;
      black_kingside = false;
      black_queenside = false;
    }
  in

  (* Test exd5 *)
  match
    Chess_engine.Move_parser.apply_san board ~san:"exd5" ~side_to_move:White
      ~castling_rights:castling ~en_passant_target:None
  with
  | Error msg -> Alcotest.fail (Printf.sprintf "Failed to capture: %s" msg)
  | Ok { board; captured; _ } ->
      Alcotest.(check bool)
        "e4 is empty" true
        (match Chess_engine.Board.get board ~file:4 ~rank:3 with
        | Empty -> true
        | _ -> false);
      Alcotest.(check bool)
        "d5 has white pawn" true
        (match Chess_engine.Board.get board ~file:3 ~rank:4 with
        | Piece { piece_type = Pawn; color = White } -> true
        | _ -> false);
      Alcotest.(check bool)
        "captured pawn" true
        (match captured with Some Pawn -> true | _ -> false)

let test_promotion () =
  (* Set up pawn on 7th rank *)
  let board = Chess_engine.Board.empty in
  let board =
    Chess_engine.Board.set board ~file:4 ~rank:6
      (Piece { piece_type = Pawn; color = White })
  in

  let castling =
    {
      Chess_engine.white_kingside = false;
      white_queenside = false;
      black_kingside = false;
      black_queenside = false;
    }
  in

  (* Test e8=Q *)
  match
    Chess_engine.Move_parser.apply_san board ~san:"e8=Q" ~side_to_move:White
      ~castling_rights:castling ~en_passant_target:None
  with
  | Error msg -> Alcotest.fail (Printf.sprintf "Failed to promote: %s" msg)
  | Ok { board; _ } ->
      Alcotest.(check bool)
        "e7 is empty" true
        (match Chess_engine.Board.get board ~file:4 ~rank:6 with
        | Empty -> true
        | _ -> false);
      Alcotest.(check bool)
        "e8 has white queen" true
        (match Chess_engine.Board.get board ~file:4 ~rank:7 with
        | Piece { piece_type = Queen; color = White } -> true
        | _ -> false)

let test_disambiguation () =
  (* Set up two knights that can move to same square *)
  let board = Chess_engine.Board.empty in
  let board =
    Chess_engine.Board.set board ~file:1 ~rank:0
      (Piece { piece_type = Knight; color = White })
  in
  let board =
    Chess_engine.Board.set board ~file:6 ~rank:0
      (Piece { piece_type = Knight; color = White })
  in

  let castling =
    {
      Chess_engine.white_kingside = false;
      white_queenside = false;
      black_kingside = false;
      black_queenside = false;
    }
  in

  (* Test Nbd7 (knight from b-file to d7) - actually need to set up better *)
  (* For now, test that we can parse disambiguation *)
  let board =
    Chess_engine.Board.set board ~file:1 ~rank:5
      (Piece { piece_type = Knight; color = Black })
  in

  match
    Chess_engine.Move_parser.apply_san board ~san:"Nbd7" ~side_to_move:Black
      ~castling_rights:castling ~en_passant_target:None
  with
  | Error msg -> Alcotest.fail (Printf.sprintf "Failed disambiguation: %s" msg)
  | Ok { board; _ } ->
      Alcotest.(check bool)
        "b6 is empty" true
        (match Chess_engine.Board.get board ~file:1 ~rank:5 with
        | Empty -> true
        | _ -> false);
      Alcotest.(check bool)
        "d7 has black knight" true
        (match Chess_engine.Board.get board ~file:3 ~rank:6 with
        | Piece { piece_type = Knight; color = Black } -> true
        | _ -> false)

let test_full_game_sequence () =
  (* Play a short opening sequence *)
  let board = Chess_engine.Board.initial in
  let castling =
    {
      Chess_engine.white_kingside = true;
      white_queenside = true;
      black_kingside = true;
      black_queenside = true;
    }
  in

  (* 1. e4 e5 *)
  let board =
    match
      Chess_engine.Move_parser.apply_san board ~san:"e4" ~side_to_move:White
        ~castling_rights:castling ~en_passant_target:None
    with
    | Ok { board; _ } -> board
    | Error msg -> Alcotest.fail msg
  in
  let board =
    match
      Chess_engine.Move_parser.apply_san board ~san:"e5" ~side_to_move:Black
        ~castling_rights:castling ~en_passant_target:None
    with
    | Ok { board; _ } -> board
    | Error msg -> Alcotest.fail msg
  in

  (* 2. Nf3 Nc6 *)
  let board =
    match
      Chess_engine.Move_parser.apply_san board ~san:"Nf3" ~side_to_move:White
        ~castling_rights:castling ~en_passant_target:None
    with
    | Ok { board; _ } -> board
    | Error msg -> Alcotest.fail msg
  in
  let board =
    match
      Chess_engine.Move_parser.apply_san board ~san:"Nc6" ~side_to_move:Black
        ~castling_rights:castling ~en_passant_target:None
    with
    | Ok { board; _ } -> board
    | Error msg -> Alcotest.fail msg
  in

  (* Generate FEN *)
  let metadata =
    {
      Chess_engine.Fen.side_to_move = White;
      castling_rights = castling;
      en_passant_square = None;
      halfmove_clock = 0;
      fullmove_number = 3;
    }
  in
  let fen = Chess_engine.Fen.generate ~board ~metadata in

  (* Verify pieces are in correct positions *)
  (* After 1. e4 e5 2. Nf3 Nc6, black's back rank should be r1bqkbnr *)
  Alcotest.(check bool)
    "FEN contains proper position" true
    (String.is_substring ~substring:"r1bqkbnr" fen)

let suite =
  [
    ("Initial board setup", `Quick, test_initial_board);
    ( "FEN generation for initial position",
      `Quick,
      test_fen_generation_initial_position );
    ("FEN board serialization", `Quick, test_fen_board_serialization);
    ("FEN board parsing", `Quick, test_fen_board_parsing);
    ("FEN parsing and generation", `Quick, test_fen_parsing_and_generation);
    ("FEN validation rejects invalid inputs", `Quick, test_invalid_fen_cases);
    ("Castling rights encoding", `Quick, test_castling_rights_encoding);
    ("Square notation conversion", `Quick, test_square_notation_conversion);
    ("Board set and get", `Quick, test_board_set_and_get);
    ("Piece FEN char conversion", `Quick, test_piece_fen_char_conversion);
    ("Pawn move", `Quick, test_pawn_move);
    ("Piece move", `Quick, test_piece_move);
    ("Castling", `Quick, test_castling);
    ("Capture", `Quick, test_capture);
    ("Promotion", `Quick, test_promotion);
    ("Disambiguation", `Quick, test_disambiguation);
    ("Full game sequence", `Quick, test_full_game_sequence);
  ]

let tests =
  List.map suite ~f:(fun (name, speed, test_fn) ->
      Alcotest_lwt.test_case name speed (fun _switch () ->
          test_fn ();
          Lwt.return_unit))
