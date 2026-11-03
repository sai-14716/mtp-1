#!/usr/bin/env python3
"""Program every built configuration onto the Nexys 4 DDR and record the measured kernel cycles.

    python scripts/run_board.py [TAG ...]        # default: every build/*/gpu_soc.bit

Writes results/board_runs.csv (one row per configuration x kernel) and results/board_logs/<tag>.txt.
The SoC repeats all kernels every 0.5 s; the second complete round is recorded.
"""
import csv, glob, os, re, subprocess, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CAPTURE = os.path.join(ROOT, "..", "scripts", "uart_capture.py")
KNAMES = ["vecadd", "matmul", "compute"]
LINE = re.compile(r"^K(\d) N(\d+) T(\d) P(\d+) M(\d+) C([0-9A-F]{8}) E([0-9A-F]{4}) R([0-9A-F]{2})$")


def sim_cycles(n, p, m, v):
    f = os.path.join(ROOT, "sim", f"res_N{n}_P{p}_M{m}" + ("_rr" if v == "rr" else "") + ".txt")
    out = {}
    if os.path.exists(f):
        for l in open(f):
            g = LINE.match(l.strip())
            if g:
                out[int(g.group(1))] = int(g.group(6), 16)
    return out


def run(tag, retry=1):
    bit = os.path.join(ROOT, "build", tag, "gpu_soc.bit")
    log = os.path.join(ROOT, "results", "board_logs", tag + ".txt")
    os.makedirs(os.path.dirname(log), exist_ok=True)
    n, p, m = map(int, re.findall(r"\d+", tag)[:3])
    r = subprocess.run([sys.executable, CAPTURE, bit, "--until", rf"^K2 N{n:02d} T4 P{p:02d} M{m:02d} .* R01$",
                        "--timeout", "20", "--log", log], capture_output=True, text=True)
    lines = [l.strip() for l in r.stdout.splitlines()]
    res = {}
    for l in lines:
        g = LINE.match(l)
        # the previous bitstream keeps printing until reprogramming finishes: keep only this configuration's lines
        if g and g.group(8) == "01" and (int(g.group(2)), int(g.group(4)), int(g.group(5))) == (n, p, m):
            res[int(g.group(1))] = g
    if len(res) != len(KNAMES):
        if retry:                                   # e.g. JTAG programming did not take effect: try once more
            print(f"{tag}: incomplete capture, retrying", flush=True)
            return run(tag, retry - 1)
        print(f"{tag}: incomplete capture\n{r.stdout}\n{r.stderr}")
        return []
    v = "rr" if "_rr" in tag else "stock"
    fm = re.search(r"_f(\d+)", tag)
    mhz = int(fm.group(1)) if fm else 50
    sim = sim_cycles(n, p, m, v)
    rows = []
    for k in sorted(res):
        g = res[k]
        cyc, err = int(g.group(6), 16), int(g.group(7), 16)
        rows.append(dict(cores=n, prog_ch=p, data_ch=m, dispatch=v, core_MHz=mhz, kernel=k, name=KNAMES[k], cycles=cyc, errors=err,
                         sim_cycles=sim.get(k, ""), board_eq_sim=(sim.get(k) == cyc) if k in sim else ""))
    print(f"{tag}: " + "  ".join(f"{r['name']}={r['cycles']} err={r['errors']}" for r in rows), flush=True)
    return rows


def main():
    tags = sys.argv[1:] or sorted(os.path.basename(os.path.dirname(b))
                                  for b in glob.glob(os.path.join(ROOT, "build", "*", "gpu_soc.bit")))
    path = os.path.join(ROOT, "results", "board_runs.csv")
    old = []
    if os.path.exists(path):
        def rtag(r):
            f = int(r.get("core_MHz") or 50)
            return (f"N{r['cores']}_P{r['prog_ch']}_M{r['data_ch']}_T4" + ("_rr" if r.get("dispatch") == "rr" else "")
                    + (f"_f{f}" if f != 50 else ""))
        old = [r for r in csv.DictReader(open(path)) if rtag(r) not in tags]
        for r in old:
            r.setdefault("dispatch", "stock")
            r["core_MHz"] = r.get("core_MHz") or 50
    rows = old + [r for t in tags for r in run(t)]
    rows.sort(key=lambda r: (r["dispatch"], int(r["prog_ch"]) > 1, int(r["data_ch"]), int(r["cores"]),
                             -int(r["core_MHz"]), int(r["kernel"])))
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["cores", "prog_ch", "data_ch", "dispatch", "core_MHz", "kernel", "name", "cycles", "errors",
                                           "sim_cycles", "board_eq_sim"])
        w.writeheader()
        w.writerows(rows)
    print("->", path)


if __name__ == "__main__":
    main()
