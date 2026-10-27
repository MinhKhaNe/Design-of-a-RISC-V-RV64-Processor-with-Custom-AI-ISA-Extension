#!/usr/bin/env bash
# Sweep the multiplier configurations over the three benchmarks and print a speedup-vs-multiplier table.
#   run from SIM/ :   bash ../MUL/mul_sweep.sh            (about 18 short simulations)
# Prerequisites: mul_div_unit.sv replaced by the parameterised one, and your Makefile's bm_compile vlog line has
#                $(VLOG_DEFS) added, e.g.   $(VLOG) -sv $(VLOG_DEFS) +incdir+$(BMB) -f $(RTL_F) $(BM_TB)
# Keep AI_LAT in top.sv fixed while sweeping.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-mulsweep}"
PROGS="${PROGS:-bench_baseline bench_opt bench_ai}"
mkdir -p "$OUT"
declare -A DEFS=(
  [iter]=""
  [mulw_short]="+define+MULW_SHORT_VAL=1"
  [lat3]="+define+MUL_MODE_VAL=2 +define+MUL_STALL_VAL=3"
  [lat1]="+define+MUL_MODE_VAL=2 +define+MUL_STALL_VAL=1"
  [mulw_fast]="+define+MULW_FAST_VAL=1"
  [comb]="+define+MUL_MODE_VAL=1"
)
for cfg in iter mulw_short lat3 lat1 mulw_fast comb; do
  for p in $PROGS; do
    echo "== $cfg / $p"
    make bm_run PROG="$p" BM_VOPT= VLOG_DEFS="${DEFS[$cfg]}" > "$OUT/${cfg}_${p}.log" 2>&1 || { echo "   FAILED, see $OUT/${cfg}_${p}.log"; }
  done
done
python3 "$HERE/mul_sweep_report.py" "$OUT"