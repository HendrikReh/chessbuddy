(lang dune 3.10)
(name chessbuddy)
(using fmt 1.3)
(generate_opam_files true)

(package
 (name chessbuddy)
 (synopsis "Hybrid SQL + vector chess retrieval pipeline")
 (depends
  (ocaml (>= 5.1))
  dune
  lwt
  lwt_ppx
  logs
  logs.fmt
  pgn_parser
  ocamlchess
  caqti
  caqti-lwt
  caqti-driver-postgresql
  yojson
  ptime
  cmdliner
  digestif
  ppx_deriving
  ppx_yojson_conv
  uri
  ))
