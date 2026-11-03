#!/bin/sh
# usage: sim/run_sim.sh NUM_CORES PROG_CH DATA_CH [TPB] [stock|rr]   (run from anywhere)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
N=$1; P=$2; M=$3; T=${4:-4}; V=${5:-stock}
SUF=""; DISP=dispatch; [ "$V" = rr ] && { SUF="_rr"; DISP=dispatch_rr; }
W="$ROOT/sim/work_N${N}_P${P}_M${M}_T${T}${SUF}"
mkdir -p "$W"; cd "$W"
sed -e "s/NUM_CORES = [0-9]*;/NUM_CORES = $N;/" -e "s/PROG_CH   = [0-9]*;/PROG_CH   = $P;/" \
    -e "s/DATA_CH   = [0-9]*;/DATA_CH   = $M;/" -e "s/TPB       = [0-9]*;/TPB       = $T;/" "$ROOT/sim/tb_soc.sv" > tb_soc.sv
export PATH="/c/Xilinx/Vivado/2024.2/bin:$PATH"
cmd //c "xvlog -sv ../../rtl/alu.sv ../../rtl/controller.sv ../../rtl/core.sv ../../rtl/dcr.sv ../../rtl/decoder.sv ../../rtl/${DISP}.sv ../../rtl/fetcher.sv ../../rtl/lsu.sv ../../rtl/pc.sv ../../rtl/registers.sv ../../rtl/scheduler.sv ../../rtl/gpu.sv ../../soc/gpu_soc_top.sv tb_soc.sv" > comp.log 2>&1 || { grep -E "ERROR" comp.log; exit 1; }
cmd //c "xelab tb_soc -s soc_sim -L unisims_ver" > elab.log 2>&1 || { grep -E "ERROR" elab.log; exit 1; }
cmd //c "xsim soc_sim -R" > sim.log 2>&1
grep -E "^K[0-9]|TIMEOUT" sim.log
