# SGEMM
#   - Dtype: float32
#   - Basic unit: A{5,64} x B{64,16} = C{5,16} (Accumulator: 10x YMM registers)
#     - Cost:
#       - Insn:    10x64 =  640 FMA (bottleneck; IPC throughput)
#       - Insn:     7x64 =  448 LD  (total: 64*(16+5)*4  =  5.25   KB)
#       - Insn:      5x2 =   10 ST  (total: 10*32 = 320B =  0.3125 KB, NT-hinted?)
#       - Time: 320 cc
#       - L1d occupancy:       64*(16+5)*4     =  5.25  KB   < 32 KB
#       - L1d  -> Core Rd BW:  64*(16+5)*4/320 = 16.8   B/cc < 64 B/cc
#       - Core -> L1d  Wr BW:        10*32/320 =  1.0   B/cc < 32 B/cc
#   
#   - Subset: The execution of thirty-two basic units
#              |   B0  |   B1  |   B2  |   B3
#        ------+-------+-------+-------+-------
#          A0  |  A0B0 |  A0B1 |  A0B2 |  A0B3
#          A1  |  A1B0 |  A1B1 |  A1B2 |  A1B3
#          A2  |  A2B0 |  A2B1 |  A2B2 |  A2B3
#          A3  |  A3B0 |  A3B1 |  A3B2 |  A3B3
#          A4  |  A4B0 |  A4B1 |  A4B2 |  A4B3
#          A5  |  A5B0 |  A5B1 |  A5B2 |  A5B3
#          A6  |  A6B0 |  A6B1 |  A6B2 |  A6B3
#          A7  |  A7B0 |  A7B1 |  A7B2 |  A7B3
#     loading eight A-slices and four B-slices, and performing every contraction
#     between them, effectively performing A{40,64} x B{64,64} = C{40,64}.
#     - Cost:
#       - Insn:  20480 FMA, 14336 LD, 320 ST
#       - Time:  10240 cc
#       - L1d occupancy:       64*(16*4+5*8)*4       = 26     KB   < 32 KB
#       - L1d  -> Core Rd BW:  64*(16*4+5*8)*4/10240 =  2.6   B/cc < 32 B/cc
#                                                      (+1.0 if consuming accumulators!)
#       - Core -> L1d  Wr BW:         32*10*32/10240 =  1.0   B/cc < 32 B/cc
#     - Collision Analysis:
#       - A-slices: 8 contiguous slices, read sequentially (by stride of 4 bytes).
#                   Full occupancy of 8*5*64*sizeof(float) = 10KB = 2.5 cache ways.
#       - B-slices: 4 contiguous slices, read in 64 blocks of 16 floats (64 bytes),
#                   strided by 320 floats (1280 bytes). When a slice is strided by
#                   1280 bytes = 20 = 5x4 cachelines, only 1/4 of all cache sets
#                   are used, but four contiguous slices achieve full occupancy at
#                   4*16*64*sizeof(float) = 16KB = 4 cache ways.
#   
#   - Set: The execution of forty subsets
#               | B0:B3 | B4:B7 | B8:B11|B12:B15|B16:B19
#        -------+-------+-------+-------+-------+-------
#        A0:A7  |  SS00 |  SS01 |  SS02 |  SS03 |  SS04
#        A8:A15 |  SS10 |  SS11 |  SS12 |  SS13 |  SS14
#       A16:A23 |  SS20 |  SS21 |  SS22 |  SS23 |  SS24
#       A24:A31 |  SS30 |  SS31 |  SS32 |  SS33 |  SS34
#       A32:A39 |  SS40 |  SS41 |  SS42 |  SS43 |  SS44
#       A40:A47 |  SS50 |  SS51 |  SS52 |  SS53 |  SS54
#       A48:A55 |  SS60 |  SS61 |  SS62 |  SS63 |  SS64
#       A56:A63 |  SS70 |  SS71 |  SS72 |  SS73 |  SS74
#     loading sixty-four A-slices and twenty B-slices, and performing every contraction
#     between them, effectively performing A{320,64} x B{64,320} = C{320,320}.
#     - Cost:
#       - Insn:  819200 FMA, 573440 LD, 12800 ST
#       - Time:  409600 cc
#       - L2 occupancy:        64*(16*20+5*64)*4        = 160     KB   < 512 KB
#       - L2   -> L1d  Rd BW:  64*(16*20+5*64)*4/409600 =   0.4   B/cc < 32 B/cc
#                                                      (+1.0 if consuming accumulators!)
#       - L1d  -> L2   Wr BW:        64*20*10*32/409600 =   1.0   B/cc < 32 B/cc



