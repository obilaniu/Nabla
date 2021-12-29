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


##
##                   SYSTEM V X86-64 CALLING CONVENTION
##
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
##
## If the callee wishes to use registers RBX, RSP, RBP, and R12–R15, it must
## restore their original values before returning control to the caller. All other
## registers must be saved by the caller if it wishes to preserve their values.
##
## For leaf-node functions (functions which do not call any other function(s)), a
## 128-byte space is stored just beneath the stack pointer of the function. The
## space is called the red zone. This zone will not be clobbered by any signal or
## interrupt handlers. Compilers can thus utilize this zone to save local variables.
## Compilers may omit some instructions at the starting of the function (adjustment
## of RSP, RBP) by utilizing this zone. However, other functions may clobber this
## zone. Therefore, this zone should only be used for leaf-node functions. gcc and
## clang offer the -mno-red-zone flag to disable red-zone optimizations.
##
## If the callee is a variadic function, then the number of floating point
## arguments passed to the function in vector registers must be provided by the
## caller in the AL register.
##
## Unlike the Microsoft calling convention, a shadow space is not provided; on
## function entry, the return address is adjacent to the seventh integer argument
## on the stack.
##


.intel_syntax noprefix
.text

#define K1     0b0000010000100001000100010000
#define KMmask 0b0111100000111110000000000000
#define KNmask 0b0000011111000001111000000000
#define KKmask 0b0000000000000000000111100000
#define KMmixm (25<<0|5<<10)
#define KNmixm ((5<<0|1<<9)<<5)
#define KMshft 23
#define KNshft 19


#
# Nabla CPUID Access Function
#
#      uint32_t nabla_cpuid_x86(uint32_t buf[4], uint32_t ECX, uint32_t EAX, int select)
#
# Executes CPUID with register values ECX:EAX and writes result into buf if non-NULL.
# The return value is one selected register from CPUID's output:
#     EAX=0    EBX=1    ECX=2    EDX=3
#
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


#
# SGEMM Modulo-Decrement Test Function
#
# Coordinate System:
#     Name:                 Mb : Nb : Ma : Na : k8 : 00000
#     Max:                  15    4    4    4    7   0
#     Bits:                  5    5    5    4    4   5
#     Offset:               23   18   13    9    5   0
#
.global sgemm_mod_count
sgemm_mod_count:
    mov     edi,   0b11011110111011100000000
    mov     edx,   (15<<23|4<<18|4<<13|4<<9|7<<5)|16
    xor     eax,   eax
0:
    # Independent count of iterations
    inc     eax
    
    # Modulo-bump
    sub     edx,   32
    mov     ecx,   edx
    and     ecx,   0b10000100001000100010000
    lzcnt   ecx,   ecx
    mov     esi,   edi
    shl     esi,   cl
    shr     esi,   cl
    xor     edx,   esi
    
    # Compare and exit.
    test    edx,   edx
    jge     0b
    ret


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
#                        RDI,      RSI,      RDX,      RCX,    R8,          R9,                   XMM0,        XMM1
# extern void sgemm_test(float* A, float* B, float* C, int K0, int counter, int prefetch_counter, float alpha, float beta);
#
.global sgemm_test
sgemm_test:
    pushq        rbx
    pushq        r10
    pushq        r11
    pushq        r12
    pushq        r13
    pushq        r14
    pushq        r15
    vzeroupper                                           # Clear any split-AVX state
    vbroadcastss ymm0,   xmm0                            # Splat alpha
    vbroadcastss ymm1,   xmm1                            # Splat beta
    and          r8d,   -512                             # Ensure correctness of counter
    or           r8d,    16                              # Ensure correctness of counter
    or           r9d,    16                              # Ensure correctness of prefetch counter
    #or           ecx,    16                              # Ensure correctness of K0 control constant
    mov          r12d,   ecx                             # Install R12 = K0 control constant
    not          ecx
    and          ecx,    0b011100000
    or           r8d,    ecx                             # Copy ~k from K0 into counter
    mov          r13,    rdi                             # Install R13 = A-base-pointer
    mov          r14,    rsi                             # Install R14 = B-base-pointer
    mov          r15,    rdx                             # Install R15 = C-base-pointer
    
    mov          eax,    r8d                             # = CURRENT COUNTER
    and          eax,            KMmask
    imul         eax,    eax,    KMmixm
    shr          eax,            KMshft                  # = m
    shl          eax,    8                               # = m*64*sizeof(float)
    addq         rax,    r13                             # = &A[m,0]
    
    mov          ebx,    r8d                             # = CURRENT COUNTER
    and          ebx,            KNmask
    imul         ebx,    ebx,    KNmixm
    shr          ebx,            KNshft                  # = n
    shl          ebx,    2                               # = n*sizeof(float)
    addq         rbx,    r14                             # = &B[0,n]
    
    leaq         r10,   [rip+0f]                         # Install return pointer
    vxorps       ymm6,   ymm6,   ymm6
    vxorps       ymm7,   ymm7,   ymm7
    vxorps       ymm8,   ymm8,   ymm8
    vxorps       ymm9,   ymm9,   ymm9
    vxorps       ymm10,  ymm10,  ymm10
    vxorps       ymm11,  ymm11,  ymm11
    vxorps       ymm12,  ymm12,  ymm12
    vxorps       ymm13,  ymm13,  ymm13
    vxorps       ymm14,  ymm14,  ymm14
    vxorps       ymm15,  ymm15,  ymm15
    sfence
    jmp .Lsgemm_zen2_bu_core_8x_unroll_accumulate        # EXECUTE
