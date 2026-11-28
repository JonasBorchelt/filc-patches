# filc-patches

Maintained patch series bringing [Fil-C](https://github.com/pizlonator/fil-c)
(memory-safe C and C++ with garbage-collected capabilities, bounds checking, and
type safety) onto the **latest stable upstream LLVM release**, rather than a
monolithic fork.

Live CI status: **[https://filc.connected.link](https://filc.connected.link)**

## Philosophy

Instead of vendoring upstream LLVM or musl trees, `filc-patches` tracks only
clean, auditable patch series, fetch/build scripts, and pinned upstream
revisions (`UPSTREAM`). Every patch documents its exact `Fil-C-Origin-Commits`
and rebase notes so changes can be reviewed, rebased onto new LLVM releases,
and verified reproducibly.

## Repository Layout

- `UPSTREAM`: Pinned upstream LLVM release tag/commit, Fil-C runtime commit,
  and upstream musl commit.
- `llvm/`: Ordered core Fil-C compiler patch series (`llvm/series`) for LLVM
  IR/DataLayout, optimizer guards, Fil-C passes, Clang frontend/CodeGen, and
  Linux driver (`llvm/series.optional` holds optional Cosmopolitan/APE patches).
- `runtime/`:
  - `runtime/cxx/`: Fil-C adaptations for LLVM `libc++` and `libc++abi`.
  - `runtime/filc/`: Provenance manifest (`PROVENANCE.md`) and compatibility
    patch series for core Fil-C runtime sources (`libpas`, `filc/{include,src,main}`,
    `yolounwind`, `projects/zegarmistrz/include`) fetched sparsely from the
    pinned Fil-C commit.
- `libc/musl/`: Maintained `yolomusl` and `usermusl` patch series against
  pinned upstream musl (zero vendored musl source files).
- `scripts/`: Reproducible fetch, apply, build, verification, and CI helper
  scripts (see [`scripts/README.md`](scripts/README.md)).

## Quickstart

Requirements on Linux (`x86_64` or `aarch64`): `git`, `cmake`, `ninja`,
`clang`, `lld`, `python3`, `ruby`, `make`, `binutils`, `libc6-dev`,
`linux-libc-dev` (and optionally `ccache`).

```sh
# 1. Fetch pinned upstream LLVM (sparse) and apply the Fil-C LLVM + libc++ patches
./scripts/apply --sparse .work/llvm-project

# 2. Build the complete Fil-C Linux musl + libc++ toolchain
#    (clang, lld, llvm-ar, llvm-ranlib, llvm-nm, compiler-rt, yolounwind, yolomusl, libpizlo/CRT, usermusl, libc++/libc++abi)
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

## Ports policy

Building and packaging software with Fil-C follows a toolchain-first policy designed to keep upstream packages unmodified whenever possible:

1. **Fix toolchain gaps at the source:** Missing compiler, runtime, or libc support is fixed in the Fil-C toolchain rather than worked around per package. One fix benefits every package and keeps upstream sources untouched.
2. **Small, upstreamable package patches only when necessary:** Genuinely unsafe or non-portable patterns in a package (such as pointer-to-integer casts, custom allocators, inline assembly, JIT engines, or address-based hashing) receive a minimal, documented, upstreamable patch with an explicit rationale.
3. **Prefer build options over source patches:** Build-system and configuration issues are resolved through build flags and configuration options instead of patching package sources.
4. **Audit imported port patches:** Adopted Fil-C port patches serve only as a starting point with full provenance attribution and are reviewed to verify whether they mask an underlying toolchain gap.
5. **Measure and reduce patch debt:** Unmodified versus patched package counts and patch sizes are tracked, with the explicit goal of driving the number and size of package patches down over time.

## Known Limitations

- **Pointer serialization/synthesis (by design, memory safety):** Operations that forge, byte-swap, UTF-8-re-encode, or perform raw integer arithmetic on serialized pointers (for example Perl `pack`/`unpack` `p`/`P` with byte-swapping `p>` or `utf8::upgrade`) strip Fil-C capabilities by design and trap deterministically under InvisiCaps.
- **PostgreSQL (`postgresql-client`):** Client tools (`psql`, `pg_dump`, `pg_restore`, `pg_isready`, `pg_config`) and `libpq` only; the PostgreSQL server is not supported under Fil-C (`Datum` carries pointers as integers and multi-process shared-memory tables cannot share process-private capability metadata).

## Provenance & Licensing

Original scripts, documentation, and repository metadata in `filc-patches`
are licensed under the **Apache License v2.0 with LLVM Exceptions**
(`Apache-2.0 WITH LLVM-exception`); see [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE) for the full per-directory license and attribution
breakdown.

This repository also contains patch series and provenance metadata referencing
upstream projects pinned in `UPSTREAM`. Each upstream component remains under
its own license, verified against the pinned source files:

- **Fil-C compiler & C++ libraries** (`pizlonator/fil-c` @ `cede3de02b42`,
  patches in `llvm/` and `runtime/cxx/`): **Apache License v2.0 with LLVM
  Exceptions** (`Apache-2.0 WITH LLVM-exception`), see Fil-C `README.md`
  (`## License`), `llvm/LICENSE.TXT`, `clang/LICENSE.TXT`, `libcxx/LICENSE.TXT`,
  `libcxxabi/LICENSE.TXT`, and SPDX headers in the Fil-C compiler files (e.g.,
  `llvm/lib/Transforms/Instrumentation/FilPizlonator.cpp`).
- **Fil-C runtime** (`pizlonator/fil-c` @ `e7b7f1e8969e`, fetched sparsely into
  `libpas/`, `filc/{include,src,main}`, `yolounwind/`, and
  `projects/zegarmistrz/include`): **BSD-2-Clause** (`Copyright (c) 2018-2022
  Apple Inc.`, `Copyright (c) 2023-2026 Epic Games, Inc.`, `Copyright (c) 2026
  Filip Pizlo`), see `libpas/LICENSE.txt` and per-file headers
  (`filc/include/stdfil.h`, `filc/main/main.c`, `yolounwind/yolounwind.c`,
  `projects/zegarmistrz/include/zegarmistrz.h`). Specific files within these
  runtime paths carry additional/distinct upstream notices: `setproctitle` from
  OpenSSH 10.3p1 (**BSD-3-Clause**, documented in `libpas/LICENSE.txt`),
  `filc/include/unwind.h` (**Apache-2.0 WITH LLVM-exception**, derived from
  LLVM `libunwind`), and `filc/src/snprintf.c` (permissive notice,
  `Copyright Patrick Powell 1995`).
- **LLVM / Clang / LLD / `compiler-rt` / `libc++` / `libc++abi`**
  (`llvm/llvm-project` @ `llvmorg-23.1.6` / `5b10d2d74929`): **Apache License
  v2.0 with LLVM Exceptions** (`Apache-2.0 WITH LLVM-exception`), see
  `LICENSE.TXT`, `llvm/LICENSE.TXT`, `clang/LICENSE.TXT`, `lld/LICENSE.TXT`,
  `compiler-rt/LICENSE.TXT`, `libcxx/LICENSE.TXT`, and `libcxxabi/LICENSE.TXT`.
- **musl** (`f314e133929b`) and **Fil-C `yolomusl` / `usermusl`**
  (`libc/musl/`): **MIT License** (`Copyright © 2005-2020 Rich Felker, et al.`,
  with compatible permissive third-party portions listed in `COPYRIGHT`), see
  upstream musl `COPYRIGHT` and Fil-C `projects/yolomusl/COPYRIGHT` /
  `projects/usermusl/COPYRIGHT`. The `libc/musl/usermusl/01-usermusl-filc.patch`
  series additionally carries BSD-licensed components with preserved file
  headers (Regents of the University of California, `Copyright (c) 1991, 1993`;
  Colin Percival and Alexander Peslyak, BSD-2-Clause).

- **Legacy Freexian Extended LTS ports** (`ports/openssl1.1`,
  `ports/curl-openssl1.1`, `ports/php5.6`, `ports/php7.0`, `ports/php7.3`,
  `ports/php7.4`): Pinned via signed Freexian ELTS `InRelease` -> `Sources.gz`
  metadata. Because Debian's `php5` `+dfsg` source tarball excludes the original
  `ext/json`, `ports/php5.6` additionally pins Freexian ELTS `jessie`
  `php-json` (`pecl-jsonc` 1.3.6-1) and builds it statically as built-in
  `ext/json` (**PHP-3.01** for the `jsonc` extension and **MIT / Expat** for the
  bundled `json-c` library; `LICENSE="PHP-3.01 AND MIT"`).

Every adopted patch and runtime path documents its exact upstream origin
commits (`Fil-C-Origin-Commits` and `runtime/filc/PROVENANCE.md`).
