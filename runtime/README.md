# runtime

Fil-C runtime libraries, provenance metadata, and patch series:

- [`filc/`](filc/PROVENANCE.md): Core Fil-C runtime (`libpas`, `filc/{include,src,main}`,
  `yolounwind`, `projects/zegarmistrz/include`) fetched sparsely from pinned
  `FILC_COMMIT` via `scripts/fetch-runtime`, plus `runtime/filc/series` for any
  LLVM-release compatibility patches.
- [`cxx/`](cxx/README.md): Fil-C adaptations for LLVM's `libc++` and `libc++abi`
  (`runtime/cxx/series`).