0:  sfence
    vzeroall
    popq         r15
    popq         r14
    popq         r13
    popq         r12
    popq         r11
    popq         r10
    popq         rbx
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


#
# SGEMM, Idea 3
#
#     A[M=400][K= 64]
#     B[K= 64][N=400]
#     C[M=400][N=400]
#
# 8x (
#      1x PREFETCHT0 (B)
#      7x LD
#     10x FMA
# )
# 5x PREFETCHT0 (A)
# 5x PREFETCHW  (C)
# 1 TEST+BR
#
# Blocks:          M=5, N=16
# Time:            40cc/iteration
# Memory accesses: 8 full cachelines of B
#                  5 half cachelines of A
#                  5 full cachelines of C
#
# Jump Schedule:
#  1.  5x:           N +=  16
#  2.  5x:  M +=  5, N -=  80
#  3.  5x:  M -= 25, N +=  80
#  4. 16x:  M += 25, N -= 400


#
# SGEMM Basic Unit Kernel, 8x unrolled.
#
# The SGEMM basic unit is a matrix multiplication of C(5,16) += A(5xK) x B(Kx16)
# sliced out of C(400x400) += A(400xK) x B(Kx400) matrix tiles. There are 2000
# basic units per tile operation. K is divisible by the unroll factor 8 such
# that 8 <= K <= 64.
#
# An SGEMM basic unit executes K sets of 10 FMAs.
#
.align 4096
.globl sgemm_zen2_bu_core_8x_unroll_accumulate
sgemm_zen2_bu_core_8x_unroll_accumulate:
.Lsgemm_zen2_bu_core_8x_unroll_accumulate:      #************ BU CORE 8X UNROLL ************
    #
    #   MAIN ARITHMETIC BODY
    #
    # K=0
    vmovaps      ymm5,  [rbx+0*400*4+32]        #     Load B[k+0, n+8:n+16]
    vmovaps      ymm4,  [rbx+0*400*4]           #     Load B[k+0, n  :n+ 8]
    vbroadcastss ymm3,  [rax+0*4+1*64*4]        #     Load A[m+1, k+0]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k+0] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k+0] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4]               #     Load A[m+0, k+0]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k+0] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k+0] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+3*64*4]        #     Load A[m+3, k+0]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k+0] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k+0] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+2*64*4]        #     Load A[m+2, k+0]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k+0] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k+0] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+4*64*4]        #     Load A[m+4, k+0]
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k+0] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k+0] * B[k,n+8:n+16]
.Lsgemm_zen2_bu_core_8x_unroll_skip_first_iter:
    # K=5
    vmovaps      ymm4,  [rbx+5*400*4]           #     Load B[k+5, n  :n+ 8]
    vmovaps      ymm5,  [rbx+5*400*4+32]        #     Load B[k+5, n+8:n+16]
    vbroadcastss ymm3,  [rax+5*4+1*64*4]        #     Load A[m+1, k+5]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k+5] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k+5] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+5*4]               #     Load A[m+0, k+5]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k+5] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k+5] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+5*4+3*64*4]        #     Load A[m+3, k+5]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k+5] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k+5] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+5*4+2*64*4]        #     Load A[m+2, k+5]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k+5] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k+5] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+5*4+4*64*4]        #     Load A[m+4, k+5]
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k+5] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k+5] * B[k,n+8:n+16]
    # K=2
    vmovaps      ymm5,  [rbx+2*400*4+32]        #     Load B[k+2, n+8:n+16]
    vmovaps      ymm4,  [rbx+2*400*4]           #     Load B[k+2, n  :n+ 8]
    vbroadcastss ymm3,  [rax+2*4+1*64*4]        #     Load A[m+1, k+2]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k+2] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k+2] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*4]               #     Load A[m+0, k+2]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k+2] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k+2] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*4+3*64*4]        #     Load A[m+3, k+2]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k+2] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k+2] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*4+2*64*4]        #     Load A[m+2, k+2]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k+2] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k+2] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*4+4*64*4]        #     Load A[m+4, k+2]
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k+2] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k+2] * B[k,n+8:n+16]
    # K=7
    vmovaps      ymm4,  [rbx+7*400*4]           #     Load B[k+7, n  :n+ 8]
    vmovaps      ymm5,  [rbx+7*400*4+32]        #     Load B[k+7, n+8:n+16]
    vbroadcastss ymm3,  [rax+7*4+1*64*4]        #     Load A[m+1, k+7]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k+7] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k+7] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+7*4]               #     Load A[m+0, k+7]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k+7] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k+7] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+7*4+3*64*4]        #     Load A[m+3, k+7]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k+7] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k+7] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+7*4+2*64*4]        #     Load A[m+2, k+7]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k+7] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k+7] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+7*4+4*64*4]        #     Load A[m+4, k+7]
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k+7] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k+7] * B[k,n+8:n+16]
    # K=1
    vmovaps      ymm5,  [rbx+1*400*4+32]        #     Load B[k+1, n+8:n+16]
    vmovaps      ymm4,  [rbx+1*400*4]           #     Load B[k+1, n  :n+ 8]
    vbroadcastss ymm3,  [rax+1*4+1*64*4]        #     Load A[m+1, k+1]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k+1] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k+1] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+1*4]               #     Load A[m+0, k+1]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k+1] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k+1] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+1*4+3*64*4]        #     Load A[m+3, k+1]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k+1] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k+1] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+1*4+2*64*4]        #     Load A[m+2, k+1]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k+1] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k+1] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+1*4+4*64*4]        #     Load A[m+4, k+1]
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k+1] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k+1] * B[k,n+8:n+16]
    # K=6
    vmovaps      ymm4,  [rbx+6*400*4]           #     Load B[k+6, n  :n+ 8]
    vmovaps      ymm5,  [rbx+6*400*4+32]        #     Load B[k+6, n+8:n+16]
    vbroadcastss ymm3,  [rax+6*4+1*64*4]        #     Load A[m+1, k+6]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k+6] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k+6] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+6*4]               #     Load A[m+0, k+6]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k+6] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k+6] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+6*4+3*64*4]        #     Load A[m+3, k+6]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k+6] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k+6] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+6*4+2*64*4]        #     Load A[m+2, k+6]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k+6] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k+6] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+6*4+4*64*4]        #     Load A[m+4, k+6]
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k+6] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k+6] * B[k,n+8:n+16]
    # K=3
    vmovaps      ymm5,  [rbx+3*400*4+32]        #     Load B[k+3, n+8:n+16]
    vmovaps      ymm4,  [rbx+3*400*4]           #     Load B[k+3, n  :n+ 8]
    vbroadcastss ymm3,  [rax+3*4+1*64*4]        #     Load A[m+1, k+3]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k+3] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k+3] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+3*4]               #     Load A[m+0, k+3]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k+3] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k+3] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+3*4+3*64*4]        #     Load A[m+3, k+3]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k+3] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k+3] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+3*4+2*64*4]        #     Load A[m+2, k+3]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k+3] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k+3] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+3*4+4*64*4]        #     Load A[m+4, k+3]
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k+3] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k+3] * B[k,n+8:n+16]
    # K=4
    vmovaps      ymm4,  [rbx+4*400*4]           #     Load B[k+4, n  :n+ 8]
    vmovaps      ymm5,  [rbx+4*400*4+32]        #     Load B[k+4, n+8:n+16]
    vbroadcastss ymm3,  [rax+4*4+1*64*4]        #     Load A[m+1, k+4]
    vfmadd231ps  ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k+4] * B[k,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k+4] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+4*4]               #     Load A[m+0, k+4]
    vfmadd231ps  ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k+4] * B[k,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k+4] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+4*4+3*64*4]        #     Load A[m+3, k+4]
    vfmadd231ps  ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k+4] * B[k,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k+4] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+4*4+2*64*4]        #     Load A[m+2, k+4]
    vfmadd231ps  ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k+4] * B[k,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k+4] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+4*4+4*64*4]        #     Load A[m+4, k+4]
    vfmadd231ps  ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k+4] * B[k,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k+4] * B[k,n+8:n+16]
    
    #
    #   POINTER A & B BUMPS
    #
    addq         rax,    8*4                    #     A[m, k+=8]
    addq         rbx,    8*400*4                #     B[k+=8, n]

