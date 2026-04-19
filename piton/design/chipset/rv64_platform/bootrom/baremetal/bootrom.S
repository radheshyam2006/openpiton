.section .text.start, "ax", @progbits
.globl _start
_start:
  # li s0, 0x80000000 sign-extends in RV64 to 0xffffffff80000000.
  # Use shift sequence to safely load DRAM_BASE without sign-extension.
  li s0, 1
  slli s0, s0, 31
  slli s0, s0, 32
  srli s0, s0, 32
  csrr a0, mhartid
  la a1, _dtb
  jr s0

.section .text.hang, "ax", @progbits
.globl _hang
_hang:
  csrr a0, mhartid
  la a1, _dtb
1:
  wfi
  j 1b

.section .rodata.dtb, "a", @progbits
.globl _dtb
.align 5, 0
_dtb:
.incbin "rv64_platform.dtb"
