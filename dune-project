(lang dune 3.10)
(version 0.0.1)
(name chessbuddy)
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
  fmt
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
  uuidm
  (alcotest :with-test)
  (alcotest-lwt :with-test)
  ))
