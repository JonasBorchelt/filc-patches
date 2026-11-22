# ports

Declarative recipes and minimal upstreamable patches for building userland
software with the Fil-C toolchain, following the
[Ports policy](../README.md#ports-policy) and [Stage 6 Plan](PLAN.md).

## Usage

```sh
# Validate the dependency graph and list Wave 1 ports
./scripts/build-ports --wave 1 --dry-run

# Build and test a single port against a Stage 5 Fil-C toolchain
FILC_TOOLCHAIN_ROOT=.work/toolchain ./scripts/build-port zlib .work/ports

# Build and test all Wave 1 (Tiers 0-1) ports in topological order
FILC_TOOLCHAIN_ROOT=.work/toolchain ./scripts/build-ports --wave 1 .work/ports
```
