#!/usr/bin/env python3
"""Build gpu_soc_top for several configurations (in parallel) and collect utilization / timing.

    python scripts/sweep.py build  N,P,M[,stock|rr[,MHz]] ... [--jobs 2]
    python scripts/sweep.py report                       # parse every build/*/ into results/fpga_sweep.csv

N = NUM_CORES, P = program-memory channels, M = data-memory channels (THREADS_PER_BLOCK fixed at 4),
rr = use rtl/dispatch_rr.sv instead of the stock dispatcher (build tag gets suffix _rr).
"""
import argparse, csv, glob, os, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
VIVADO = r"C:\Xilinx\Vivado\2024.2\bin\vivado.bat"
CLK_NS = 20.0                                       # core clock constraint (50 MHz from the MMCM)
DEVICE = {"LUT": 63400, "FF": 126800, "BRAM": 135, "DSP": 240}


def tag(n, p, m, t=4, v="stock", f=50):
    return f"N{n}_P{p}_M{m}_T{t}" + ("_rr" if v == "rr" else "") + (f"_f{f}" if f != 50 else "")


def build_one(cfg):
    n, p, m, v, f = cfg
    out = os.path.join(ROOT, "build", tag(n, p, m, 4, v, f))
    os.makedirs(out, exist_ok=True)
    t0 = time.time()
    with open(os.path.join(out, "vivado_stdout.log"), "w") as fh:
        r = subprocess.run([VIVADO, "-mode", "batch", "-nojournal", "-log", os.path.join(out, "vivado.log"),
                            "-source", os.path.join(ROOT, "scripts", "build_gpu.tcl"),
                            "-tclargs", str(n), str(p), str(m), "4", v, str(f)],
                           stdout=fh, stderr=subprocess.STDOUT, cwd=out)
    ok = os.path.exists(os.path.join(out, "gpu_soc.bit"))
    msg = f"{tag(n, p, m, 4, v, f)}: {'OK' if ok else 'FAILED (rc=%d)' % r.returncode} in {time.time() - t0:.0f}s"
    print(msg, flush=True)
    return ok


def util_row(rpt, name):
    for line in open(rpt):
        cols = [c.strip() for c in line.split("|")]
        if len(cols) > 2 and cols[1] == name:
            return float(cols[2])
    return None


def parse(out):
    d = {}
    u = os.path.join(out, "util.rpt")
    if not os.path.exists(u):
        return None
    d["LUT"] = util_row(u, "Slice LUTs")
    d["LUTRAM"] = util_row(u, "LUT as Memory")
    d["FF"] = util_row(u, "Slice Registers")
    d["BRAM"] = util_row(u, "Block RAM Tile")
    d["DSP"] = util_row(u, "DSPs")
    tim = open(os.path.join(out, "timing.rpt")).read()
    m = re.search(r"WNS\(ns\).*?\n.*?\n\s*(-?[\d.]+)\s+(-?[\d.]+)\s+(\d+)\s+(\d+)\s+(-?[\d.]+)", tim)
    wns, whs = float(m.group(1)), float(m.group(5))
    d["WNS_ns"], d["WHS_ns"] = wns, whs
    d["timing_met"] = wns >= 0 and whs >= 0
    per = re.search(r"g_mmcm\.clk\w*_raw\s+\{[^}]*\}\s+([\d.]+)", tim)
    clk_ns = float(per.group(1)) if per else CLK_NS
    d["core_MHz"] = round(1000.0 / clk_ns, 1)
    d["Fmax_MHz"] = round(1000.0 / (clk_ns - wns), 1)
    cp = open(os.path.join(out, "critical_path.rpt")).read()
    src = re.search(r"Source:\s+(\S+)", cp)
    dst = re.search(r"Destination:\s+(\S+)", cp)
    lv = re.search(r"Logic Levels:\s+(\d+)", cp)
    d["crit_src"] = src.group(1) if src else ""
    d["crit_dst"] = dst.group(1) if dst else ""
    d["logic_levels"] = int(lv.group(1)) if lv else None
    pw = re.search(r"Total On-Chip Power \(W\)\s*\|\s*([\d.]+)", open(os.path.join(out, "power.rpt")).read())
    d["power_W"] = float(pw.group(1)) if pw else None
    d["bitstream"] = os.path.exists(os.path.join(out, "gpu_soc.bit"))
    return d


def report():
    rows = []
    for out in sorted(glob.glob(os.path.join(ROOT, "build", "N*_P*_M*_T*"))):
        n, p, m, t = map(int, re.findall(r"\d+", os.path.basename(out))[:4])
        base = os.path.basename(out)
        disp = "rr" if "_rr" in base else "stock"
        d = parse(out)
        if d is None:
            rows.append(dict(cores=n, prog_ch=p, data_ch=m, tpb=t, dispatch=disp, status="no util.rpt (build failed / running)"))
            continue
        d.update(cores=n, prog_ch=p, data_ch=m, tpb=t, dispatch=disp, status="ok",
                 LUT_pct=round(100 * d["LUT"] / DEVICE["LUT"], 2),
                 FF_pct=round(100 * d["FF"] / DEVICE["FF"], 2))
        rows.append(d)
    rows.sort(key=lambda r: (r["dispatch"], r["prog_ch"] > 1, r["data_ch"], r["cores"], -r.get("core_MHz", 50)))
    keys = ["cores", "prog_ch", "data_ch", "tpb", "dispatch", "core_MHz", "status", "LUT", "LUT_pct", "LUTRAM", "FF", "FF_pct", "BRAM",
            "DSP", "WNS_ns", "WHS_ns", "timing_met", "Fmax_MHz", "logic_levels", "crit_src", "crit_dst",
            "power_W", "bitstream"]
    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    path = os.path.join(ROOT, "results", "fpga_sweep.csv")
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    for r in rows:
        print(", ".join(f"{k}={r.get(k)}" for k in keys[:19] if k in r))
    print("->", path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["build", "report"])
    ap.add_argument("cfgs", nargs="*")
    ap.add_argument("--jobs", type=int, default=2)
    a = ap.parse_args()
    if a.cmd == "build":
        cfgs = []
        for c in a.cfgs:
            f = c.split(",")
            cfgs.append((int(f[0]), int(f[1]), int(f[2]), f[3] if len(f) > 3 else "stock",
                         int(f[4]) if len(f) > 4 else 50))
        with ThreadPoolExecutor(a.jobs) as ex:
            ok = list(ex.map(build_one, cfgs))
        print(f"{sum(ok)}/{len(ok)} builds produced a bitstream")
    report()


if __name__ == "__main__":
    main()
