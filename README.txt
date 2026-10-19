make clean                              # xóa toàn bộ các transcript, file waveform kết quả sau khi compilation
make build                              # chạy compilation kiểm tra lỗi syntax
make wave                               # lệnh giúp biên dịch và mở các file waveform để check dạng sóng
make all                                # thực hiện tất cả các lệnh make clean, build, wave theo trình tự
make PROG=smoke                         # biên dịch -> build/imem.hex, build/dmem.hex, build/prog_params.svh
make sim PROG=smoke RTL=<thư mục RTL>   # biên dịch + mô phỏng bằng Verilator
python3 test_elf2hex.py                 # tự kiểm tra bộ chuyển ELF -> hex (không cần toolchain)