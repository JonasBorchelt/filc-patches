# llvm

Fil-C LLVM/Clang patch series against the pinned upstream LLVM commit in
`UPSTREAM` (currently `llvmorg-23.1.6`).

## Series (`llvm/series`)

Applied by default via `scripts/apply`:

1. `01-llvm-ir-datalayout-and-analysis.patch`: Dual `DataLayout` (`DLAfterFilC`), relaxed `Value::doRAUW` type assert, non-integral pointer guards in `IR/` & `Analysis/`.
2. `02-llvm-optimizer-guards.patch`: `InstCombine`, `SROA`, and `PassBuilderPipelines` safety guards (stripped of Fil-C's `verbose` debug logging in `SROA.cpp`).
3. `03-llvm-filc-passes.patch`: New passes: `KillUB`, `FilPizlonator`, `DeleteRedundantPollchecks`, and `RegisterFilPasses`.
4. `04-clang-frontend-ast-basic-sema.patch`: `RecordDecl::HasUnion` tracking, `TargetInfo` dual `DataLayout`, preprocessor defines, `cpuid.h`.
5. `05-clang-codegen-abi-and-pipeline.patch`: `BackendUtil` pass registration, X86/AArch64 ABI & `va_arg`, record layout, constants, atomics, builtins, Itanium C++ ABI.
6. `06a-clang-driver-filc-core.patch`: Fil-C Linux Clang driver (`pizfix`/`optfil`, SARCASM assembler, `-enable-filc-jit`, version scripts, static-PIE).
7. `06b-clang-driver-wl-version-script.patch`: Rewrites `-Wl,--version-script=` and `-Wl,--version-script,` through `PizlonateVersionScript()` in the Linux Clang driver.
8. `06c-clang-driver-sarcasm-safe-wa-flags.patch`: Accepts safe no-op assembler metadata flags (`-Wa,--noexecstack`, `-Wa,--generate-missing-build-notes={yes,no}`, `-Wa,-mrelax-relocations={yes,no}`, `-Wa,--compress-debug-sections[=...]`) in `SarcasmAs` while still rejecting unsafe flags.
9. `07-filc-hardened-compile-diagnostics.patch`: Rejects `__builtin_setjmp`/`__builtin_longjmp` cleanly in Clang Sema and replaces all user-input-reachable `llvm_unreachable`/`assert` sites in `FilPizlonator`, `CGRecordLayoutBuilder`, and `Gnu.cpp` with `report_fatal_error(..., /*GenCrashDiag=*/false)` so Release builds (`LLVM_ENABLE_ASSERTIONS=OFF`) never turn unsupported constructs into compiler UB.
10. `08-filc-pass-assertions-option.patch`: Adds CMake option `FILC_ENABLE_PASS_ASSERTIONS` that activates ODR-safe `FILC_ASSERT` checks for all 515 internal `assert(...)` invariants in `FilPizlonator.cpp` and `KillUB.cpp` without undefining `NDEBUG` across LLVM headers.

## Optional (`llvm/series.optional`)

- `optional/06b-clang-driver-cosmo-fat-ape.patch`: Cosmopolitan libc & Fat-APE driver support. Still at `llvmorg-20.1.8` (not required for Linux/Unikraft builds; scheduled to be ported last).

## Intentionally Dropped Changes (Audited Exceptions)

- `llvm/lib/Transforms/Scalar/SROA.cpp`: `static constexpr bool verbose = false;` and all `if (verbose)` debug-logging blocks stripped.
- `polly/lib/External/isl/imath/Makefile` and `polly/lib/External/isl/imath/tests/gmp-compat-test/Makefile`: accidental deletions from Fil-C's 20.1.8 rebase discarded.
