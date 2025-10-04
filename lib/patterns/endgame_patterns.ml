open! Base
open Pattern_detector
open Chess_engine

let piece_positions board ~piece ~color =
  let positions = ref [] in
  for file = 0 to 7 do
    for rank = 0 to 7 do
      match Board.get board ~file ~rank with
      | Piece { piece_type; color = c }
        when Poly.equal piece_type piece && Poly.equal c color ->
          positions := (file, rank) :: !positions
      | _ -> ()
    done
  done;
  !positions

let material_profile board color =
  let pawns = List.length (piece_positions board ~piece:Pawn ~color) in
  let rooks = List.length (piece_positions board ~piece:Rook ~color) in
  let bishops = List.length (piece_positions board ~piece:Bishop ~color) in
  let knights = List.length (piece_positions board ~piece:Knight ~color) in
  let queens = List.length (piece_positions board ~piece:Queen ~color) in
  (pawns, rooks, bishops + knights, queens)

let parse_board fen =
  match Chess_engine.Fen.parse fen with
  | Ok (board, _) -> Some board
  | Error _ -> None

let final_board moves =
  match List.last moves with
  | None -> parse_board Fen_generator.starting_position_fen
  | Some move -> parse_board move.Types.Move_feature.fen_after

let result_for color result =
  match (result, color) with
  | "1-0", White -> Victory
  | "0-1", Black -> Victory
  | "1/2-1/2", _ -> DrawNeutral
  | "1-0", Black -> Defeat
  | "0-1", White -> Defeat
  | _ -> DrawNeutral

module Lucena : PATTERN_DETECTOR = struct
  let pattern_id = "lucena_position"
  let pattern_name = "Lucena Position"
  let pattern_type = `Endgame

  let detect ~moves ~result:_ =
    match final_board moves with
    | None ->
        Lwt.return
          {
            detected = false;
            confidence = 0.0;
            initiating_color = None;
            start_ply = None;
            end_ply = None;
            metadata = [];
          }
    | Some board -> (
        let wpawns, wrooks, wminor, wqueen = material_profile board White in
        let bpawns, brooks, bminor, bqueen = material_profile board Black in
        let qualifies (pawns, rooks, minor, queen) =
          pawns = 1 && rooks = 1 && minor = 0 && queen = 0
        in
        let white_ok = qualifies (wpawns, wrooks, wminor, wqueen) in
        let black_ok = qualifies (bpawns, brooks, bminor, bqueen) in
        let detection_color =
          if white_ok && black_ok then Some White
          else if white_ok then Some White
          else if black_ok then Some Black
          else None
        in
        match detection_color with
        | None ->
            Lwt.return
              {
                detected = false;
                confidence = 0.0;
                initiating_color = None;
                start_ply = None;
                end_ply = None;
                metadata = [];
              }
        | Some color ->
            let pawn = piece_positions board ~piece:Pawn ~color in
            let metadata =
              match pawn with
              | [ (file, rank) ] ->
                  [ ("pawn_file", `Int file); ("pawn_rank", `Int rank) ]
              | _ -> []
            in
            Lwt.return
              {
                detected = true;
                confidence = 0.6;
                initiating_color = Some color;
                start_ply = None;
                end_ply = None;
                metadata;
              })

  let classify_success ~detection ~result =
    if not detection.detected then Lwt.return (false, DrawNeutral)
    else
      let color = Option.value detection.initiating_color ~default:White in
      let outcome = result_for color result in
      let success =
        match outcome with
        | Victory | DrawAdvantage -> true
        | DrawNeutral | Defeat -> false
      in
      Lwt.return (success, outcome)
end

module Philidor : PATTERN_DETECTOR = struct
  let pattern_id = "philidor_position"
  let pattern_name = "Philidor Position"
  let pattern_type = `Endgame

  let detect ~moves ~result:_ =
    match final_board moves with
    | None ->
        Lwt.return
          {
            detected = false;
            confidence = 0.0;
            initiating_color = None;
            start_ply = None;
            end_ply = None;
            metadata = [];
          }
    | Some board -> (
        let wpawns, wrooks, _, _ = material_profile board White in
        let bpawns, brooks, _, _ = material_profile board Black in
        let defending, attacking =
          if wrooks = 1 && wpawns = 0 && brooks = 1 && bpawns = 1 then
            (Some White, Some Black)
          else if brooks = 1 && bpawns = 0 && wrooks = 1 && wpawns = 1 then
            (Some Black, Some White)
          else (None, None)
        in
        match (defending, attacking) with
        | Some defender, Some attacker -> (
            let defender_rook =
              piece_positions board ~piece:Rook ~color:defender
            in
            let attacker_pawn =
              piece_positions board ~piece:Pawn ~color:attacker
            in
            match (defender_rook, attacker_pawn) with
            | _, [ (_file, rank) ]
              when (Poly.equal attacker White && rank = 5)
                   || (Poly.equal attacker Black && rank = 2) ->
                Lwt.return
                  {
                    detected = true;
                    confidence = 0.5;
                    initiating_color = Some defender;
                    start_ply = None;
                    end_ply = None;
                    metadata =
                      [
                        ( "defender",
                          `String
                            (if Poly.equal defender White then "white"
                             else "black") );
                      ];
                  }
            | _ ->
                Lwt.return
                  {
                    detected = false;
                    confidence = 0.0;
                    initiating_color = None;
                    start_ply = None;
                    end_ply = None;
                    metadata = [];
                  })
        | _ ->
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
      let defender = Option.value detection.initiating_color ~default:White in
      let outcome = result_for defender result in
      let success =
        match outcome with
        | DrawNeutral | DrawAdvantage -> true
        | Victory | Defeat -> false
      in
      Lwt.return (success, outcome)
end

let register_all () =
  Registry.register (module Lucena);
  Registry.register (module Philidor)
