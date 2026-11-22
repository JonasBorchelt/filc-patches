# libc/musl

Maintained Fil-C patch series for both musl variants against upstream
`musl` commit `f314e133929b6379eccc632bef32eaebb66a7335` (v1.2.4+, pinned in
`UPSTREAM`), with zero vendored musl source files.

- `yolomusl/`: un-pizlonated underlying libc (`libyoloc.so`, `libyoloc.a`,
  `ld-fil1-<arch>.so`, CRT objects) used beneath `libpizlo`.
- `usermusl/`: pizlonated userland libc (`libc.so`, `libc.a`, headers)
  compiled with Fil-C `clang -yolo-assembler` and routed through `zsys_*`.

## Usage

```sh
./scripts/apply-musl yolomusl .work/yolomusl
./scripts/apply-musl usermusl .work/usermusl
```

Both patches carry `Fil-C-Origin-Commits` headers referencing the exact
`pizlonator/fil-c` commits (`cede3de02b42`, branch `deluge`).