## The calling convention of the System V AMD64 ABI is followed on Solaris, Linux,
## FreeBSD, macOS, and is the de facto standard among Unix and Unix-like operating
## systems. The OpenVMS Calling Standard on x86-64 is based on the System V ABI
## with some extensions needed for backwards compatibility. The first six integer
## or pointer arguments are passed in registers RDI, RSI, RDX, RCX, R8, R9 (R10 is
## used as a static chain pointer in case of nested functions), while
## XMM0, XMM1, XMM2, XMM3, XMM4, XMM5, XMM6 and XMM7 are used for the first
## floating point arguments. As in the Microsoft x64 calling convention, additional
## arguments are passed on the stack. Integer return values up to 64 bits in size
## are stored in RAX while values up to 128 bit are stored in RAX and RDX.
## Floating-point return values are similarly stored in XMM0 and XMM1. The wider
## YMM and ZMM registers are used for passing and returning wider values in place
## of XMM when they exist.

## If the callee wishes to use registers RBX, RSP, RBP, and R12–R15, it must
## restore their original values before returning control to the caller. All other
## registers must be saved by the caller if it wishes to preserve their values.

## For leaf-node functions (functions which do not call any other function(s)), a
## 128-byte space is stored just beneath the stack pointer of the function. The
## space is called the red zone. This zone will not be clobbered by any signal or
## interrupt handlers. Compilers can thus utilize this zone to save local variables.
## Compilers may omit some instructions at the starting of the function (adjustment
## of RSP, RBP) by utilizing this zone. However, other functions may clobber this
## zone. Therefore, this zone should only be used for leaf-node functions. gcc and
## clang offer the -mno-red-zone flag to disable red-zone optimizations.

## If the callee is a variadic function, then the number of floating point
## arguments passed to the function in vector registers must be provided by the
## caller in the AL register.

## Unlike the Microsoft calling convention, a shadow space is not provided; on
## function entry, the return address is adjacent to the seventh integer argument
## on the stack.

.intel_syntax noprefix



.section .rodata
.align 64
.Lvectormask10:
.int -1, -1, -1, -1, -1, -1, -1, -1, 0, 0, 0, 0, 0, 0, 0, 0



