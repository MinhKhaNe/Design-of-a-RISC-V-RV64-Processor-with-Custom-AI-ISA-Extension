VSIM = vsim
VLOG = vlog
VLIB = vlib
VMAP = vmap

WORK = work
TOP  = tb_rv64imafc

RTL_F    = rtl.f
TB_SRC   = ../TB/$(TOP).sv

VOPT_ARGS = -voptargs="+acc"

.PHONY: all run compile simulate gui wave clean \
        help bm_check bm_data bm_host bm_build bm_dis bm_compile bm_sim bm_run bm_gui bm_wave bm_clean clean_all

all: clean run

run: compile simulate

$(WORK):
	$(VLIB) $(WORK)
	$(VMAP) $(WORK) $(WORK)

compile: $(WORK)
	$(VLOG) -sv -f $(RTL_F) $(TB_SRC)

simulate:
	$(VSIM) -c $(TOP) $(VOPT_ARGS) -do "run -all; quit"

gui:
	$(VSIM) $(TOP) $(VOPT_ARGS)

wave:
	$(VSIM) $(TOP) $(VOPT_ARGS) -do "log -r /*; add wave -r /*; run -all"

clean:
	rm -rf $(WORK) transcript vsim.wlf *.log *.vcd wave.vcd

# ======================================================================
#  BARE-METAL: bien dich chuong trinh C -> nap vao imem/dmem -> mo phong tren core
#
#    make bm_run PROG=smoke        # build C + compile RTL/TB + chay mo phong (batch)
#    make bm_build PROG=smoke      # chi bien dich C -> imem.hex / dmem.hex
#    make bm_sim                   # chi chay mo phong (can bm_compile truoc)
#    make bm_gui / bm_wave         # mo giao dien / xuat waveform
#    make bm_dis PROG=smoke        # file disassembly (kiem tra lenh compiler sinh ra)
#    make bm_check                 # kiem tra toolchain va RTL (imem/dmem co INIT_FILE chua)
#    make bm_data                  # sinh lai SRC/bench_data.h (du lieu + dap an NumPy)
#    make bm_host PROG=bench_baseline   # chay cung chuong trinh C tren may host: kiem tra DUNG/SAI (khong do chu ky)
#    make bm_clean / clean_all
#
#  Bo cuc thu muc mac dinh (doi bang SW_DIR=..., BM_TB=...):
#    <sim>/Makefile, rtl.f          (thu muc nay)
#    ../SW/SRC/{crt0.S,rt.h,<PROG>.c}, ../SW/link.ld.in, ../SW/elf2hex.py
#    ../TB/tb_baremetal.sv
#  Ket qua build nam rieng theo tung chuong trinh: SW_build/<PROG>/
# ======================================================================
RISCV      ?= riscv64-unknown-elf-
CC          = $(RISCV)gcc
OBJDUMP     = $(RISCV)objdump
SIZE        = $(RISCV)size
PYTHON     ?= python3
HOSTCC     ?= gcc

PROG       ?= smoke
SW_DIR     ?= ../SW
SW_BUILD   ?= SW_build
SRCS       ?= $(SW_DIR)/SRC/$(PROG).c
BMB         = $(SW_BUILD)/$(PROG)

ARCH       ?= rv64imac_zicsr
ABI        ?= lp64
IMEM_BYTES ?= 65536
DMEM_BYTES ?= 65536
RAM_BASE   ?= 0x10000
TIMEOUT    ?= 5000000

BM_TOP      = tb_baremetal
BM_TB      ?= ../TB/$(BM_TOP).sv
BM_VOPT    ?= $(VOPT_ARGS)
BM_INI      = $(if $(wildcard modelsim.ini),-modelsimini $(CURDIR)/modelsim.ini)
BM_VSIM_ARGS = $(BM_INI) -lib $(CURDIR)/$(WORK) $(BM_TOP) $(BM_VOPT) +TIMEOUT=$(TIMEOUT)

CFLAGS  = -O2 -g -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany -ffreestanding -fno-builtin -fno-pic \
          -ffunction-sections -fdata-sections -Wall -Wextra \
          -DRAM_BASE=$(RAM_BASE)UL -DRAM_SIZE=$(DMEM_BYTES)UL -I$(SW_DIR)/SRC
LDFLAGS = -nostdlib -nostartfiles -static -Wl,--gc-sections -Wl,-Map=$(BMB)/$(PROG).map -T $(BMB)/link.ld
LIBS   ?= -lgcc

