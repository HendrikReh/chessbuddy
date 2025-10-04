open! Base
open Chess_engine
open Lwt.Infix
open Pattern_detector
module PS = Pawn_structure
module Move = Types.Move_feature

let parse_board fen =
  match Chess_engine.Fen.parse fen with
  | Ok (board, _) -> Some board
  | Error _ -> None

let starting_board () = parse_board Fen_generator.starting_position_fen
let opponent = function White -> Black | Black -> White

let result_to_outcome result color =
  match (result, color) with
  | "1-0", White -> Victory
  | "0-1", Black -> Victory
  | "1/2-1/2", _ -> DrawNeutral
  | "1-0", Black -> Defeat
  | "0-1", White -> Defeat
  | _ -> DrawNeutral

module Queenside_majority : PATTERN_DETECTOR = struct
  let pattern_id = "queenside_majority_attack"
  let pattern_name = "Queenside Majority Attack"
  let pattern_type = `Strategic

  type push = {
    ply : int;
    file : int;
    rank : int;
    double_step : bool;
    capture : bool;
  }

  type color_state = {
    majority_span : int;
    first_majority_ply : int option;
    last_majority_ply : int option;
    pushes : push list;
    passed_created : bool;
    opponent_pawn_removed : bool;
    opponent_island_delta : int;
    max_rank : int option;
  }

  type state = { white : color_state; black : color_state }

  let empty_color_state =
    {
      majority_span = 0;
      first_majority_ply = None;
      last_majority_ply = None;
      pushes = [];
      passed_created = false;
      opponent_pawn_removed = false;
      opponent_island_delta = 0;
      max_rank = None;
    }

  let initial_state = { white = empty_color_state; black = empty_color_state }

  let update_max_rank color current after_board =
    match PS.max_rank_in_zone after_board ~color ~zone:`Queenside with
    | None -> current
    | Some rank -> (
        match current with
        | None -> Some rank
        | Some existing ->
            if Poly.equal color White then Some (Int.max existing rank)
            else Some (Int.min existing rank))

  let update_color color state ~before_board ~after_board move =
    match (before_board, after_board) with
    | None, _ | _, None -> state
    | Some before_board, Some after_board -> (
        let color_state =
          match color with White -> state.white | Black -> state.black
        in
        let has_majority =
          PS.has_zone_majority after_board ~zone:`Queenside ~color
        in
        let first_majority_ply =
          match color_state.first_majority_ply with
          | Some p -> Some p
          | None -> if has_majority then Some move.Move.ply_number else None
        in
        let last_majority_ply =
          if has_majority then Some move.Move.ply_number
          else color_state.last_majority_ply
        in
        let majority_span =
          if has_majority then color_state.majority_span + 1
          else color_state.majority_span
        in
        let transition =
          PS.detect_transition ~before:before_board ~after:after_board ~color
            ~zone:`Queenside
        in
        let pushes =
          match transition with
          | None -> color_state.pushes
          | Some t ->
              let push =
                {
                  ply = move.Move.ply_number;
                  file = t.to_file;
                  rank = t.to_rank;
                  double_step = t.double_step;
                  capture = t.is_capture;
                }
              in
              push :: color_state.pushes
        in
        let passed_created =
          color_state.passed_created
          || PS.passed_pawn_created ~before:before_board ~after:after_board
               ~color ~zone:`Queenside
        in
        let opponent_pawn_removed =
          color_state.opponent_pawn_removed
          || PS.opponent_pawn_removed ~before:before_board ~after:after_board
               ~color ~zone:`Queenside
        in
        let island_delta =
          let opponent_color = opponent color in
          let before_islands =
            PS.island_count before_board ~color:opponent_color
          in
          let after_islands =
            PS.island_count after_board ~color:opponent_color
          in
          Int.max 0 (after_islands - before_islands)
        in
        let opponent_island_delta =
          color_state.opponent_island_delta + island_delta
        in
        let max_rank = update_max_rank color color_state.max_rank after_board in
        let updated =
          {
            majority_span;
            first_majority_ply;
            last_majority_ply;
            pushes;
            passed_created;
            opponent_pawn_removed;
            opponent_island_delta;
            max_rank;
          }
        in
        match color with
        | White -> { state with white = updated }
        | Black -> { state with black = updated })

  let rec step state prev_board = function
    | [] -> Lwt.return state
    | move :: rest ->
        let board_before =
          match prev_board with
          | Some board -> Some board
          | None -> parse_board move.Move.fen_before
        in
        let board_after = parse_board move.Move.fen_after in
        let state =
          update_color White state ~before_board:board_before
            ~after_board:board_after move
        in
        let state =
          update_color Black state ~before_board:board_before
            ~after_board:board_after move
        in
        step state board_after rest

  let confidence_for color_state color =
    let push_count = List.length color_state.pushes in
    let base = 0.55 in
    let span_bonus =
      Float.min 0.25 (Float.of_int color_state.majority_span *. 0.05)
    in
    let push_bonus = Float.min 0.2 (Float.of_int push_count *. 0.08) in
    let contact_bonus =
      if color_state.opponent_pawn_removed then 0.1 else 0.0
    in
    let passed_bonus = if color_state.passed_created then 0.15 else 0.0 in
    let islands_bonus =
      Float.min 0.1 (Float.of_int color_state.opponent_island_delta *. 0.05)
    in
    let infiltration_bonus =
      match color_state.max_rank with
      | None -> 0.0
      | Some rank -> (
          match color with
          | White when rank >= 4 -> 0.1
          | Black when rank <= 3 -> 0.1
          | _ -> 0.0)
    in
    Float.min 1.0
      (base +. span_bonus +. push_bonus +. contact_bonus +. passed_bonus
     +. islands_bonus +. infiltration_bonus)

  let push_to_json { ply; file; rank; double_step; capture } =
    `Assoc
      [
        ("ply", `Int ply);
        ("file", `Int file);
        ("rank", `Int rank);
        ("double_step", `Bool double_step);
        ("capture", `Bool capture);
      ]

  let metadata_for color_state =
    let push_count = List.length color_state.pushes in
    let pushes_json =
      color_state.pushes |> List.rev_map ~f:push_to_json |> fun lst -> `List lst
    in
    [
      ("push_count", `Int push_count);
      ("passed_pawn", `Bool color_state.passed_created);
      ("opponent_contact", `Bool color_state.opponent_pawn_removed);
      ("opponent_island_delta", `Int color_state.opponent_island_delta);
      ("pushes", pushes_json);
    ]
    |> fun lst ->
    match color_state.max_rank with
    | None -> lst
    | Some rank -> ("max_rank", `Int rank) :: lst

  let summarise color color_state =
    let push_count = List.length color_state.pushes in
    let has_duration = color_state.majority_span >= 3 in
    let has_pressure = push_count >= 2 in
    let has_conversion =
      color_state.passed_created || color_state.opponent_pawn_removed
      || push_count >= 2
    in
    if not (has_duration && has_pressure && has_conversion) then None
    else
      let confidence = confidence_for color_state color in
      let metadata = metadata_for color_state in
      Some
        {
          detected = true;
          confidence;
          initiating_color = Some color;
          start_ply = color_state.first_majority_ply;
          end_ply = color_state.last_majority_ply;
          metadata;
        }

  let detect ~moves ~result:_ =
    let initial_board =
      match moves with
      | [] -> starting_board ()
      | move :: _ -> parse_board move.Move.fen_before
    in
    step initial_state initial_board moves >>= fun final_state ->
    match summarise White final_state.white with
    | Some detection -> Lwt.return detection
    | None -> (
        match summarise Black final_state.black with
        | Some detection -> Lwt.return detection
        | None ->
            Lwt.return
              {
                detected = false;
                confidence = 0.0;
                initiating_color = None;
                start_ply = None;
                end_ply = None;
                metadata = [];
              })

  let classify_success ~detection ~result =
    if not detection.detected then Lwt.return (false, DrawNeutral)
    else
      let outcome =
        match detection.initiating_color with
        | Some color -> result_to_outcome result color
        | None -> DrawNeutral
      in
      let success =
        match outcome with
        | Victory | DrawAdvantage -> true
        | DrawNeutral | Defeat -> false
      in
      Lwt.return (success, outcome)
