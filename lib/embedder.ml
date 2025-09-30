module type PROVIDER = Ingestion_pipeline.EMBEDDER

module Constant : PROVIDER = struct
  let version = "constant-0"
  let embed ~fen:_ = Lwt.return (Array.make 768 0.)
end
