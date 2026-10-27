#!/usr/bin/env bash
# Sweep the multiplier configurations over the CNN (nn_bench) and print a measured speedup table.
#   run from SIM/ :   make nn_mulsweep           (or   bash ../NN/nn_mul_sweep.sh)       6 simulations, about 1-2 minutes
# Prerequisites (already in place if you ran ../MUL/tools/mul_sweep.sh before): the parameterised mul_div_unit.sv and
# $(VLOG_DEFS) on the vlog line of bm_compile.  Keep AI_LAT fixed while sweeping.
# The last configuration stays compiled in the work library; the next `make nn_run` / `make regress` recompiles with the
# default (original) multiplier, so nothing else to restore.
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-nn_mulsweep}"
MAKE="${MAKE:-make}"
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
  echo "== $cfg"
  $MAKE bm_run PROG=nn_bench BM_VOPT= VLOG_DEFS="${DEFS[$cfg]}" > "$OUT/${cfg}.log" 2>&1 || echo "   FAILED, see $OUT/${cfg}.log"
done
python3 "$HERE/nn_mul_sweep_report.py" "$OUT"