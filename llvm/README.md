# llvm

Fil-C LLVM/Clang patch series against the pinned upstream LLVM commit in
`UPSTREAM` (currently `llvmorg-21.1.8`).

## Series (`llvm/series`)

Applied by default via `scripts/apply`:

1. `01-llvm-ir-datalayout-and-analysis.patch` — Dual `DataLayout` (`DLAfterFilC`), relaxed `Value::doRAUW` type assert, non-integral pointer guards in `IR/` & `Analysis/`.
2. `02-llvm-optimizer-guards.patch` — `InstCombine`, `SROA`, and `PassBuilderPipelines` safety guards (stripped of Fil-C's `verbose` debug logging in `SROA.cpp`).
3. `03-llvm-filc-passes.patch` — New passes: `KillUB`, `FilPizlonator`, `DeleteRedundantPollchecks`, and `RegisterFilPasses`.
4. `04-clang-frontend-ast-basic-sema.patch` — `RecordDecl::HasUnion` tracking, `TargetInfo` dual `DataLayout`, preprocessor defines, `cpuid.h`.
5. `05-clang-codegen-abi-and-pipeline.patch` — `BackendUtil` pass registration, X86/AArch64 ABI & `va_arg`, record layout, constants, atomics, builtins, Itanium C++ ABI.
6. `06a-clang-driver-filc-core.patch` — Fil-C Linux Clang driver (`pizfix`/`optfil`, SARCASM assembler, `-enable-filc-jit`, version scripts, static-PIE).

## Optional (`llvm/series.optional`)

- `optional/06b-clang-driver-cosmo-fat-ape.patch` — Cosmopolitan libc & Fat-APE driver support. Still at `llvmorg-20.1.8` (not required for Linux/Unikraft builds; scheduled to be ported last).

## Intentionally Dropped Changes (Audited Exceptions)

- `llvm/lib/Transforms/Scalar/SROA.cpp`: `static constexpr bool verbose = false;` and all `if (verbose)` debug-logging blocks stripped.
- `polly/lib/External/isl/imath/Makefile` and `polly/lib/External/isl/imath/tests/gmp-compat-test/Makefile`: accidental deletions from Fil-C's 20.1.8 rebase discarded.