.text
#
# SGEMM Basic Unit Kernel
#
# The SGEMM basic unit is a matrix multiplication of C(5,16) += A(5xK) x B(Kx16)
# sliced out of C(320x320) += A(320xK) x B(Kx320) matrix tiles. There are 1280
# basic units per tile operation. K is divisible by 4 such that 4 <= K <= 64.
#
# An SGEMM basic unit executes K sets of 10 FMAs. The K sets are broken into
# four quarters, executed in alternate ascending-descending fashion:
#
#    Quarter 0:  k=0 mod 4;  pk=+1;  k+pk=1 mod 4;  iterate post k+=4
#                exit: k+=pk, pk=+pk*2=+2, k == K+1
#    Quarter 1:  k=1 mod 4;  pk=+2;  k+pk=3 mod 4;  iterate pre  k-=4
#                exit: k+=pk, pk=-pk/2=-1, k ==   3
#    Quarter 2:  k=3 mod 4;  pk=-1;  k+pk=2 mod 4;  iterate post k+=4
#                exit: k+=pk, pk=+pk*2=-2, k == K+2
#    Quarter 3:  k=2 mod 4;  pk=-2;  k+pk=0 mod 4;  iterate pre  k-=4
#                exit: k+=pk, pk=-pk/2=+1, k ==   0
#
# The ascent-descend style has the advantage of leaving the input registers
# unchanged by balancing increments and decrements.
#
.align 256
.global sgemm_bu_core_entry   # Purely for debug information, DO NOT CALL DIRECTLY!
sgemm_bu_core_entry:          # Purely for debug information, DO NOT CALL DIRECTLY!
.Lsgemm_bu_core_entry_clr:                      # REGISTERS ON ENTRY:
                                                #   RAX: &A[ m ][k=0]   A[320][ 64]
                                                #        The A-pointer **cannot** be moved from RAX!!!
                                                #   RBX: &B[k=0][ n ]   B[ 64][320]
                                                #   RCX: &C[ m ][ n ]   C[320][320]
                                                #   RDX: +1*320*4
                                                #   RDI: LinkRegister1
                                                #   RSI: LinkRegister2
                                                #   R8:  &A[ m ][k=K]
                                                # REGISTERS CLOBBERED ON EXIT:
                                                # ************ BU CORE FORWARD, PEELED ITER ************
    vmovaps      ymm4,  [rbx]                   # Load B[k, n  :n+ 8]
    vmovaps      ymm5,  [rbx+32]                # Load B[k, n+8:n+16]
    vbroadcastss ymm3,  [rax+1*64*4]            # Load A[m+1, k]
    vmulps       ymm8,   ymm3,  ymm4            #  => acc10 += A[1,k] * B[k,n:n+8]
    vmulps       ymm9,   ymm3,  ymm5            #  => acc11 += A[1,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax]                   # Load A[m+0, k]
    vmulps       ymm6,   ymm3,  ymm4            #  => acc00 += A[0,k] * B[k,n:n+8]
    vmulps       ymm7,   ymm3,  ymm5            #  => acc01 += A[0,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+3*64*4]            # Load A[m+3, k]
    vmulps       ymm12,  ymm3,  ymm4            #  => acc30 += A[3,k] * B[k,n:n+8]
    vmulps       ymm13,  ymm3,  ymm5            #  => acc31 += A[3,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*64*4]            # Load A[m+2, k]
    vmulps       ymm10,  ymm3,  ymm4            #  => acc20 += A[2,k] * B[k,n:n+8]
    vmulps       ymm11,  ymm3,  ymm5            #  => acc21 += A[2,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+4*64*4]            # Load A[m+4, k]
    addq         rax,    4*4                    # Increment A-pointer (A[m][k+=4])
    vmulps       ymm14,  ymm3,  ymm4            #  => acc40 += A[4,k] * B[k,n:n+8]
    vmulps       ymm15,  ymm3,  ymm5            #  => acc41 += A[4,k] * B[k,n+8:n+16]
    prefetcht0  [rbx+rdx]                       # Initiate prefetch of B-slice for next sub-BU
    leaq         rbx,   [rbx+4*320*4]           # Increment B-pointer (B[k+=4][n], no rflags)
    cmpq         rax,    r8                     # Exit if k >= K (equivalently: &A[k] >= &A[K])
    jge  .Lsgemm_bu_core_forward_exit           # Single-iteration early-exit
.align 128                                      # ************ BU CORE FORWARD, EXTREMELY HOT ************
.Lsgemm_bu_core_entry_acc:                      # do{
.Lsgemm_bu_core_forward:                        #
    vmovaps      ymm4,  [rbx]                   #     Load B[k, n  :n+ 8]
    vmovaps      ymm5,  [rbx+32]                #     Load B[k, n+8:n+16]
    vbroadcastss ymm3,  [rax+1*64*4]            #     Load A[m+1, k]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax]                   #     Load A[m+0, k]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+3*64*4]            #     Load A[m+3, k]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*64*4]            #     Load A[m+2, k]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+4*64*4]            #     Load A[m+4, k]
    addq         rax,    4*4                    #     Increment A-pointer (A[m][k+=4])
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k] * B[k,n+8:n+16]
    prefetcht0  [rbx+rdx]                       #     Initiate prefetch of B-slice for next sub-BU
    leaq         rbx,   [rbx+4*320*4]           #     Increment B-pointer (B[k+=4][n], no rflags)
    cmpq         rax,    r8                     #     Exit if k >= K (equivalently: &A[k] >= &A[K])
    jnge .Lsgemm_bu_core_forward                # }while()
