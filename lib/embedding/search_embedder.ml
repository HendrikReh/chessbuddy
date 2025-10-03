open! Base

module type PROVIDER = Search_indexer.TEXT_EMBEDDER

module Openai = struct
  let make ?api_key ?model () =
    match Openai_client.create ?api_key ?model () with
    | Error msg -> Error msg
    | Ok client ->
        let module Provider = struct
          let model = Openai_client.model client
          let embed ~text = Openai_client.embed client text
        end in
        Ok (module Provider : PROVIDER)
end
