# perf.mk -- cycle accounting of a bare-metal program on the core (perf_mon.sv + perf_report.py).   Add ONE line at the end of your Makefile:  include perf.mk
#   make perf_run                     nn_bench, current RTL:  where do the cycles go?  (bubbles by cause, instruction mix, loops, what-if bounds)
#   make perf_run PROG=bench_ai       another program (regions are numbered; use PERF_LABELS="--labels none --ovh 0" if region 0 is an empty measurement)
#   make perf_run VLOG_DEFS="+define+AI_LAT_VAL=3"        any RTL configuration (the same defines as the regression)
#   make perf_report LOG=perf_sim/nn_bench.log            only re-print the tables of a saved log
# PERF folder = the one holding perf_mon.sv and perf_report.py (auto-detected: ../PERF or ../perf).
# perf_mon.sv is run as a SECOND TOP-LEVEL MODULE next to tb_baremetal: no change to the testbench or the RTL.
#   If your testbench instance is not called tb_baremetal.dut, pass  PERF_DUT=<path>  (it becomes +define+PERF_DUT=<path>).
PYTHON     ?= python3
VLOG       ?= vlog
VLOG_DEFS  ?=
PROG       ?= nn_bench
PERF_DIR   ?= $(firstword $(wildcard ../PERF ../perf))
PERF_SIM   ?= perf_sim
PERF_VOPT  ?= -voptargs=+acc
PERF_LABELS ?=
LOG        ?= $(PERF_SIM)/$(PROG).log

.PHONY: perf_run perf_report

perf_run:
	@test -n "$(PERF_DIR)" || { echo "perf.mk: cannot find the PERF folder (perf_mon.sv). Pass PERF_DIR=<path>"; exit 1; }
	mkdir -p $(PERF_SIM)
	$(MAKE) --no-print-directory bm_compile PROG=$(PROG)
	$(VLOG) -sv $(VLOG_DEFS) $(if $(PERF_DUT),+define+PERF_DUT=$(PERF_DUT)) $(PERF_DIR)/perf_mon.sv
	$(MAKE) --no-print-directory bm_sim PROG=$(PROG) BM_VOPT="perf_mon $(PERF_VOPT)" | tee $(PERF_SIM)/$(PROG).log
	$(PYTHON) $(PERF_DIR)/perf_report.py $(PERF_SIM)/$(PROG).log --csv $(PERF_SIM)/$(PROG).csv $(PERF_LABELS)

perf_report:
	@test -n "$(PERF_DIR)" || { echo "perf.mk: cannot find the PERF folder (perf_report.py). Pass PERF_DIR=<path>"; exit 1; }
	$(PYTHON) $(PERF_DIR)/perf_report.py $(LOG) $(PERF_LABELS)