.Lsgemm_bu_core_forward_exit:                   # ************ BU CORE FORWARD, EXTREMELY HOT ************
    xor          al,     4                      # Begin fetching from A-pointer addresses corresponding to prefetch.
                                                # (XOR AL, imm8 selected to save 2 bytes and fit within 2 L1i$ cachelines)
    addq         rbx,    rdx                    # Begin fetching from previously prefetched B-pointer addresses.
    addq         rdx,    rdx                    # Double the prefetch offset.
.align 256                                      # ************ BU CORE BACKWARD, EXTREMELY HOT ************
.Lsgemm_bu_core_backward:                       # do{
    leaq         rbx,   [rbx-4*320*4]           #     Pre-decrement B-pointer (B[k-=4][n], no rflags)
    vmovaps      ymm4,  [rbx]                   #     Load B[k, n  :n+ 8]
    subq         rax,    4*4                    #     Pre-decrement A-pointer (A[m][k-=4])
    vmovaps      ymm5,  [rbx+32]                #     Load B[k, n+8:n+16]
    vbroadcastss ymm3,  [rax+1*64*4]            #     Load A[m+1, k]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax]                   #     Load A[m+0, k]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+3*64*4]            #     Load A[m+3, k]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*64*4]            #     Load A[m+2, k]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+4*64*4]            #     Load A[m+4, k]
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k] * B[k,n+8:n+16]
    prefetcht0  [rbx+rdx]                       #     Initiate prefetch of B-slice for next sub-BU
    test         al,     0b11110000             #     Exit if k == 0 (equivalently: &A[k] == &A[0])
    jne  .Lsgemm_bu_core_backward               # }while()
                                                # ************ BU CORE BACKWARD, EXTREMELY HOT ************
    addq         rbx,    rdx                    # Begin fetching from previously prefetched B-pointer addresses.
    sar          rdx,    1                      # Halve  the prefetch offset.
    neg          rdx                            # Negate the prefetch offset.
.align 128
    xor          al,     8                      # Begin fetching from A-pointer addresses corresponding to prefetch.
                                                # (XOR AL, imm8 selected to save 2 bytes and fit within 2 L1i$ cachelines)
    test         al,     0b00001000
    jne  .Lsgemm_bu_core_forward                # If first half complete, begin second half.
    jmp          rdi                            # RETURN (LINK REGISTER)
.byte 0x66, 0x66, 0x66, 0x0F, 0x1F              # 11-byte-
.byte 0x84, 0x00, 0x00, 0x00, 0x00, 0x00        # nop padding
.byte 0x66, 0x66, 0x66, 0x0F, 0x1F              # 11-byte-
.byte 0x84, 0x00, 0x00, 0x00, 0x00, 0x00        # nop padding
.byte 0x66, 0x66, 0x66, 0x0F, 0x1F              # 11-byte-
.byte 0x84, 0x00, 0x00, 0x00, 0x00, 0x00        # nop padding
.Lsgemm_bu_eject_beta_one:                      # REGISTERS ON ENTRY:
                                                #   RSI:  LinkRegister2
                                                #   RCX:  &C[ m ][ n ]
                                                #   YMM0: alpha
                                                # REGISTERS CLOBBERED ON EXIT:
                                                #   YMM6-YMM15
                                                # ************ BU EJECTION (beta=1) ************
    vfmadd213ps  ymm8,   ymm0, [rcx+1*320*4]    #   alpha * acc10 -->
    vfmadd213ps  ymm9,   ymm0, [rcx+1*320*4+32] #   alpha * acc11 -->
    vfmadd213ps  ymm6,   ymm0, [rcx]            #   alpha * acc00 -->
    vfmadd213ps  ymm7,   ymm0, [rcx+32]         #   alpha * acc01 -->
    vfmadd213ps  ymm12,  ymm0, [rcx+3*320*4]    #   alpha * acc30 -->
    vfmadd213ps  ymm13,  ymm0, [rcx+3*320*4+32] #   alpha * acc31 -->
    vfmadd213ps  ymm10,  ymm0, [rcx+2*320*4]    #   alpha * acc20 -->
    vfmadd213ps  ymm11,  ymm0, [rcx+2*320*4+32] #   alpha * acc21 -->
    vfmadd213ps  ymm14,  ymm0, [rcx+4*320*4]    #   alpha * acc40 -->
    vfmadd213ps  ymm15,  ymm0, [rcx+4*320*4+32] #   alpha * acc41 -->