help:
	@echo "RTL:        make run | gui | wave | clean"
	@echo "Bare-metal: make bm_run PROG=<ten> | bm_build | bm_compile | bm_sim | bm_gui | bm_wave | bm_dis | bm_check | bm_data | bm_host | bm_clean | clean_all"
	@echo "Bien hay doi: PROG ARCH(rv64imac_zicsr|rv64im_zicsr) IMEM_BYTES DMEM_BYTES TIMEOUT SW_DIR BM_TB RISCV BM_VOPT"

bm_check:
	@command -v $(CC) >/dev/null 2>&1 || echo "[bm_check] LOI: khong tim thay $(CC)  (truyen RISCV=<prefix>- neu toolchain co prefix khac)"
	@command -v $(PYTHON) >/dev/null 2>&1 || echo "[bm_check] LOI: khong tim thay $(PYTHON)"
	@test -f $(SW_DIR)/elf2hex.py || echo "[bm_check] LOI: khong thay $(SW_DIR)/elf2hex.py (dat SW_DIR=...)"
	@test -f $(BM_TB) || echo "[bm_check] LOI: khong thay $(BM_TB) (dat BM_TB=...)"
	@for f in $$(grep -E '(imem|dmem)\.sv[[:space:]]*$$' $(RTL_F) 2>/dev/null); do \
	  grep -q INIT_FILE $$f || echo "[bm_check] CANH BAO: $$f chua co tham so INIT_FILE (can imem/dmem cua buoc 1)"; done
	@echo "[bm_check] xong"

$(BMB):
	mkdir -p $@

bm_data:
	$(PYTHON) $(SW_DIR)/gen_data.py $(SW_DIR)/SRC/bench_data.h

# Chay chuong trinh tren may host (gcc thuong): chi kiem tra logic dung/sai so voi dap an, KHONG do chu ky
bm_host:
	mkdir -p $(SW_BUILD)
	$(HOSTCC) -O2 -Wall -Wextra -DHOST_BUILD -I$(SW_DIR)/SRC $(SRCS) -o $(SW_BUILD)/$(PROG)_host
	$(SW_BUILD)/$(PROG)_host

$(BMB)/link.ld: $(SW_DIR)/link.ld.in Makefile | $(BMB)
	sed -e 's/@IMEM_BYTES@/$(IMEM_BYTES)/' -e 's/@DMEM_BYTES@/$(DMEM_BYTES)/' -e 's/@RAM_BASE@/$(RAM_BASE)/' $< > $@

$(BMB)/$(PROG).elf: $(SW_DIR)/SRC/crt0.S $(SRCS) $(wildcard $(SW_DIR)/SRC/*.h) $(BMB)/link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) $(SW_DIR)/SRC/crt0.S $(SRCS) $(LIBS) -o $@
	$(SIZE) $@

$(BMB)/imem.hex: $(BMB)/$(PROG).elf $(SW_DIR)/elf2hex.py
	$(PYTHON) $(SW_DIR)/elf2hex.py $< --ram-base $(RAM_BASE) --imem-bytes $(IMEM_BYTES) --dmem-bytes $(DMEM_BYTES) -o $(BMB)

$(BMB)/$(PROG).dis: $(BMB)/$(PROG).elf
	$(OBJDUMP) -d -M no-aliases $< > $@

bm_build: $(BMB)/imem.hex

bm_dis: $(BMB)/$(PROG).dis
	@echo "Disassembly: $(BMB)/$(PROG).dis"

# TB phai bien dich lai moi lan doi PROG (prog_params.svh chua TRAP_PC/kich thuoc bo nho)
bm_compile: $(WORK) bm_check $(BMB)/imem.hex
	$(VLOG) -sv +incdir+$(BMB) -f $(RTL_F) $(BM_TB)

# chay trong thu muc build cua chuong trinh de $readmemh tim thay imem.hex / dmem.hex
bm_sim:
	cd $(BMB) && $(VSIM) -c $(BM_VSIM_ARGS) -do "run -all; quit -f"

bm_run: bm_compile bm_sim

bm_gui:
	cd $(BMB) && $(VSIM) $(BM_VSIM_ARGS)

bm_wave:
	cd $(BMB) && $(VSIM) $(BM_VSIM_ARGS) -do "log -r /*; add wave /$(BM_TOP)/dut/*; run -all"

bm_clean:
	rm -rf $(SW_BUILD)

clean_all: clean bm_clean