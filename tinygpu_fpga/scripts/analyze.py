#!/usr/bin/env python3
"""Merge FPGA sweep (resources/timing) with board measurements, compute speedups, make figures.

    python scripts/analyze.py   ->  results/scaling.csv, results/*.png, results/summary.md
"""
import csv, os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
RES = os.path.join(ROOT, "results")
F_BOARD = 50.0                                    # MHz, clock the board runs at
KN = ["vecadd", "matmul", "compute"]
KDESC = {"vecadd": "K0 vecadd (memory-bound)", "matmul": "K1 matmul 8x8", "compute": "K2 compute (ALU-bound)"}

# reference palette, categorical slots 1-3 (validated all-pairs), text tokens
SURF, INK, INK2, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#8a8984", "#e6e5e1"
SERIES = {"A0": ("#eda100", "A-stock: 1 prog port, 4 data ports, stock dispatcher"),
          "A": ("#2a78d6", "A: 1 prog port, 4 data ports"),
          "B": ("#eb6834", "B: 1 prog port per core, 4 data ports"),
          "C": ("#1baf7a", "C: 1 prog port per core, N data ports")}


def series_of(p, m, n, disp="rr"):
    if p == 1 and m == 4:
        return "A0" if disp == "stock" else "A"
    if p == n and m == 4:
        return "B"
    if p == n and m == max(4, n):
        return "C"
    return None


def load():
    fpga = {(int(r["cores"]), int(r["prog_ch"]), int(r["data_ch"]), r["dispatch"], round(float(r["core_MHz"]))): r
            for r in csv.DictReader(open(os.path.join(RES, "fpga_sweep.csv"))) if r["status"] == "ok"}
    board = list(csv.DictReader(open(os.path.join(RES, "board_runs.csv"))))
    base = {r["name"]: int(r["cycles"]) for r in board
            if (r["cores"], r["prog_ch"], r["data_ch"], r["dispatch"]) == ("1", "1", "4", "stock")}
    rows = []
    for r in board:
        n, p, m, disp = int(r["cores"]), int(r["prog_ch"]), int(r["data_ch"]), r["dispatch"]
        mhz = int(r.get("core_MHz") or 50)
        f = fpga.get((n, p, m, disp, mhz), {})
        cyc = int(r["cycles"])
        fmax = float(f["Fmax_MHz"]) if f else None
        ok = int(r["errors"]) == 0 and cyc != 0xFFFFFFFF
        met = f.get("timing_met") == "True"
        rows.append(dict(cores=n, prog_ch=p, data_ch=m, dispatch=disp, core_MHz=mhz,
                         series=series_of(p, m, n, disp) or "", kernel=r["name"],
                         correct=ok, timing_met=met, valid=ok and met,
                         cycles=cyc, errors=int(r["errors"]), board_eq_sim=r["board_eq_sim"],
                         speedup=round(base[r["name"]] / cyc, 2) if ok else None,
                         t_us_board=round(cyc / mhz, 2) if ok else None,
                         Fmax_MHz=fmax, t_us_at_Fmax=round(cyc / fmax, 2) if (fmax and ok) else None,
                         LUT=f.get("LUT"), FF=f.get("FF")))
    return rows, {k[:4]: v for k, v in fpga.items() if k[4] == 50}      # figures: the 50 MHz-constrained builds


def style(ax, title, ylabel):
    ax.set_facecolor(SURF)
    ax.set_title(title, color=INK, fontsize=10, loc="left")
    ax.set_ylabel(ylabel, color=INK2, fontsize=9)
    ax.set_xlabel("TinyGPU cores", color=INK2, fontsize=9)
    ax.set_xscale("log", base=2)
    ax.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(MUTED)
    ax.tick_params(colors=INK2, labelsize=8)
    ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{int(v)}"))


