#!/usr/bin/env python3
"""Program the Nexys 4 DDR over JTAG and capture the UART report.

The serial port is opened *before* programming so that lines printed right after
configuration are not lost.

    python uart_capture.py <file.bit> --until "^D0 " --log run.txt
"""
import argparse, os, re, subprocess, sys, threading, time
import serial
import serial.tools.list_ports

VIVADO = r"C:\Xilinx\Vivado\2024.2\bin\vivado.bat"
HERE = os.path.dirname(os.path.abspath(__file__))


def find_port():
    for p in serial.tools.list_ports.comports():
        if "0403:6010" in p.hwid:            # FTDI FT2232 on Digilent boards
            return p.device
    sys.exit("no Digilent USB-UART found")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bit")
    ap.add_argument("--port", default=None)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--until", default=None, help="regex: stop once a line matches")
    ap.add_argument("--count", type=int, default=1, help="number of --until matches to wait for")
    ap.add_argument("--timeout", type=float, default=60.0, help="seconds after programming")
    ap.add_argument("--log", default=None)
    args = ap.parse_args()

    port = args.port or find_port()
    ser = serial.Serial(port, args.baud, timeout=0.1)
    ser.reset_input_buffer()

    lines, stop = [], threading.Event()

    def reader():
        buf = b""
        while not stop.is_set():
            buf += ser.read(256)
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                lines.append(raw.decode("ascii", "replace").strip())

    th = threading.Thread(target=reader, daemon=True)
    th.start()

    prog = subprocess.run([VIVADO, "-mode", "batch", "-nojournal", "-nolog",
                           "-source", os.path.join(HERE, "program_board.tcl"),
                           "-tclargs", os.path.abspath(args.bit)],
                          capture_output=True, text=True)
    if "PROGRAMMED" not in prog.stdout:
        stop.set()
        sys.exit("programming failed:\n" + prog.stdout[-3000:] + prog.stderr[-2000:])
    print(f"programmed {args.bit}; listening on {port}", file=sys.stderr)

    pat = re.compile(args.until) if args.until else None
    t0 = time.time()
    while time.time() - t0 < args.timeout:
        if pat and sum(1 for l in lines if pat.search(l)) >= args.count:
            break
        time.sleep(0.05)
    time.sleep(0.2)
    stop.set()
    th.join()
    ser.close()

    out = "\n".join(l for l in lines if l)
    print(out)
    if args.log:
        with open(args.log, "w") as fh:
            fh.write(out + "\n")
    if pat and sum(1 for l in lines if pat.search(l)) < args.count:
        sys.exit("timeout waiting for " + args.until)


if __name__ == "__main__":
    main()
