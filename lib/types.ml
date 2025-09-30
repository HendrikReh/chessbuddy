open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Rating = struct
  type t = {
    standard : int option;
    rapid : int option;
    blitz : int option;
  } [@@deriving show, yojson]
end

module Player = struct
  type t = {
    fide_id : string option;
    full_name : string;
    rating_history : (Ptime.t * Rating.t) list;
  } [@@deriving show, yojson]
end

module Game_header = struct
  type t = {
    event : string option;
    site : string option;
    game_date : Ptime.t option;
    round : string option;
    eco : string option;
    opening : string option;
    white_player : string;
    black_player : string;
    white_elo : int option;
    black_elo : int option;
    result : string;
    termination : string option;
  } [@@deriving show, yojson]
end

module Move_feature = struct
  type t = {
    ply_number : int;
    san : string;
    uci : string option;
    fen_before : string;
    fen_after : string;
    side_to_move : char;
    eval_cp : int option;
    is_capture : bool;
    is_check : bool;
    is_mate : bool;
    motifs : string list;
  } [@@deriving show, yojson]
end

module Game = struct
  type t = {
    header : Game_header.t;
    moves : Move_feature.t list;
    source_pgn : string;
  } [@@deriving show, yojson]
end

module Batch = struct
  type t = {
    label : string;
    checksum : string;
    ingested_at : Ptime.t;
  } [@@deriving show, yojson]
end