def plot_line(ax, xs, ys, key):
    col, _ = SERIES[key]
    ax.plot(xs, ys, color=col, linewidth=2, marker="o", markersize=6,
            markeredgecolor=SURF, markeredgewidth=1.5, label=SERIES[key][1], zorder=3)
    ax.annotate(f"{'A-stock' if key == 'A0' else key}  {ys[-1]:g}", (xs[-1], ys[-1]), xytext=(6, 0), textcoords="offset points",
                va="center", fontsize=8, color=INK2)


def fig_speedup(rows):
    fig, axs = plt.subplots(1, 3, figsize=(13, 4.2), facecolor=SURF)
    for ax, k in zip(axs, KN):
        mx = 1
        for key in "ABC":
            pts = {}
            for r in rows:
                if r["kernel"] == k and r["valid"] and r["series"] in ((key,) if key != "A" else ("A", "A0")):
                    pts[r["cores"]] = r["speedup"]
                elif key == "C" and r["kernel"] == k and r["valid"] and r["series"] == "B" and r["cores"] <= 4:
                    pts.setdefault(r["cores"], r["speedup"])    # C == B while N <= 4 (M = max(4, N) = 4)
            pts = sorted(pts.items())
            if key in "BC":                                         # series B/C start from the 1-core baseline
                pts = [(1, 1.0)] + [p for p in pts if p[0] > 1]
            if len(pts) > 1:
                plot_line(ax, [p[0] for p in pts], [p[1] for p in pts], key)
                mx = max(mx, pts[-1][0])
        ideal = [2 ** i for i in range(0, mx.bit_length())]
        ax.plot(ideal, ideal, color=MUTED, linestyle="--", linewidth=1, zorder=1)
        ax.annotate("ideal", (ideal[-1], ideal[-1]), xytext=(-4, 4), textcoords="offset points",
                    ha="right", fontsize=8, color=MUTED)
        ax.set_yscale("log", base=2)
        ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v:g}"))
        style(ax, KDESC[k], "speedup vs 1 core")
    h, l = axs[0].get_legend_handles_labels()
    fig.legend(h, l, loc="lower center", ncol=3, frameon=False, fontsize=9, labelcolor=INK)
    fig.tight_layout(rect=(0, 0.08, 1, 1))
    fig.savefig(os.path.join(RES, "speedup.png"), dpi=150, facecolor=SURF)


def fig_fpga(fpga, field, ylabel, title, fname, hline=None):
    fig, ax = plt.subplots(figsize=(6.2, 4.2), facecolor=SURF)
    built = {key: dict((n, float(r[field])) for (n, p, m, d), r in fpga.items() if series_of(p, m, n, d) == key)
             for key in ("A0", "A", "B", "C")}
    a1 = fpga.get((1, 1, 4, "stock"))
    if a1:                                          # 1 core, 1 port, 4 data ports is the common starting point of B
        built["B"].setdefault(1, float(a1[field]))
    for n, v in built["B"].items():                 # C == B while N <= 4 (M = max(4, N) = 4)
        if n <= 4:
            built["C"].setdefault(n, v)
    for key in ("A0", "A", "B", "C"):               # only configurations that were actually implemented
        pts = sorted(built[key].items())
        if pts:
            plot_line(ax, [q[0] for q in pts], [q[1] for q in pts], key)
    if hline:
        ax.axhline(hline[0], color=MUTED, linestyle="--", linewidth=1, zorder=1)
        ax.annotate(hline[1], (1.0, hline[0]), xycoords=("axes fraction", "data"), xytext=(0, 3),
                    textcoords="offset points", ha="right", va="bottom", fontsize=8, color=MUTED)
    style(ax, title, ylabel)
    ax.legend(loc="best", frameon=False, fontsize=8, labelcolor=INK)
    fig.tight_layout()
    fig.savefig(os.path.join(RES, fname), dpi=150, facecolor=SURF)


