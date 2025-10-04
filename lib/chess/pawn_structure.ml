open! Base
open Chess_engine

module Tuple2 = struct
  let equal eq_a eq_b (a1, b1) (a2, b2) = eq_a a1 a2 && eq_b b1 b2
end

type zone = [ `Queenside | `Center | `Kingside ]

type transition = {
  from_file : int;
  from_rank : int;
  to_file : int;
  to_rank : int;
  is_capture : bool;
  double_step : bool;
}

let files_of_zone = function
  | `Queenside -> [ 0; 1; 2 ]
  | `Center -> [ 3; 4 ]
  | `Kingside -> [ 5; 6; 7 ]

let pawn_positions board ~color =
  let positions = ref [] in
  for file = 0 to 7 do
    for rank = 0 to 7 do
      match Board.get board ~file ~rank with
      | Piece { piece_type = Pawn; color = c } when Poly.equal c color ->
          positions := (file, rank) :: !positions
      | _ -> ()
    done
  done;
  !positions

let count_zone board ~color zone =
  let files = files_of_zone zone in
  pawn_positions board ~color
  |> List.count ~f:(fun (file, _) -> List.mem files file ~equal:Int.equal)

let opponent = function White -> Black | Black -> White

let has_zone_majority board ~zone ~color =
  let ours = count_zone board ~color zone in
  let theirs = count_zone board ~color:(opponent color) zone in
  ours > theirs

let find_transition ~before_positions ~after_positions ~color ~dest =
  let square_equal = Tuple2.equal Int.equal Int.equal in
  let direction = match color with White -> 1 | Black -> -1 in
  let dest_file, dest_rank = dest in
  let candidates =
    List.filter before_positions ~f:(fun (file, rank) ->
        let file_delta = abs (file - dest_file) in
        let rank_delta = dest_rank - rank in
        (file_delta <= 1 && rank_delta = direction)
        || (file_delta = 0 && rank_delta = 2 * direction))
  in
  List.find_map candidates ~f:(fun (from_file, from_rank) ->
      let moved_from = (from_file, from_rank) in
      if List.mem after_positions moved_from ~equal:square_equal then None
      else Some (from_file, from_rank))

let is_capture ~before ~color ~from_file ~from_rank:_ ~to_file ~to_rank =
  match Board.get before ~file:to_file ~rank:to_rank with
  | Piece { color = occupant_color; _ }
    when not (Poly.equal occupant_color color) ->
      true
  | _ -> from_file <> to_file

let is_double_step ~color ~from_rank ~to_rank =
  match color with
  | White -> to_rank - from_rank = 2
  | Black -> from_rank - to_rank = 2

let detect_transition ~before ~after ~color ~zone =
  let files = files_of_zone zone in
  let before_positions = pawn_positions before ~color in
  let after_positions = pawn_positions after ~color in
  let potential_destinations =
    List.filter after_positions ~f:(fun (file, rank) ->
        List.mem files file ~equal:Int.equal
        && not
             (List.exists before_positions ~f:(fun (bf, br) ->
                  bf = file && br = rank)))
  in
  List.find_map potential_destinations ~f:(fun dest ->
      match find_transition ~before_positions ~after_positions ~color ~dest with
      | None -> None
      | Some (from_file, from_rank) ->
          let to_file, to_rank = dest in
          let capture =
            is_capture ~before ~color ~from_file ~from_rank ~to_file ~to_rank
          in
          Some
            {
              from_file;
              from_rank;
              to_file;
              to_rank;
              is_capture = capture;
              double_step = is_double_step ~color ~from_rank ~to_rank;
            })

let advancing_pawn ~before ~after ~color ~zone =
  match detect_transition ~before ~after ~color ~zone with
  | None -> None
  | Some move when not move.is_capture -> Some (move.to_file, move.to_rank)
  | Some _ -> None

let opponent_pawn_removed ~before ~after ~color ~zone =
  let files = files_of_zone zone in
  let opponent_color = opponent color in
  let before_positions = pawn_positions before ~color:opponent_color in
  let after_positions = pawn_positions after ~color:opponent_color in
  List.exists before_positions ~f:(fun (file, rank) ->
      List.mem files file ~equal:Int.equal
      && not
           (List.exists after_positions ~f:(fun (af, ar) ->
                af = file && ar = rank)))

let passed_pawn_created ~before ~after ~color ~zone =
  match detect_transition ~before ~after ~color ~zone with
  | None -> false
  | Some { to_file; to_rank; _ } ->
      let opponent_color = opponent color in
      let opponent_positions = pawn_positions after ~color:opponent_color in
      let relevant_files =
        List.filter
          [ to_file - 1; to_file; to_file + 1 ]
          ~f:(fun f -> f >= 0 && f <= 7)
      in
      let ahead =
        match color with
        | White -> fun rank -> rank > to_rank
        | Black -> fun rank -> rank < to_rank
      in
      not
        (List.exists opponent_positions ~f:(fun (file, rank) ->
             List.mem relevant_files file ~equal:Int.equal && ahead rank))

let island_count board ~color =
  let positions = pawn_positions board ~color in
  let has_pawn file =
    List.exists positions ~f:(fun (f, _) -> Int.equal f file)
  in
  let rec loop file prev acc =
    if file > 7 then acc
    else
      let current = has_pawn file in
      let acc = if current && not prev then acc + 1 else acc in
      loop (file + 1) current acc
  in
  loop 0 false 0

let max_rank_in_zone board ~color ~zone =
  let positions = pawn_positions board ~color in
  let files = files_of_zone zone in
  let relevant =
    List.filter positions ~f:(fun (file, _) ->
        List.mem files file ~equal:Int.equal)
  in
  match relevant with
  | [] -> None
  | _ ->
      let cmp =
        match color with
        | White -> fun (_, r1) (_, r2) -> Int.compare r1 r2
        | Black -> fun (_, r1) (_, r2) -> Int.compare r2 r1
      in
      let _, rank = List.max_elt relevant ~compare:cmp |> Option.value_exn in
      Some rank
