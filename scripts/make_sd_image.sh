#!/usr/bin/env bash
# make_sd_image.sh — Build the NyanSoC SD card boot image.
#
# SD card raw layout (512-byte sectors, no partition table):
#   Sector     0        : reserved (zeroed)
#   Sectors    1 –  516 : fw_jump.bin  (OpenSBI, 258 KB = 516 sectors)
#   Sectors  517 –  524 : sbi_stub.bin (stub kernel, 8 sectors = 4 KB)
#   Sectors  525 –  532 : nyansoc.dtb  (device tree, 8 sectors = 4 KB)
#
# Usage:
#   ./scripts/make_sd_image.sh [output.img]
#   ./scripts/make_sd_image.sh /dev/sdX   # write directly to SD card (macOS: /dev/diskN)
#
# Prerequisites:
#   - OpenSBI built:   opensbi/build/platform/nyansoc/firmware/fw_jump.bin
#   - Stub built:      firmware/sbi_stub/sbi_stub.bin
#   - DTB compiled:    boards/tangnano20k/nyansoc.dtb
#
# The script builds any missing prerequisites automatically.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENSBI_DIR="/Users/v/workspace/opensbi"
OUTPUT="${1:-${REPO_ROOT}/nyansoc_sd.img}"

FW_JUMP="${OPENSBI_DIR}/build/platform/nyansoc/firmware/fw_jump.bin"
STUB="${REPO_ROOT}/firmware/sbi_stub/sbi_stub.bin"
DTB="${REPO_ROOT}/boards/tangnano20k/nyansoc.dtb"

# ── Build prerequisites if needed ────────────────────────────────────────────

if [ ! -f "${FW_JUMP}" ]; then
    echo "Building OpenSBI fw_jump..."
    make -C "${OPENSBI_DIR}" PLATFORM=nyansoc CROSS_COMPILE=riscv64-elf- \
         FW_TEXT_START=0x80000000
fi

if [ ! -f "${STUB}" ]; then
    echo "Building sbi_stub..."
    make -C "${REPO_ROOT}/firmware/sbi_stub"
fi

if [ ! -f "${DTB}" ]; then
    echo "Compiling device tree..."
    dtc -I dts -O dtb -o "${DTB}" \
        "${REPO_ROOT}/boards/tangnano20k/nyansoc.dts"
fi

# ── Sector layout ─────────────────────────────────────────────────────────────

SECTOR=512

OPENSBI_START=1
OPENSBI_SECTORS=516   # 258 KB

STUB_START=517
STUB_SECTORS=8        # 4 KB

DTB_START=525
DTB_SECTORS=8         # 4 KB

TOTAL_SECTORS=$((DTB_START + DTB_SECTORS))
TOTAL_BYTES=$((TOTAL_SECTORS * SECTOR))

# ── Validate sizes ────────────────────────────────────────────────────────────

FW_SIZE=$(wc -c < "${FW_JUMP}")
STUB_SIZE=$(wc -c < "${STUB}")
DTB_SIZE=$(wc -c < "${DTB}")

FW_MAX=$((OPENSBI_SECTORS * SECTOR))
STUB_MAX=$((STUB_SECTORS * SECTOR))
DTB_MAX=$((DTB_SECTORS * SECTOR))

echo "fw_jump.bin : ${FW_SIZE} bytes (max ${FW_MAX})"
echo "sbi_stub.bin: ${STUB_SIZE} bytes (max ${STUB_MAX})"
echo "nyansoc.dtb : ${DTB_SIZE} bytes (max ${DTB_MAX})"

if [ "${FW_SIZE}" -gt "${FW_MAX}" ]; then
    echo "ERROR: fw_jump.bin too large (${FW_SIZE} > ${FW_MAX})" >&2; exit 1
fi
if [ "${STUB_SIZE}" -gt "${STUB_MAX}" ]; then
    echo "ERROR: sbi_stub.bin too large" >&2; exit 1
fi
if [ "${DTB_SIZE}" -gt "${DTB_MAX}" ]; then
    echo "ERROR: nyansoc.dtb too large" >&2; exit 1
fi

# ── Create image ──────────────────────────────────────────────────────────────

echo "Creating image: ${OUTPUT} (${TOTAL_BYTES} bytes, ${TOTAL_SECTORS} sectors)"

# Zero the whole image first
dd if=/dev/zero of="${OUTPUT}" bs=${SECTOR} count=${TOTAL_SECTORS} 2>/dev/null

# Write each payload at its sector offset
dd if="${FW_JUMP}" of="${OUTPUT}" bs=${SECTOR} seek=${OPENSBI_START} conv=notrunc 2>/dev/null
dd if="${STUB}"    of="${OUTPUT}" bs=${SECTOR} seek=${STUB_START}    conv=notrunc 2>/dev/null
dd if="${DTB}"     of="${OUTPUT}" bs=${SECTOR} seek=${DTB_START}     conv=notrunc 2>/dev/null

echo ""
echo "SD image written to: ${OUTPUT}"
echo ""
echo "To write to an SD card on macOS:"
echo "  diskutil unmountDisk /dev/diskN"
echo "  sudo dd if=${OUTPUT} of=/dev/rdiskN bs=1m"
echo "  diskutil eject /dev/diskN"
echo ""
echo "To write to an SD card on Linux:"
echo "  sudo dd if=${OUTPUT} of=/dev/sdX bs=1M"
