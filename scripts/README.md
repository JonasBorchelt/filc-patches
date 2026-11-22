# scripts

Helper scripts to fetch pinned upstream sources, apply patch series, and verify
reproducibility:

- `scripts/fetch [--sparse] [--reference <git-repo>] [TARGET_DIR]` — Checks out upstream LLVM at the exact revision pinned in `UPSTREAM`.
- `scripts/apply [--with-optional] [--no-cxx] [--sparse] [--reference <git-repo>] [TARGET_DIR]` — Fetches/resets upstream LLVM and applies `llvm/series` and `runtime/cxx/series` (plus `llvm/series.optional` when `--with-optional` is given).
- `scripts/verify-identical [--filc-dir <path>] [--work-dir <path>]` — Applies the full series against `UPSTREAM`'s `LLVM_COMMIT` and verifies bit-for-bit identity against `UPSTREAM`'s `FILC_COMMIT`, explicitly auditing the allowed exceptions (`SROA.cpp` verbose debug logging and `polly/` deletions).
