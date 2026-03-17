#!/usr/bin/env python3
"""uart_load.py — NyanSoC UART program loader host script.

Usage:
  # Upload a binary and run it:
  python3 scripts/uart_load.py -p /dev/ttyUSB0 load firmware/hello_world/hello_world.bin 0x00010000
  python3 scripts/uart_load.py -p /dev/ttyUSB0 go   0x00010000

  # Upload to SDRAM and run:
  python3 scripts/uart_load.py -p /dev/ttyUSB0 load fw.bin 0x80000000
  python3 scripts/uart_load.py -p /dev/ttyUSB0 go   0x80000000

  # Load and immediately jump (shorthand):
  python3 scripts/uart_load.py -p /dev/ttyUSB0 run fw.bin 0x80000000

  # Ping the board:
  python3 scripts/uart_load.py -p /dev/ttyUSB0 ping

  # Dump memory:
  python3 scripts/uart_load.py -p /dev/ttyUSB0 dump 0x00010000 256

Protocol (all multi-byte values big-endian):
  Load:  'L' <addr:4> <len:4> <data:len> <xor_csum:1>  → 'K' or 'E'
  Go:    'G' <addr:4>                                   → (jumps, no reply)
  Dump:  'D' <addr:4> <len:4>                           → <data:len>
  Ping:  'P'                                             → 'O'
"""

import argparse
import struct
import sys
import time
import serial


def open_port(port, baud):
    return serial.Serial(port, baud, timeout=2)


def drain(ser):
    """Read and print any pending output from the board."""
    time.sleep(0.1)
    while ser.in_waiting:
        data = ser.read(ser.in_waiting)
        sys.stdout.write(data.decode("ascii", errors="replace"))
        sys.stdout.flush()
        time.sleep(0.05)


def cmd_ping(ser):
    drain(ser)
    ser.write(b'P')
    resp = ser.read(1)
    if resp == b'O':
        print("Ping OK")
        return True
    print(f"Ping FAILED (got {resp!r})")
    return False


def cmd_load(ser, data: bytes, addr: int):
    drain(ser)
    csum = 0
    for b in data:
        csum ^= b

    print(f"Loading {len(data)} bytes to 0x{addr:08X} (csum=0x{csum:02X})...")

    # Send the header first, wait for the board to print its "Load ... bytes"
    # status line, then send the payload.  This avoids a race where the board
    # is still printing the banner when we start blasting bytes.
    header = b'L' + struct.pack('>II', addr, len(data))
    ser.write(header)
    time.sleep(0.05)   # let the board print its status line
    drain(ser)         # consume "Load 0x... bytes -> 0x...\r\n"

    # Send data + checksum
    ser.write(data + bytes([csum]))

    # Read until we get 'K' or 'E'
    resp = b''
    deadline = time.time() + 10
    while time.time() < deadline:
        c = ser.read(1)
        if not c:
            continue
        resp += c
        if b'K' in resp:
            time.sleep(0.05)
            ser.read(ser.in_waiting)  # consume " OK\r\n"
            print("  OK")
            return True
        if b'E' in resp:
            time.sleep(0.05)
            rest = ser.read(ser.in_waiting)
            line = (resp + rest).decode("ascii", errors="replace").strip()
            print(f"  ERROR: {line}")
            return False

    print(f"  TIMEOUT waiting for response (got {len(resp)} bytes: {resp!r})")
    return False


def cmd_go(ser, addr: int, stay: bool = False):
    drain(ser)
    print(f"Jumping to 0x{addr:08X}...")
    ser.write(b'G' + struct.pack('>I', addr))
    if not stay:
        time.sleep(0.2)
        output = ser.read(ser.in_waiting)
        if output:
            sys.stdout.write(output.decode("ascii", errors="replace"))
            sys.stdout.flush()
        return

    # Stay connected: stream output until Ctrl+C
    print("--- program output (Ctrl+C to exit) ---")
    ser.timeout = 0.1
    try:
        while True:
            data = ser.read(256)
            if data:
                sys.stdout.write(data.decode("ascii", errors="replace"))
                sys.stdout.flush()
    except KeyboardInterrupt:
        print("\n--- disconnected ---")


def cmd_dump(ser, addr: int, length: int):
    drain(ser)
    print(f"Dumping {length} bytes from 0x{addr:08X}...")
    ser.write(b'D' + struct.pack('>II', addr, length))
    data = b''
    deadline = time.time() + 5 + length / 115200 * 10
    while len(data) < length and time.time() < deadline:
        chunk = ser.read(length - len(data))
        data += chunk
    if len(data) < length:
        print(f"  WARNING: only got {len(data)}/{length} bytes")

    # Hex dump
    for i in range(0, len(data), 16):
        row = data[i:i+16]
        hex_part = ' '.join(f'{b:02X}' for b in row)
        asc_part = ''.join(chr(b) if 32 <= b < 127 else '.' for b in row)
        print(f"  {addr+i:08X}  {hex_part:<47}  {asc_part}")


def parse_addr(s):
    return int(s, 16) if s.startswith('0x') or s.startswith('0X') else int(s, 0)


def main():
    parser = argparse.ArgumentParser(description="NyanSoC UART loader")
    parser.add_argument('-p', '--port',  default='/dev/ttyUSB0', help='Serial port')
    parser.add_argument('-b', '--baud',  type=int, default=115200)

    sub = parser.add_subparsers(dest='cmd', required=True)

    sub.add_parser('ping')

    p_load = sub.add_parser('load', help='Upload binary to memory')
    p_load.add_argument('file',    help='Binary file to upload')
    p_load.add_argument('addr',    help='Load address (hex, e.g. 0x80000000)')

    p_go = sub.add_parser('go', help='Jump to address')
    p_go.add_argument('addr', help='Jump address (hex)')
    p_go.add_argument('--stay', action='store_true',
                      help='Keep terminal open after jump (Ctrl+C to exit)')

    p_run = sub.add_parser('run', help='Upload binary and jump to it')
    p_run.add_argument('file', help='Binary file to upload')
    p_run.add_argument('addr', help='Load/jump address (hex)')
    p_run.add_argument('--no-stay', action='store_true',
                       help='Disconnect immediately after jump')

    p_dump = sub.add_parser('dump', help='Dump memory as hex')
    p_dump.add_argument('addr',   help='Start address (hex)')
    p_dump.add_argument('length', help='Number of bytes (decimal or hex)', type=lambda s: int(s,0))

    args = parser.parse_args()

    try:
        ser = open_port(args.port, args.baud)
    except serial.SerialException as e:
        print(f"Cannot open {args.port}: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Connected to {args.port} at {args.baud} baud")
    drain(ser)

    if args.cmd == 'ping':
        sys.exit(0 if cmd_ping(ser) else 1)

    elif args.cmd == 'load':
        addr = parse_addr(args.addr)
        data = open(args.file, 'rb').read()
        sys.exit(0 if cmd_load(ser, data, addr) else 1)

    elif args.cmd == 'go':
        addr = parse_addr(args.addr)
        cmd_go(ser, addr, stay=args.stay)

    elif args.cmd == 'run':
        addr = parse_addr(args.addr)
        data = open(args.file, 'rb').read()
        if cmd_load(ser, data, addr):
            cmd_go(ser, addr, stay=not args.no_stay)
        else:
            sys.exit(1)

    elif args.cmd == 'dump':
        addr = parse_addr(args.addr)
        cmd_dump(ser, addr, args.length)

    ser.close()


if __name__ == '__main__':
    main()
