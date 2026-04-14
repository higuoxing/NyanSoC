# NyanSoC: OpenSBI SD boot — handoff notes

Context: Tang Nano 20K, NyanRV (RV32IMA + S/U), bootloader in IMEM loads `fw_jump.bin`, stub, and DTB from SD, then jumps to OpenSBI at `0x80000000` with `a0=0`, `a1=DTB PA`.

---

## Memory map constraints (critical)

- **SDRAM** is **8 MiB** unique (e.g. `COLUMN_WIDTH=8`); higher addresses **alias** within that window.
- **Do not** place the DTB (or anything OpenSBI must use) at **`0x81000000`**: it can **alias to `0x80000000`** and **corrupt the OpenSBI image** while it runs or during FDT relocation.
- Use **`0x80100000`** for the DTB (and align OpenSBI build flags with that — see `FW_JUMP_FDT_ADDR` / passthrough behavior in `fw_jump.S`).

---

## Bootloader → OpenSBI jump

- OpenSBI is copied into SDRAM; on RISC-V you must **`fence rw, rw`** then **`fence.i`** before executing that code (instruction stream vs stores). The bootloader Makefile needs **`zifencei`** in `-march` if you emit `fence.i`.
- The jump uses **`a0=hartid`**, **`a1=DTB physical address`**; **`fw_jump`** expects **S-mode** as the next stage (`fw_next_mode` → `PRV_S`).

---

## Why serial went quiet after “Jumping to OpenSBI…”

Several independent issues can produce **no OpenSBI banner** and **no error text**:

### 1. Console registered too late (fixed in-tree)

OpenSBI originally registered the NyanSoC UART only in **`platform early_init`**, which runs **after** `sbi_heap_init`, `sbi_domain_init`, and `sbi_hsm_init`. Failures there call `sbi_hart_hang()` with **no UART**, so the line appears **stuck** right after the bootloader message.

**Fix:** Implement **`nascent_init`** on the NyanSoC platform to call `uart_nyansoc_init()` and **move `sbi_platform_nascent_init()` to the very start of `sbi_init()`** so the console exists before MISA checks, heap, and domain setup.

### 2. “Unsupported S-mode” warmboot deadlock (fixed in-tree)

For **fw_jump**, `scratch->next_mode` is **S-mode**. OpenSBI sets `next_mode_supported` only if **`misa_extension('S')`** is true. If that fails, **`coldboot` is never taken** and the hart enters **`init_warmboot` → `wait_for_coldboot()`** and **spins forever** — again often with **no console** if UART was not brought up first.

**Fix:** After `nascent_init`, if `next_mode_supported` is false, **`sbi_printf` + `sbi_hart_hang()`** instead of falling through to warmboot wait.

### 3. CSR `misa` reads as zero

If **`misa` reads as 0**, OpenSBI uses **`platform_ops.misa_check_extension` / `misa_get_xlen`**. NyanSoC now provides these to match **RTL intent** (RV32IMA + S + U).

### 4. Heap layout `EINVAL`

`sbi_heap_init()` validates `fw_heap_offset`, `fw_heap_size`, `fw_rw_offset`, etc. On failure it used to hang silently; **diagnostic `sbi_printf`** was added on failure (meaningful only after the console is early-initialized).

### 5. Stale SD image

The card must carry a **`fw_jump.bin` built with the same `FW_TEXT_START`, `FW_JUMP_*`, and DTB address assumptions** as the bootloader. An old binary can still relocate or boot incorrectly.

---

## Repo layout note (`sw/Makefile`)

`make opensbi` **copies `sw/opensbi-platform/` over `sw/opensbi/platform/nyansoc/`** before building. Maintain platform changes in **`sw/opensbi-platform/`** (or re-copy manually) so they are not lost on the next top-level build.

---

## Key files (non-exhaustive)

| Topic | Location |
|--------|-----------|
| Bootloader load/jump, `fence.i`, DTB address | `firmware/bootloader/bootloader.c`, `firmware/bootloader/Makefile` |
| OpenSBI platform (UART, PLIC, timer, nascent/MISA hooks) | `sw/opensbi-platform/platform.c` → synced to `sw/opensbi/platform/nyansoc/platform.c` |
| fw_jump addresses | `sw/opensbi/platform/nyansoc/objects.mk`, `sw/opensbi-platform/objects.mk` |
| Early `sbi_init` / heap diagnostics | `sw/opensbi/lib/sbi/sbi_init.c`, `sw/opensbi/lib/sbi/sbi_heap.c` |
| OpenSBI entry, lottery, FDT copy | `sw/opensbi/firmware/fw_base.S`, `sw/opensbi/firmware/fw_jump.S` |
| CPU: AMO, `misa`, traps | `rtl/nyanrv.v` |

---

## What to do when debugging next

1. Confirm **bitstream** includes the **current** bootloader IMEM if you changed `fence.i` / CSR cleanup.
2. Confirm SD has a **fresh** `fw_jump.bin` from **`make -C sw opensbi`** (or equivalent).
3. With the **nascent UART + sbi_init** fixes, expect either the **OpenSBI banner** or a **printed error** (MISA, heap layout, etc.).
4. If still **no bytes** after the jump, failure is likely **before `nascent_init`** (e.g. trap in `_start`, relocation, **`amoswap`** boot lottery, or bad load of `fw_jump.bin`). Next steps: trap/LED, ILA, or a **minimal MMIO write** in very early OpenSBI asm (debug only).

---
