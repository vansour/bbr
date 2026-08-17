# BBR Script Robustness Design

**Date:** 2026-08-17

## Goal

Improve the reliability, error reporting, validation, and testability of the Debian/Ubuntu BBR management script without changing its intentional no-backup behavior or its broad network-sysctl deletion semantics.

## Invariants

- Menu 2 remains destructive and does not create backups.
- Menu 2 continues to discover active `net.*` entries in the existing sysctl search paths and `/etc/sysctl.conf`.
- BBR, TCP tuning, and concurrency tuning continue to use independent `99-*.conf` files and can be applied in any order.
- Supported operating systems, menu choices, and tuning parameter values remain unchanged unless required to prevent invalid arithmetic or an incorrect success report.

## Design

### Reliable configuration writes

All generated configuration files are written to a temporary file in the target directory, checked for successful completion, assigned the intended permissions, and atomically moved into place. A failed write must not report success or leave a partially written target file.

### Sysctl application and verification

The script will check command return codes and expose `sysctl --system` failures. Each operation will verify every key it writes, normalizing whitespace for vector values such as `tcp_rmem` and `ip_local_port_range`. A configuration file may remain on disk after an application failure, but the user-facing result will clearly distinguish persistence from runtime activation.

BBR keeps its existing fq fallback: if fq cannot be applied, the persistent BBR file is reduced to the congestion-control setting and BBR is verified independently.

### Deletion behavior

The existing deletion target set and confirmation flow remain. Deletion errors are collected and returned as failures. The preview will explain that unrelated network settings in matching files can also be removed, while preserving the no-backup policy.

### Input and prerequisite handling

The script will validate required external commands before using them, handle EOF during prompts, and reject numeric inputs that could overflow the BDP calculation. Existing accepted bandwidth and RTT formats remain valid.

### Testability

The interactive loop will move behind a `main` function guarded by a direct-execution check. A dependency-free shell test file will source the functions and cover parsers, arithmetic boundaries, atomic writes, command failure propagation, and complete sysctl verification through controlled test doubles.

### Documentation

README wording will be aligned with the actual buffer default clamps, the semantics of `tcp_fin_timeout`, the fact that `pfifo_fast` is the script-selected value rather than a universal original default, and the scope of unrelated network parameters affected by deletion.

## Acceptance criteria

- A failed configuration write or rename returns nonzero and never prints a successful write message.
- A failed deletion is reported and causes the delete operation to return nonzero.
- Each tuning operation verifies all values it writes; partial application cannot be reported as complete.
- BBR still falls back to BBR-only persistence when fq is unavailable.
- Existing valid parser inputs retain their current outputs; invalid and overflowing inputs are rejected.
- The menu still displays and exits with option `0`.
- `bash -n`, ShellCheck, and the new test suite pass.
- No backup file or restore mechanism is introduced.