.align 256
.Lsgemm_bu_eject_alpha_one_beta_zero:           # REGISTERS ON ENTRY:
                                                #   RSI:  LinkRegister2
                                                #   RCX: &C[ m ][ n ]
                                                # REGISTERS CLOBBERED ON EXIT:
                                                #   (None)
                                                # ************ BU EJECTION (alpha=1, beta=0) ************
    vmovaps     [rcx+1*320*4],    ymm8          #                        C[1][n:n+8]
    vmovaps     [rcx+1*320*4+32], ymm9          #                        C[1][n+8:n+16]
    vmovaps     [rcx],            ymm6          #                        C[0][n:n+8]
    vmovaps     [rcx+32],         ymm7          #                        C[0][n+8:n+16]
    vmovaps     [rcx+3*320*4],    ymm12         #                        C[3][n:n+8]
    vmovaps     [rcx+3*320*4+32], ymm13         #                        C[3][n+8:n+16]
    vmovaps     [rcx+2*320*4],    ymm10         #                        C[2][n:n+8]
    vmovaps     [rcx+2*320*4+32], ymm11         #                        C[2][n+8:n+16]
    vmovaps     [rcx+4*320*4],    ymm14         #                        C[4][n:n+8]
    vmovaps     [rcx+4*320*4+32], ymm15         #                        C[4][n+8:n+16]
    jmp          rsi                            # RETURN (LINK REGISTER)
.Lsgemm_bu_eject_beta_zero:                     # REGISTERS ON ENTRY:
                                                #   RSI:  LinkRegister2
                                                #   RCX:  &C[ m ][ n ]
                                                #   YMM0: alpha
                                                # REGISTERS CLOBBERED ON EXIT:
                                                #   YMM5-YMM15
                                                # ************ BU EJECTION (beta=0) ************
    vmulps       ymm8,   ymm8,    ymm0          #   alpha * acc10 -->
    vmulps       ymm9,   ymm9,    ymm0          #   alpha * acc11 -->
    vmulps       ymm6,   ymm6,    ymm0          #   alpha * acc00 -->
    vmulps       ymm7,   ymm7,    ymm0          #   alpha * acc01 -->
    vmulps       ymm12,  ymm12,   ymm0          #   alpha * acc30 -->
    vmulps       ymm13,  ymm13,   ymm0          #   alpha * acc31 -->
    vmulps       ymm10,  ymm10,   ymm0          #   alpha * acc20 -->
    vmulps       ymm11,  ymm11,   ymm0          #   alpha * acc21 -->
    vmulps       ymm14,  ymm14,   ymm0          #   alpha * acc40 -->
    vmulps       ymm15,  ymm15,   ymm0          #   alpha * acc41 -->
    jmp .Lsgemm_bu_eject_alpha_one_beta_zero
.align 128