def md_tables(rows):
    """Markdown tables for the report: FPGA implementation results and measured kernel cycles."""
    allf = list(csv.DictReader(open(os.path.join(RES, "fpga_sweep.csv"))))
    out = ["| Cores | Prog ports | Data ports | Dispatcher | Clock (MHz) | LUT | LUT % | FF | BRAM | DSP | WNS (ns) | "
           "Timing met | Fmax est. (MHz) | Critical path |",
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    def crit(r):
        d = r.get("crit_dst", "")
        for key, name in (("dispatch", "dispatcher"), ("data_memory_controller", "data-mem arbiter"),
                          ("program_memory_controller", "prog-mem arbiter"), ("alu", "ALU divider"),
                          ("lsu", "LSU/arbiter"), ("core_instance", "core")):
            if key in d or key in r.get("crit_src", ""):
                return name
        return d.split("/")[-2] if "/" in d else d
    for r in sorted(allf, key=lambda r: (r["dispatch"] != "stock", int(r["prog_ch"]) > 1, int(r["data_ch"]) > 4,
                                         int(r["cores"]), -float(r.get("core_MHz") or 50))):
        if r["status"] != "ok":
            out.append(f"| {r['cores']} | {r['prog_ch']} | {r['data_ch']} | {r['dispatch']} | | {r['status']} |"
                       " | | | | | | | |")
            continue
        out.append(f"| {r['cores']} | {r['prog_ch']} | {r['data_ch']} | {r['dispatch']} | {float(r['core_MHz']):g} | "
                   f"{int(float(r['LUT'])):,} | {r['LUT_pct']} | {int(float(r['FF'])):,} | {r['BRAM']} | "
                   f"{int(float(r['DSP']))} | {r['WNS_ns']} | {'yes' if r['timing_met'] == 'True' else '**no**'} | "
                   f"{r['Fmax_MHz']} | {crit(r)} |")
    out += ["", "| Cores | Prog ports | Data ports | Dispatcher | Clock (MHz) | Timing met | "
            "vecadd cycles (speedup) | matmul cycles (speedup) | compute cycles (speedup) | All results correct | Board = sim |",
            "|---|---|---|---|---|---|---|---|---|---|---|"]
    grp = {}
    for r in rows:
        grp.setdefault((r["series"], r["cores"], r["prog_ch"], r["data_ch"], r["dispatch"], r["core_MHz"]), {})[r["kernel"]] = r
    order = {"A0": 0, "A": 1, "B": 2, "C": 3, "": 4}
    for key in sorted(grp, key=lambda k: (order[k[0]], k[1], -k[5])):
        g = grp[key]
        if len(g) < 3:
            continue
        def cell(k):
            r = g[k]
            return "timeout" if r["cycles"] == 0xFFFFFFFF else f"{r['cycles']:,} ({r['speedup']}x)"
        okall = all(g[k]["correct"] for k in KN)
        eq = all(str(g[k]["board_eq_sim"]) == "True" for k in KN)
        out.append(f"| {key[1]} | {key[2]} | {key[3]} | {key[4]} | {key[5]} | "
                   f"{'yes' if g[KN[0]]['timing_met'] else '**no**'} | {cell('vecadd')} | {cell('matmul')} | "
                   f"{cell('compute')} | {'yes' if okall else '**no**'} | {'yes' if eq else '**no**'} |")
    with open(os.path.join(RES, "tables.md"), "w") as fh:
        fh.write("\n".join(out) + "\n")


def main():
    rows, fpga = load()
    rows.sort(key=lambda r: (r["series"] or "Z", r["cores"], r["dispatch"], KN.index(r["kernel"])))
    with open(os.path.join(RES, "scaling.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    fig_speedup(rows)
    fig_fpga(fpga, "LUT_pct", "LUT utilization (% of XC7A100T)", "FPGA LUT usage vs core count", "lut_usage.png")
    fig_fpga(fpga, "Fmax_MHz", "Fmax (MHz, from routed WNS at 50 MHz)", "Achievable clock vs core count",
             "fmax.png", hline=(50.0, "board clock 50 MHz"))
    md_tables(rows)
    print("wrote scaling.csv, tables.md, speedup.png, lut_usage.png, fmax.png")


if __name__ == "__main__":
    main()