#if 1
    #
    #   PREFETCH MODULO COUNTER (R9) DECREMENT &
    #   PREFETCH ADDRESS COMPUTATION &
    #   PREFETCH DATA
    #
    # I: R9, R12, R13, R14, R15
    # O: R9
    # Registers available:   RCX, RDX, RDI, RSI, R10, R11
    # Registers unavailable: RAX, RBX, R8
    #
    # A-prefetch-pointer (float A[M=400][K= 64])
    # B-prefetch-pointer (float B[K= 64][N=400])
    # C-prefetch-pointer (float C[M=400][N=400])
    #
    # Coordinate System:
    #     Name:                 mb : nb : ma : na : k8 : 10000
    #     Max:                  15    4    4    4    7   16
    #     Bits:                  5    5    5    4    4   5
    #     Offset:               23   18   13    9    5   0
    #
    sub          r9d,    32                     # [PREFETCH COUNTER]
    mov          ecx,    r9d                    # [PREFETCH COUNTER]
    and          ecx,    K1                     # [PREFETCH COUNTER]
    lzcnt        ecx,    ecx                    # [PREFETCH COUNTER]
    mov          esi,    r12d                   # [PREFETCH COUNTER]
    shl          esi,    cl                     # [PREFETCH COUNTER]
    shr          esi,    cl                     # [PREFETCH COUNTER]
    xor          r9d,    esi                    # [PREFETCH COUNTER]
    
    mov          ecx,    r9d                    # = PREFETCH COUNTER
    and          ecx,           KMmask
    imul         ecx,    ecx,   KMmixm
    shr          ecx,           KMshft          # = m
    imul         edx,    ecx,   400*4           # = m*400*sizeof(float)
    shl          ecx,    8                      # = m* 64*sizeof(float)
    addq         rdx,    r15                    # = &C[m,0]
    
    mov          esi,    r12d                   # =  K0 CONSTANT
    neg          esi                            # = -K0
    sub          esi,    r9d                    # = -K0 - PREFETCH COUNTER
    and          esi,           KKmask          # = k*sizeof(float)
    imul         edi,    esi,   400             # = k*400*sizeof(float)
    add          esi,    ecx                    # = (m*64 + k)*sizeof(float)
    add          rdi,    r14                    # = &B[k,0]
    
    prefetcht0  [r13 + rsi + 1*64*4]            # Prefetch A[m+1,k:k+8]
    prefetcht0  [r13 + rsi + 0*64*4]            # Prefetch A[m,  k:k+8]
    prefetcht0  [r13 + rsi + 3*64*4]            # Prefetch A[m+3,k:k+8]
    prefetcht0  [r13 + rsi + 2*64*4]            # Prefetch A[m+2,k:k+8]
    prefetcht0  [r13 + rsi + 4*64*4]            # Prefetch A[m+4,k:k+8]
    
    mov          ecx,    r9d                    # = PREFETCH COUNTER
    and          ecx,           KNmask
    imul         ecx,    ecx,   KNmixm
    shr          ecx,           KNshft          # = n
    
    prefetchw   [rdx + rcx*4 + 1*400*4]         # Prefetch C[m+1,n:n+16]
    prefetchw   [rdx + rcx*4 + 0*400*4]         # Prefetch C[m+0,n:n+16]
    prefetchw   [rdx + rcx*4 + 3*400*4]         # Prefetch C[m+3,n:n+16]
    prefetchw   [rdx + rcx*4 + 2*400*4]         # Prefetch C[m+2,n:n+16]
    prefetchw   [rdx + rcx*4 + 4*400*4]         # Prefetch C[m+4,n:n+16]
    prefetcht0  [rdi + rcx*4 + 0*400*4]         # Prefetch B[k+0,n:n+16]
    prefetcht0  [rdi + rcx*4 + 5*400*4]         # Prefetch B[k+5,n:n+16]
    prefetcht0  [rdi + rcx*4 + 2*400*4]         # Prefetch B[k+2,n:n+16]
    prefetcht0  [rdi + rcx*4 + 7*400*4]         # Prefetch B[k+7,n:n+16]
    prefetcht0  [rdi + rcx*4 + 1*400*4]         # Prefetch B[k+1,n:n+16]
    prefetcht0  [rdi + rcx*4 + 6*400*4]         # Prefetch B[k+6,n:n+16]
    prefetcht0  [rdi + rcx*4 + 3*400*4]         # Prefetch B[k+3,n:n+16]
    prefetcht0  [rdi + rcx*4 + 4*400*4]         # Prefetch B[k+4,n:n+16]
