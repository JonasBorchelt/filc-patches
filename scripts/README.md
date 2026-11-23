# scripts

Helper scripts to fetch pinned upstream sources, apply patch series, build the
Fil-C toolchain, and run verification suites:

- `scripts/fetch [--sparse] [--reference <git-repo>] [TARGET_DIR]`: Checks out upstream LLVM at the exact revision pinned in `UPSTREAM`.
- `scripts/apply [--with-optional] [--no-cxx] [--sparse] [--reference <git-repo>] [TARGET_DIR]`: Fetches/resets upstream LLVM and applies `llvm/series` and `runtime/cxx/series` (plus `llvm/series.optional` when `--with-optional` is given).
- `scripts/fetch-musl [--reference <git-repo>] [TARGET_DIR]`: Checks out upstream musl at the exact `MUSL_COMMIT` pinned in `UPSTREAM`.
- `scripts/apply-musl <yolomusl|usermusl> [--reference <git-repo>] [TARGET_DIR]`: Fetches upstream musl and applies `libc/musl/<variant>/series`.
- `scripts/fetch-runtime [--reference <git-repo>] [TARGET_DIR]`: Sparse-fetches Fil-C runtime sources (`libpas`, `filc/{include,src,main}`, `yolounwind`, `projects/zegarmistrz/include`) at `FILC_COMMIT` and applies `runtime/filc/series`.
- `scripts/build-and-smoke [LLVM_SRC_DIR] [BUILD_DIR]`: Builds Fil-C Clang + LLD and runs freestanding X86_64/AArch64 compiler pipeline smoke tests.
- `scripts/build-toolchain [WORK_ROOT]`: Builds the complete Fil-C Linux musl toolchain (`clang`, `lld`, `compiler-rt`, `yolounwind`, `yolomusl`, `libpizlo`, `usermusl`, `libc++`/`libc++abi`).
- `scripts/test-toolchain [WORK_ROOT] [REPORT_FILE]`: Runs end-to-end runtime tests (Hello World, Out-of-Bounds & Use-After-Free safety traps, C++ with `libc++`) and emits a SHA-256 evidence report.
- `scripts/package-release <WORK_ROOT> <OUT_DIR> [VERSION]`: Packages a built toolchain into a reproducible, relocatable, leak-gated `filc-<version>-<arch>-linux.tar.xz` archive with `LICENSES/`, `NOTICE`, `MANIFEST`, `PROVENANCE`, `SHA256SUMS`, and `setup.sh`.
- `scripts/test-package-release`: Fast offline unit test for `scripts/package-release` against a mock toolchain tree (symlink idempotency, `SHA256SUMS`, `MANIFEST`, wrappers, and Leak-Gate rejection).
- `scripts/test-release-archive <ARCHIVE.tar.xz> [REPO_ROOT]`: Unpacks a release archive into a fresh temporary directory and verifies `MANIFEST`, C/C++ Hello World, OOB/UAF traps, and building `ports/zlib`.
- `scripts/nightly-check [LLVM_SRC_DIR] [BUILD_DIR] [REPORT_FILE]`: Automated latest-LLVM-release patch and smoke-test check used by nightly CI.
- `scripts/verify-identical [--filc-dir <path>] [--work-dir <path>]`: Applies the full LLVM series against `UPSTREAM`'s `LLVM_COMMIT` and verifies bit-for-bit identity against `UPSTREAM`'s `FILC_COMMIT`.
- `scripts/verify-pins [--check-metadata-only] [--all|--verifiable-direct|--changed [ref]|<port>...]`: Verifies `ports/*/PORT` `UPSTREAM_SHA256` pins against official upstream checksum files, GitHub release digests, or detached PGP signatures using pinned keys in `ports/pgp-keys/`.
- `scripts/verify-patches [--all|--ports a,b [--with-deps]|<port>...]`: Verifies that every patch in `ports/*/patches/series` applies cleanly to its pinned, SHA-256-verified upstream tarball with zero fuzz and zero line offset.
- `scripts/build-port <port-name> [WORK_ROOT]`: Builds, installs, and tests a single port recipe under the staged Fil-C toolchain.
- `scripts/build-ports [--dry-run] [--wave N|--tiers ...|--ports ...] [WORK_ROOT]`: Validates the `ports/` dependency DAG and builds ports in topological order.
- `scripts/test-ports`: Runs offline unit tests for the port runner, DAG validation, patch headers, and pin metadata.
