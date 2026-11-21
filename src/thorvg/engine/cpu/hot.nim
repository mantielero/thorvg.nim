## `noRaiseHot`: pragma for leaf procs called from per-pixel loops (H-perf-3).
##
## With `--exceptions:goto` a caller polls the thread-local error flag after every call to
## a proc the compiler cannot prove non-raising, and an ORC type hook or an unsigned `div`
## is enough to spoil that proof. On `--threads:on` MinGW builds every poll costs a
## `__emutls_get_address` call (about half of the time of a rotated image). In `danger`
## builds all checks are off and these procs cannot raise, so the pragma just states the
## fact (`enforceNoRaises`). In every other build it expands to nothing, so debug and
## release keep their checks and precise error locations.

when defined(danger):
  import std/macros

  macro noRaiseHot*(def: untyped): untyped =
    ## Adds `enforceNoRaises` to the proc definition `def`.
    result = def
    let pragmas = result[4]
    if pragmas.kind == nnkEmpty:
      result[4] = newNimNode(nnkPragma).add(ident"enforceNoRaises")
    else:
      pragmas.add ident"enforceNoRaises"
else:
  template noRaiseHot*(def: untyped): untyped =
    ## No-op outside `danger` builds.
    def