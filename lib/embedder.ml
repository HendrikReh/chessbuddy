open! Base

module type PROVIDER = Ingestion_pipeline.EMBEDDER

module Constant : PROVIDER = struct
  let version = "constant-0"
  let embed ~fen:_ = Lwt.return (Array.create ~len:768 0.)
end
