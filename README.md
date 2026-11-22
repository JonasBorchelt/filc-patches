# filc-patches

Fil-C (memory-safe C/C++) maintained as a patch series on top of current
LLVM main: compiler, runtime, libc and userland ports, rebased, built and
tested continuously.

This repository contains only patches, series files, scripts and CI
configuration. LLVM and Fil-C sources are fetched by the scripts.

Layout (planned):

- `llvm/`    series and patches against LLVM main
- `runtime/` Fil-C runtime
- `libc/`    C library
- `ports/`   userland ports
- `scripts/` fetch, apply, build, test
- `ci/`      CI pipeline
- `UPSTREAM` pinned LLVM and Fil-C revisions