#
# SGEMM tester
#
#                        RDI,      RSI,      RDX,      XMM0,        XMM1
# extern void sgemm_test(float* A, float* B, float* C, float alpha, float beta);
#
.global sgemm_test
sgemm_test:
    pushq rbx
    pushq r10
    pushq r11
    pushq r12
    pushq r13
    vzeroupper                                  # Clear any split-AVX state
    vbroadcastss ymm0, xmm0                     # Splat alpha
    vbroadcastss ymm1, xmm1                     # Splat beta
                                                # BU PROLOGUE
                                                #   Matrices:
                                                #       float A[M=320][K=64] (K-stride:   1)
                                                #       float B[K=64][N=320] (K-stride: 320)
                                                # BU PROLOGUE REGISTERS:
                                                #   RDI: &A[m][0]
                                                #   RSI: &B[0][n]
                                                #   RDX: &C[m][n]
    mov   rax,  rdi                             # Install A-pointer
    mov   rbx,  rsi                             # Install B-pointer
    mov   rcx,  rdx                             # Install C-pointer
    mov   rdx,  +1*320*4                        # Place required constant for BU in RDX
    leaq  r8,  [rax+64*4]                       # Configure A-pointer stop
    leaq  rdi, [rip+.Lsgemm_bu_eject_alpha_one_beta_zero]
    leaq  rsi, [rip+1f]
    xor   r12,  r12
.align 64
0:
                                                # PREFETCH
    prefetchw  [rcx]                            #   Prefetch C[0][n:n+16] with write intent
    prefetchw  [rcx+1*320*4]                    #   Prefetch C[1][n:n+16] with write intent
    prefetchw  [rcx+2*320*4]                    #   Prefetch C[2][n:n+16] with write intent
    prefetchw  [rcx+3*320*4]                    #   Prefetch C[3][n:n+16] with write intent
    prefetchw  [rcx+4*320*4]                    #   Prefetch C[4][n:n+16] with write intent
    jmp .Lsgemm_bu_core_entry_clr               # EXECUTE BASIC UNIT
.align 64
1:                                              # REENTRY FROM BASIC UNIT
                                                #   (need to set:    RAX, RBX, RCX, R8)
                                                #   (link registers: RDI, RSI)
    mov     r10,  +1*64
    mov     r11,  -3*64
    incq    r12
    testq   r12,   3
    cmove   r10,   r11
    leaq    rbx,  [rbx+r10]                     # Advance B-slice pointer
    leaq    rcx,  [rcx+r10]                     # Advance C-slice pointer likewise
    mov     r10,   +5*64*4
    mov     r11,   +0*64*4
    cmovne  r10,   r11
    leaq    rax,  [rax+r10]                     # Advance A-slice pointer
    leaq    r8,   [r8 +r10]                     # Advance A-slice pointer stop
    mov     r10,  +5*320*4
    cmovne  r10,   r11
    leaq    rcx,  [rcx+r10]                     # Advance C-slice pointer likewise
    testq   r12,   255
    mov     r10,  -320* 64*4
    cmovne  r10,   r11
    leaq    rax,  [rax+r10]
    leaq    r8,   [r8 +r10]
    mov     r10,  -320*320*4+64*4
    cmovne  r10,   r11
    leaq    rcx,  [rcx+r10]
    mov     r10,  64*4
    cmovne  r10,   r11
    leaq    rbx,  [rbx+r10]
    cmpq    r12,  1280                          # Internal trip count
    jl      0b
    popq    r13
    popq    r12
    popq    r11
    popq    r10
    popq    rbx
    retq



.align  64
.global nabla_cpuid_x86
nabla_cpuid_x86:
    mov     r8d,  ecx
    mov     eax,  esi
    mov     ecx,  edx
    mov     rsi,  rbx
    cpuid
    test    rdi,  rdi
    je 0f
    mov    [rdi+0*4], eax
    mov    [rdi+1*4], ebx
    mov    [rdi+2*4], ecx
    mov    [rdi+3*4], edx
0:  cmp     r8d,  1
    cmove   eax,  ebx
    cmp     r8d,  2
    cmove   eax,  ecx
    cmp     r8d,  3
    cmove   eax,  edx
    mov     rbx,  rsi
    retq




