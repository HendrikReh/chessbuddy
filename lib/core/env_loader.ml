open! Base

let sanitize line =
  let trimmed = String.strip line in
  if String.is_empty trimmed then None
  else if Char.equal trimmed.[0] '#' then None
  else Some trimmed

let split_kv line =
  match String.lsplit2 line ~on:'=' with
  | Some (key, value) ->
      let key = String.strip key in
      let value = String.strip value in
      if String.is_empty key then None else Some (key, value)
  | None -> None

let read_env_file path =
  if Stdlib.Sys.file_exists path then
    let ic = Stdlib.open_in path in
    Exn.protect
      ~finally:(fun () -> Stdlib.close_in_noerr ic)
      ~f:(fun () ->
        let rec collect acc =
          match Stdlib.input_line ic with
          | line -> (
              match sanitize line with
              | None -> collect acc
              | Some useful ->
                  let acc =
                    match split_kv useful with
                    | None -> acc
                    | Some kv -> kv :: acc
                  in
                  collect acc)
          | exception End_of_file -> List.rev acc
        in
        collect [])
  else []

let lookup ?(path = ".env") key =
  match Stdlib.Sys.getenv_opt key with
  | Some value -> Some value
  | None ->
      read_env_file path
      |> List.find_map ~f:(fun (k, v) ->
             if String.equal k key then Some v else None)
