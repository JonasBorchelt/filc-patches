# filc-patches

Maintained patch series bringing [Fil-C](https://github.com/pizlonator/fil-c)
(memory-safe C and C++ with garbage-collected capabilities, bounds checking, and
type safety) onto the **latest stable upstream LLVM release** — not a
monolithic fork.

Live CI status: **[https://filc.connected.link](https://filc.connected.link)**

## Philosophy

Instead of vendoring upstream LLVM or musl trees, `filc-patches` tracks only
clean, auditable patch series, fetch/build scripts, and pinned upstream
revisions (`UPSTREAM`). Every patch documents its exact `Fil-C-Origin-Commits`
and rebase notes so changes can be reviewed, rebased onto new LLVM releases,
and verified reproducibly.

## Repository Layout

- `UPSTREAM` — Pinned upstream LLVM release tag/commit, Fil-C runtime commit,
  and upstream musl commit.
- `llvm/` — Ordered core Fil-C compiler patch series (`llvm/series`) for LLVM
  IR/DataLayout, optimizer guards, Fil-C passes, Clang frontend/CodeGen, and
  Linux driver (`llvm/series.optional` holds optional Cosmopolitan/APE patches).
- `runtime/` —
  - `runtime/cxx/` — Fil-C adaptations for LLVM `libc++` and `libc++abi`.
  - `runtime/filc/` — Provenance manifest (`PROVENANCE.md`) and compatibility
    patch series for core Fil-C runtime sources (`libpas`, `filc/{include,src,main}`,
    `yolounwind`, `projects/zegarmistrz/include`) fetched sparsely from the
    pinned Fil-C commit.
- `libc/musl/` — Maintained `yolomusl` and `usermusl` patch series against
  pinned upstream musl (zero vendored musl source files).
- `scripts/` — Reproducible fetch, apply, build, verification, and CI helper
  scripts (see [`scripts/README.md`](scripts/README.md)).

## Quickstart

Requirements on Linux (`x86_64` or `aarch64`): `git`, `cmake`, `ninja`,
`clang`, `lld`, `python3`, `ruby`, `make`, `binutils`, `libc6-dev`,
`linux-libc-dev` (and optionally `ccache`).

```sh
# 1. Fetch pinned upstream LLVM (sparse) and apply the Fil-C LLVM + libc++ patches
./scripts/apply --sparse .work/llvm-project

# 2. Build the complete Fil-C Linux musl + libc++ toolchain
#    (clang, lld, compiler-rt, yolounwind, yolomusl, libpizlo/CRT, usermusl, libc++/libc++abi)
./scripts/build-toolchain .work/toolchain

# 3. Run the end-to-end runtime and memory-safety verification suite
./scripts/test-toolchain .work/toolchain .work/toolchain-report.txt
```

Individual fetch helpers (`scripts/fetch`, `scripts/fetch-runtime`,
`scripts/fetch-musl`, `scripts/apply-musl`) can also be invoked standalone.

## Continuous Verification

Automated CI verifies two workflows and publishes sanitized status reports to
[https://filc.connected.link](https://filc.connected.link):

- **Nightly LLVM Release Check**: resolves the latest stable upstream
  `llvmorg-X.Y.Z` tag, checks and applies the full patch series patch-by-patch
  (stopping immediately on apply failure when a newer release introduces
  conflicts), builds the complete Fil-C toolchain, and runs all end-to-end
  runtime tests.
- **Full Toolchain Verification**: builds `clang`/`lld`, `compiler-rt`,
  `yolounwind`, `yolomusl`, `libpizlo`, `usermusl`, and `libc++`/`libc++abi`,
  then executes and hashes four runtime tests:
  1. **Hello World (C)**: compiles, links, runs, exit code `0`.
  2. **Out-of-Bounds Trap**: deliberate OOB heap read caught by Fil-C safety
     panic.
  3. **Use-After-Free Trap**: deliberate UAF read caught by Fil-C safety panic.
  4. **C++ with `libc++`**: `std::vector`, `std::string`, `<iostream>`, and
     `throw`/`catch` exceptions, exit code `0`.

## Provenance & Licensing

This repository contains patches and build/test glue referencing upstream
projects under their respective open-source licenses:

- **Fil-C** (`pizlonator/fil-c`): BSD-2-Clause License (copyright Epic Games,
  Inc. and Filip Pizlo). Every adopted patch and runtime path documents its
  exact origin commits.
- **LLVM / Clang / LLD / compiler-rt / libc++ / libc++abi**: Apache License v2.0
  with LLVM Exceptions.
- **musl**: MIT License.