#endif
    
    #
    #   CURRENT POINTER C COMPUTATION &
    #   CURRENT MODULO COUNTER (R8) DECREMENT &
    #   CURRENT/NEXT POINTER A & B COMPUTATION
    #
    # I: R8, R12, R13, R14, R15
    # O: R8, RCX, RDX, RDI, RSI
    # Registers available:   RCX, RDX, RDI, RSI, R10, R11
    # Registers unavailable: RAX, RBX, R9
    #
    # A-current-pointer (float A[M=400][K= 64])
    # B-current-pointer (float B[K= 64][N=400])
    # C-current-pointer (float C[M=400][N=400])
    #
    # Coordinate System:
    #     Name:                 mb : nb : ma : na : k8 : 10000
    #     Max:                  15    4    4    4    7   16
    #     Bits:                  5    5    5    4    4   5
    #     Offset:               23   18   13    9    5   0
    #
    mov          edx,    r8d                    # = CURRENT COUNTER
    and          edx,           KMmask
    imul         edx,    edx,   KMmixm
    shr          edx,           KMshft          # = m
    imul         edx,    edx,   400*4           # = m*400*sizeof(float)
    addq         rdx,    r15                    # = &C[m,0]
    
    mov          ecx,    r8d                    # = CURRENT COUNTER
    and          ecx,           KNmask
    imul         ecx,    ecx,   KNmixm
    shr          ecx,           KNshft          # = n
    leaq         rdx,   [rdx+rcx*4]             # = &C[m,n]
    
    mov          edi,    r8d                    # [CURRENT COUNTER SAVE]
    sub          r8d,    32                     # [CURRENT COUNTER]
    mov          ecx,    r8d                    # [CURRENT COUNTER]
    and          ecx,    K1                     # [CURRENT COUNTER]
    lzcnt        ecx,    ecx                    # [CURRENT COUNTER]
    mov          esi,    r12d                   # [CURRENT COUNTER]
    shl          esi,    cl                     # [CURRENT COUNTER]
    shr          esi,    cl                     # [CURRENT COUNTER]
    xor          r8d,    esi                    # [CURRENT COUNTER BECOMES NEXT]
    
    mov          esi,    r8d                    # = NEXT COUNTER
    and          esi,           KMmask
    imul         esi,    esi,   KMmixm
    shr          esi,           KMshft          # = m
    shl          esi,    8                      # = m*64*sizeof(float)
    
    mov          ecx,    r8d                    # = NEXT COUNTER
    and          ecx,           KNmask
    imul         ecx,    ecx,   KNmixm
    shr          ecx,           KNshft          # = n
    shl          ecx,    2                      # = n*sizeof(float)
    
    #
    # Loop exit test
    #
    test         edi,    0b011100000            # Exit if old_k == 0
    jne .Lsgemm_zen2_bu_core_8x_unroll_accumulate
    leaq         rax,   [r13+rsi]               # Install A-pointer
    leaq         rbx,   [r14+rcx]               # Install B-pointer
    
    #
    # Eject accumulators and reload.
    #
    vmovaps     [rdx+1*320*4],    ymm8          # C[1][n:n+8]
    vmovaps     [rdx+1*320*4+32], ymm9          # C[1][n+8:n+16]
    vmovaps     [rdx],            ymm6          # C[0][n:n+8]
    vmovaps     [rdx+32],         ymm7          # C[0][n+8:n+16]
    vmovaps     [rdx+3*320*4],    ymm12         # C[3][n:n+8]
    vmovaps     [rdx+3*320*4+32], ymm13         # C[3][n+8:n+16]
    vmovaps     [rdx+2*320*4],    ymm10         # C[2][n:n+8]
    vmovaps     [rdx+2*320*4+32], ymm11         # C[2][n+8:n+16]
    vmovaps     [rdx+4*320*4],    ymm14         # C[4][n:n+8]
    vmovaps     [rdx+4*320*4+32], ymm15         # C[4][n+8:n+16]
    
    vmovaps      ymm4,  [rbx+0*400*4]           #     Load B[k+0, n  :n+ 8]
    vmovaps      ymm5,  [rbx+0*400*4+32]        #     Load B[k+0, n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+1*64*4]        #     Load A[m+1, k+0]
    vmulps       ymm8,   ymm3,  ymm4            #      => acc10 += A[1,k+0] * B[k,n:n+8]
    vmulps       ymm9,   ymm3,  ymm5            #      => acc11 += A[1,k+0] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4]               #     Load A[m+0, k+0]
    vmulps       ymm6,   ymm3,  ymm4            #      => acc00 += A[0,k+0] * B[k,n:n+8]
    vmulps       ymm7,   ymm3,  ymm5            #      => acc01 += A[0,k+0] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+3*64*4]        #     Load A[m+3, k+0]
    vmulps       ymm12,  ymm3,  ymm4            #      => acc30 += A[3,k+0] * B[k,n:n+8]
    vmulps       ymm13,  ymm3,  ymm5            #      => acc31 += A[3,k+0] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+2*64*4]        #     Load A[m+2, k+0]
    vmulps       ymm10,  ymm3,  ymm4            #      => acc20 += A[2,k+0] * B[k,n:n+8]
    vmulps       ymm11,  ymm3,  ymm5            #      => acc21 += A[2,k+0] * B[k,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+4*64*4]        #     Load A[m+4, k+0]
    vmulps       ymm14,  ymm3,  ymm4            #      => acc40 += A[4,k+0] * B[k,n:n+8]
    vmulps       ymm15,  ymm3,  ymm5            #      => acc41 += A[4,k+0] * B[k,n+8:n+16]
    
    test         r8d,    r8d                    # Test if countdown register >= 0
    jge .Lsgemm_zen2_bu_core_8x_unroll_skip_first_iter
    jmp          r10