end

module Minority_attack : PATTERN_DETECTOR = struct
  let pattern_id = "minority_attack"
  let pattern_name = "Minority Attack"
  let pattern_type = `Strategic

  type push = { ply : int; file : int; rank : int; capture : bool }

  type color_state = {
    minority_seen : bool;
    start_ply : int option;
    last_event_ply : int option;
    pushes : push list;
    contact_made : bool;
    opponent_island_delta : int;
    passed_created : bool;
    max_rank : int option;
  }

  type state = { white : color_state; black : color_state }

  let empty_color_state =
    {
      minority_seen = false;
      start_ply = None;
      last_event_ply = None;
      pushes = [];
      contact_made = false;
      opponent_island_delta = 0;
      passed_created = false;
      max_rank = None;
    }

  let initial_state = { white = empty_color_state; black = empty_color_state }

  let update_max_rank color current after_board =
    match PS.max_rank_in_zone after_board ~color ~zone:`Queenside with
    | None -> current
    | Some rank -> (
        match current with
        | None -> Some rank
        | Some existing ->
            if Poly.equal color White then Some (Int.max existing rank)
            else Some (Int.min existing rank))

  let update_color color state ~before_board ~after_board move =
    match (before_board, after_board) with
    | None, _ | _, None -> state
    | Some before_board, Some after_board -> (
        let color_state =
          match color with White -> state.white | Black -> state.black
        in
        let our_count = PS.count_zone after_board ~color `Queenside in
        let opp_count =
          PS.count_zone after_board ~color:(opponent color) `Queenside
        in
        let minority_seen =
          color_state.minority_seen || our_count < opp_count
        in
        let transition =
          PS.detect_transition ~before:before_board ~after:after_board ~color
            ~zone:`Queenside
        in
        let pushes =
          match transition with
          | None -> color_state.pushes
          | Some t ->
              let push =
                {
                  ply = move.Move.ply_number;
                  file = t.to_file;
                  rank = t.to_rank;
                  capture = t.is_capture;
                }
              in
              push :: color_state.pushes
        in
        let contact_made =
          color_state.contact_made
          || Option.exists transition ~f:(fun t -> t.is_capture)
          || PS.opponent_pawn_removed ~before:before_board ~after:after_board
               ~color ~zone:`Queenside
        in
        let passed_created =
          color_state.passed_created
          || PS.passed_pawn_created ~before:before_board ~after:after_board
               ~color ~zone:`Queenside
        in
        let island_delta =
          let opponent_color = opponent color in
          let before_islands =
            PS.island_count before_board ~color:opponent_color
          in
          let after_islands =
            PS.island_count after_board ~color:opponent_color
          in
          Int.max 0 (after_islands - before_islands)
        in
        let opponent_island_delta =
          color_state.opponent_island_delta + island_delta
        in
        let max_rank = update_max_rank color color_state.max_rank after_board in
        let start_ply =
          match color_state.start_ply with
          | Some ply -> Some ply
          | None ->
              if minority_seen && Option.is_some transition then
                Some move.Move.ply_number
              else color_state.start_ply
        in
        let last_event_ply =
          if Option.is_some transition || contact_made || island_delta > 0 then
            Some move.Move.ply_number
          else color_state.last_event_ply
        in
        let updated =
          {
            minority_seen;
            start_ply;
            last_event_ply;
            pushes;
            contact_made;
            opponent_island_delta;
            passed_created;
            max_rank;
          }
        in
        match color with
        | White -> { state with white = updated }
        | Black -> { state with black = updated })

  let rec step state prev_board = function
    | [] -> Lwt.return state
    | move :: rest ->
        let board_before =
          match prev_board with
          | Some board -> Some board
          | None -> parse_board move.Move.fen_before
        in
        let board_after = parse_board move.Move.fen_after in
        let state =
          update_color White state ~before_board:board_before
            ~after_board:board_after move
        in
        let state =
          update_color Black state ~before_board:board_before
            ~after_board:board_after move
        in
        step state board_after rest

  let confidence_for color_state color =
    let push_count = List.length color_state.pushes in
    let base = 0.45 in
    let push_bonus = Float.min 0.25 (Float.of_int push_count *. 0.1) in
    let contact_bonus = if color_state.contact_made then 0.2 else 0.0 in
    let islands_bonus =
      Float.min 0.15 (Float.of_int color_state.opponent_island_delta *. 0.05)
    in
    let passed_bonus = if color_state.passed_created then 0.1 else 0.0 in
    let infiltration_bonus =
      match color_state.max_rank with
      | None -> 0.0
      | Some rank -> (
          match color with
          | White when rank >= 4 -> 0.05
          | Black when rank <= 3 -> 0.05
          | _ -> 0.0)
    in
    Float.min 1.0
      (base +. push_bonus +. contact_bonus +. islands_bonus +. passed_bonus
     +. infiltration_bonus)

  let metadata_for color_state =
    let push_count = List.length color_state.pushes in
    let pushes_json =
      color_state.pushes
      |> List.rev_map ~f:(fun push ->
             `Assoc
               [
                 ("ply", `Int push.ply);
                 ("file", `Int push.file);
                 ("rank", `Int push.rank);
                 ("capture", `Bool push.capture);
               ])
      |> fun lst -> `List lst
    in
    [
      ("push_count", `Int push_count);
      ("contact", `Bool color_state.contact_made);
      ("opponent_island_delta", `Int color_state.opponent_island_delta);
      ("passed_pawn", `Bool color_state.passed_created);
      ("pushes", pushes_json);
    ]
    |> fun lst ->
    match color_state.max_rank with
    | None -> lst
    | Some rank -> ("max_rank", `Int rank) :: lst

  let summarise color color_state =
    let push_count = List.length color_state.pushes in
    let has_minor = color_state.minority_seen in
    let sufficient_pushes = push_count >= 2 in
    let has_progress =
      color_state.contact_made
      || color_state.opponent_island_delta > 0
      || color_state.passed_created
    in
    if not (has_minor && sufficient_pushes && has_progress) then None
    else
      let confidence = confidence_for color_state color in
      let metadata = metadata_for color_state in
      Some
        {
          detected = true;
          confidence;
          initiating_color = Some color;
          start_ply = color_state.start_ply;
          end_ply = color_state.last_event_ply;
          metadata;
        }

  let detect ~moves ~result:_ =
    let initial_board =
      match moves with
      | [] -> starting_board ()
      | move :: _ -> parse_board move.Move.fen_before
    in
    step initial_state initial_board moves >>= fun final_state ->
    match summarise White final_state.white with
    | Some detection -> Lwt.return detection
    | None -> (
        match summarise Black final_state.black with
        | Some detection -> Lwt.return detection
        | None ->
            Lwt.return
              {
                detected = false;
                confidence = 0.0;
                initiating_color = None;
                start_ply = None;
                end_ply = None;
                metadata = [];
              })

  let classify_success ~detection ~result =
    if not detection.detected then Lwt.return (false, DrawNeutral)
    else
      let color = Option.value detection.initiating_color ~default:White in
      let outcome = result_to_outcome result color in
      let success =
        match outcome with
        | Victory -> true
        | DrawAdvantage | DrawNeutral -> true
        | Defeat -> false
      in
      Lwt.return (success, outcome)
end

let register_all () =
  Registry.register (module Queenside_majority);
  Registry.register (module Minority_attack)
