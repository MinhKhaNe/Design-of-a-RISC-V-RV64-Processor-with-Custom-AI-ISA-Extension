make clean                              # xóa toàn bộ các transcript, file waveform kết quả sau khi compilation
make build                              # chạy compilation kiểm tra lỗi syntax
make wave                               # lệnh giúp biên dịch và mở các file waveform để check dạng sóng
make all                                # thực hiện tất cả các lệnh make clean, build, wave theo trình tự
make bm_run PROG=smoke                  # build C + compile RTL/TB + chay mo phong (batch)
make bm_build PROG=smoke                # chi bien dich C -> imem.hex / dmem.hex
make bm_sim                             # chi chay mo phong (can bm_compile truoc)
make bm_gui / bm_wave                   # mo giao dien / xuat waveform
make bm_dis PROG=smoke                  # file disassembly (kiem tra lenh compiler sinh ra)
make bm_check                           # kiem tra toolchain va RTL (imem/dmem co INIT_FILE chua)
make bm_data                            # sinh lai SRC/bench_data.h (du lieu + dap an NumPy)
make bm_host PROG=bench_baseline        # chay cung chuong trinh C tren may host: kiem tra DUNG/SAI (khong do chu ky)
make bm_clean / clean_all
python3 test_elf2hex.py                 # tự kiểm tra bộ chuyển ELF -> hex (không cần toolchain)
