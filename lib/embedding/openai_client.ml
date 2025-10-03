open! Base
open Lwt.Infix
module Http = Cohttp_lwt_unix
module Json = Yojson.Safe
module Util = Yojson.Safe.Util

let default_endpoint = Uri.of_string "https://api.openai.com/v1/embeddings"
let openai_api_key = "OPENAI_API_KEY"

type t = { api_key : string; model : string; endpoint : Uri.t }

let model t = t.model

let fetch_api_key () =
  match Env_loader.lookup openai_api_key with
  | Some key -> Ok key
  | None -> Error (Printf.sprintf "%s is not set" openai_api_key)

let create ?api_key ?(model = "gpt-5") ?(endpoint = default_endpoint) () =
  match
    api_key
    |> Option.value_map ~default:(fetch_api_key ()) ~f:(fun key -> Ok key)
  with
  | Error _ as err -> err
  | Ok api_key -> Ok { api_key; model; endpoint }

let headers t =
  Cohttp.Header.of_list
    [
      ("Authorization", "Bearer " ^ t.api_key);
      ("Content-Type", "application/json");
    ]

let parse_embedding body =
  try
    let json = Json.from_string body in
    let error = Util.member "error" json in
    if not (Json.equal error `Null) then
      let message =
        match Util.member "message" error with
        | `String msg -> msg
        | _ -> Json.to_string error
      in
      Error message
    else
      let data = Util.member "data" json |> Util.to_list in
      match data with
      | first :: _ ->
          let vector = Util.member "embedding" first |> Util.to_list in
          let arr =
            vector
            |> List.map ~f:(fun value -> Util.to_float value)
            |> Array.of_list
          in
          Ok arr
      | [] -> Error "embedding response missing data"
  with
  | Util.Type_error (msg, _) -> Error msg
  | exn -> Error (Stdlib.Printexc.to_string exn)

let embed t text =
  let payload =
    `Assoc [ ("model", `String t.model); ("input", `String text) ]
    |> Json.to_string
  in
  let body = Cohttp_lwt.Body.of_string payload in
  Http.Client.post ~headers:(headers t) ~body t.endpoint
  >>= fun (resp, body_stream) ->
  Cohttp_lwt.Body.to_string body_stream >>= fun body_str ->
  let status = Cohttp.Response.status resp in
  if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
    Lwt.return (parse_embedding body_str)
  else
    let message =
      match parse_embedding body_str with
      | Ok _ -> body_str
      | Error _ -> body_str
    in
    let error_msg =
      Printf.sprintf "OpenAI embeddings request failed (%s): %s"
        (Cohttp.Code.string_of_status status)
        message
    in
    Lwt.return (Error error_msg)
