#!/bin/sh
# Run each newly finished bitstream on the board (skips configs that already have results/board_logs/<tag>.txt).
# Stops when results/WATCH_STOP exists.
cd "$(dirname "$0")/.."
rm -f results/WATCH_STOP
while [ ! -f results/WATCH_STOP ]; do
  for b in build/*/gpu_soc.bit; do
    t=$(basename "$(dirname "$b")")
    [ -f "results/board_logs/$t.txt" ] && continue
    grep -q "^BUILD_DONE $t" "build/$t/vivado.log" 2>/dev/null || continue
    python scripts/run_board.py "$t"
  done
  sleep 30
done
echo WATCH_DONE
