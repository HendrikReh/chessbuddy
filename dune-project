(lang dune 3.10)
(version 0.0.8)
(name chessbuddy)
(generate_opam_files true)

(package
 (name chessbuddy)
 (maintainers "Hendrik Reh <maintainers@chessbuddy.io>")
 (authors "Hendrik Reh")
 (homepage "https://github.com/HendrikReh/chessbuddy")
 (bug_reports "https://github.com/HendrikReh/chessbuddy/issues")
 (license "MIT")
 (synopsis "Hybrid SQL + vector chess retrieval pipeline")
 (depends
  (ocaml (>= 5.1))
  dune
  lwt
  lwt_ssl
  lwt_ppx
  logs
  fmt
  caqti
  caqti-lwt
  caqti-driver-postgresql
  yojson
  ptime
  base
  stdio
  cmdliner
  digestif
  ppx_deriving
  ppx_yojson_conv
  cohttp-lwt-unix
  tls
  uri
  uuidm
  uutf
  (alcotest :with-test)
  (alcotest-lwt :with-test)
  (ocamlformat (>= 0.27.0))
  ))