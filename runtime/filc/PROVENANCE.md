# Fil-C Runtime Provenance

The core Fil-C runtime (`libpizlo` / `libpas`, `filc` C runtime & headers,
`yolounwind`, and `zegarmistrz.h`) is Fil-C original/heavily-customized code
without a separate upstream release tarball. Instead of vendoring blobs into
`filc-patches`, `scripts/fetch-runtime` performs a sparse partial checkout of
the exact subdirectories below from the pinned `FILC_REPO` / `FILC_COMMIT` in
`UPSTREAM`, then applies any patches listed in `runtime/filc/series`.

## Pinned Source

- Repository: `https://github.com/pizlonator/fil-c.git`
- Branch: `deluge`
- Pinned commit: `cede3de02b42b58a14acc9ce39c9894ab952a915`

## Sparse Checkout Paths & Fil-C-Origin-Commits

### `libpas` (745 commits up to `cede3de02b42`)
Allocator, concurrent FUGC garbage collector, capability/bounds runtime, and
`libpizlo.{so,a}` build system. Recent origin commits:
- `240f816f10daeb17778dae82e936414e69401f73` 2026-11-21 filc: allocation-site profiler should use pas_hash_ptr and unprefixed statics
- `ba65d3bb2693429d643a3e866af2d8f63e0627f2` 2026-11-21 filc: allocation-site profiler should use bmalloc, not libc malloc
- `8d74ec6ab1b1fcd1b177bfeb441cfe40c7a1bbd0` 2026-11-13 Fix bugs that made yosh not work on Mac
- `0c7723f3a5baaf1859cc96e6b2fc75e5cef80f9e` 2026-11-13 Fix ARM64 build
- `1c48972fcc247b1be074668089603cd13c735427` 2026-11-07 Fix the four review items in the LLVM JIT runtime and pizlonator

### `filc/include` (258 commits up to `cede3de02b42`)
Public and runtime headers installed into `pizfix/stdfil-include/` (`stdfil.h`,
`pizlonated_runtime.h`, `pizlonated_syscalls.h`, `pizlonated_eh_landing_pad.h`,
`pizlonated_math.h`, `unwind.h`, `filc_test_support.h`). Recent origin commits:
- `f090ef71eb5fb8a4b0ae4f83fd34b97d00401bd4` 2026-11-07 Sprint 3: llvmpipe-on-Fil-C-JIT relink of GL processes + live desktop verification
- `ffe0059e2470d4cdc8a01c72a874fc800c207cad` 2026-11-05 Add a bunch of checks to the Fil-C runtime to make sure that you can't use the LLVM JIT API in a way that asserts (or crashes) in LLVM.
- `f383feef5c55e62e12f54073014e7a6216cb31ee` 2026-11-01 Dramatically simplify the implementation of the LLVM JIT wrappers

### `filc/src` (66 commits up to `cede3de02b42`)
Pizlonated side of `libpizlo` (`runtime.c`, `snprintf.c`, `syscall.h`,
`unwind.c`, `gcc_personality.c`, `pizlonated_eh_landing_pad.c`). Recent origin commits:
- `587d1bb8db875b5995d5a99dca388952466e0f3d` 2026-11-20 filc: route SYS_pidfd_send_signal in zsys_syscall; util-linux: safe fsopen probe
- `a8c295674428f4a83f7fc06a9dd2fe85defab6de` 2026-10-15 Add support for statmount and listmount. Also make sure we expose open_tree, move_mount, fsopen, fsconfig, fsmount, fspick, mount_setattr, statmount, and listmount via syscall(2).
- `c48d6f6cee55c633521f963219856cf5d2b45347` 2026-09-26 cosmo: stop exposing Linux-only syscalls from yolocosmo/usercosmo and the Fil-C runtime
- `3eb0af4740f73b5352f8fc44c6d8fe67fef69870` 2026-08-15 Fix #299. This adds support for oversize and misaligned atomics.

### `filc/main` (14 commits up to `cede3de02b42`)
Program entry CRT shims (`main.c` -> `filc_crt.o`/`filc_mincrt.o`, `main_jit.c`
-> `filc_jit_crt.o`/`filc_jit_mincrt.o`). Recent origin commits:
- `bc99f1d90f20a319a5aff1952ee68900e78518a6` 2026-10-31 Initial implementation of LLVM JIT support. It's really rough.
- `39ee664dbf0b7db841ae05269201e757447290ee` 2026-03-27 Make it possible to build libpas with g++, but don't make that the default.
- `8677034123570922b9d839a2a331f5775014e9f2` 2024-07-22 Fully switch Fil-C over to Linux/X86_64 and use a Musl Sando architecture

### `yolounwind` (6 commits up to `cede3de02b42`)
Un-pizlonated unwinder archive (`libyolounwind.a`) running beneath `libpizlo`.
All origin commits:
- `5acb41d4baa707656c0dec7f4235a1d1dd581bbd` 2026-09-26 cosmo: gate aarch64 x18/x28 register reservations on the cosmo flavor
- `c09c93d5d3b75ca0184eb9a3c326c3747d3dcdfe` 2026-09-26 cosmo: fix aarch64 libc++ iostream - reserve x18/x28 in every pizlonated object
- `51f8f39557fe5d4ecfa8452ef1c66983cd737431` 2026-09-26 cosmo: aarch64 Fil-C cosmo port (yolocosmo/libpas/usercosmo cross builds + driver support, qemu-verified)
- `4287de907b914b47e90f4db327c2e581df2dfd64` 2025-12-23 Fix license headers
- `cadecbb11172a9c8fb4fcf5814357c4b9f25ba42` 2025-11-19 Fix yolounwind for glibc now that we're including libyolort.
- `73dc226a9e19c2aac9750082b815d7a66fddb7b4` 2025-11-18 Use a stub unwind library instead of gcc_eh.

### `projects/zegarmistrz/include` (5 commits up to `cede3de02b42`)
Header `zegarmistrz.h` installed into `pizfix/stdfil-include/` by
`libpas/Makefile-setup`. All origin commits:
- `4f51f21dd6fab1e3fd78e74b5f96ed1869d7c4d1` 2026-11-03 Wire up zegarmistrz through the Fil-C runtime and wire it up to the simple OpenSSL tests
- `fc9ed1961af5da823121aa707a1ec50f58244b56` 2026-10-24 Teach zegarmistrz about the constant-timeliness of instuctions
- `0a86dd2a52fdd8a850932bfa9a11bb4316aac0a3` 2026-10-02 Make it easier for a guest to interact with zegarmistrz.
- `346728ea48f7c526bb0166a11e573ab28d2dc4ff` 2026-09-27 Refactor the way registers work in zegarmistrz and add tests of tainting masked/compress/expand loads/stores and make them pass.
- `8e7fa8edc9602dfb52ebb108dbd4b6f255622d24` 2026-09-27 Add zegarmistrz: a X86_64 emulator that I'll be able to use for dynamic data flow analysis.

## Other Runtime Components

- `compiler-rt` (`crtbegin.o`, `crtend.o`, `libyolort.a`): built unpatched from
  the pinned LLVM release tree (`scripts/fetch --sparse`).
- `libc++` and `libc++abi`: built from the pinned LLVM release tree with
  `runtime/cxx/01-libcxx-libcxxabi-filc.patch` applied.