#.align  64
#.global sgemm_frag
#sgemm_frag:
#    pushq rbp
#    pushq rbx
#    pushq r12
#    pushq r13
#    pushq r14
#    pushq r15
#    movd  [rsp-4], xmm0  # Save alpha in red zone
#    movd  [rsp-8], xmm1  # Save beta  in red zone
#    vzeroall             # Reinitialize entire vector register set.
#                         # Stack:
#                         #      +96     LDA
#                         #      +88     B
#                         #      +80     LDB
#                         #      +72     C
#                         #      +64     LDC
#                         #      +56     L
#                         #      +48     (return address)
#                         #      +40     (saved rbp)
#                         #      +32     (saved rbx)
#                         #      +24     (saved r12)
#                         #      +16     (saved r13)
#                         #      + 8     (saved r14)
#                         #     [rsp] => (saved r15)
#                         #      - 4     alpha
#                         #      - 8     beta
#    or    edi, 0x20
#    cmpd  edi, 'n'       # Check transA == 'n'
#    jnz .Lbadtrans
#    or    esi, 0x20
#    cmpd  esi, 'n'       # Check transB == 'n'
#    jnz .Lbadtrans
#    cmpq  rdx, 320       # Check M <= 320
#    ja  .Loversize
#    cmpq  rcx, 320       # Check N <= 320
#    ja  .Loversize
#    cmpq  r8,  64        # Check K <= 64
#    ja  .Loversize
#    test  r9,  r9        # Check A != NULL
#    jz  .Lnullptr
#    movq rax, [rsp+88]
#    test  rax, rax       # Check B != NULL
#    jz  .Lnullptr
#    movq rax, [rsp+72]
#    test  rax, rax       # Check C != NULL
#    jz  .Lnullptr
#    movq rax, [rsp+56]
#    test  rax, rax       # Check L != NULL
#    jz  .Lnullptr
#    
#    #
#    # Checks passed.
#    #
#    # We now stage A and B into L as follows:
#    #
#    #    L +         0:   C (up to 320 x 320, 400 KiB)
#    #    L + 320*320*4:   A (up to 320 x  64,  80 KiB)
#    #    L + 384*320*4:   B (up to  64 x 320,  80 KiB)
#    #
#    # The L1 cache is 32KB, 8-way set-associative with 64 sets and a cacheline
#    # size of 64B. When striding by 320 floats (1280 bytes, 5x2x2xCL), only
#    # one-quarter of the sets are used.
#    #
#    leaq  rbx, [r8-1]
#    or    rbx, 7
#    addq  rbx, 8
#    
#    
#    xor   eax, eax       # Exit successful
#.Lsgemm_frag_exit:
#    popq  r15
#    popq  r14
#    popq  r13
#    popq  r12
#    popq  rbx
#    popq  rbp
#    ret
#.align 16
#    .Lbadtrans:
#    .Loversize:
#    .Lnullptr:
#    mov   eax, 1         # Set error code
#    jmp   .Lsgemm_frag_exit
#
#
#
#.align 64
#sgemm_nn_core:
#    pushq rbp
#    pushq rbx
#    pushq r12
#    pushq r13
#    pushq r14
#    pushq r15
#    movd  [rsp-4], xmm0  # Save alpha in red zone
#    movd  [rsp-8], xmm1  # Save beta  in red zone
#                         # Stack:
#                         #      +96     LDA
#                         #      +88     B
#                         #      +80     LDB
#                         #      +72     C
#                         #      +64     LDC
#                         #      +56     L
#                         #      +48     (return address)
#                         #      +40     (saved rbp)
#                         #      +32     (saved rbx)
#                         #      +24     (saved r12)
#                         #      +16     (saved r13)
#                         #      + 8     (saved r14)
#                         #     [rsp] => (saved r15)
#                         #      - 4     alpha
#                         #      - 8     beta
#                         # Registers:
#                         #      r15:    (return address)
#                         #      r14:    K << 20 | M << 11 | N << 2 | transB << 1 | transA
#                         #      r13:    beta << 32 | alpha
#                         #      r12:    
#    vzeroall                                    #   Reinitialize entire vector register set.
