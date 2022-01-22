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
.section .rodata.str1.1, "aMS", @progbits, 1

# Microarchitecture Strings
.Luarch_unknown:       .asciz "(unknown)"
.Luarch_unknown_intel: .asciz "(unknown Intel)"
.Luarch_unknown_amd:   .asciz "(unknown AMD)"
.Luarch_zen:           .asciz "Zen"       # Rel. Mar 2017; 14nm;  EPYC Naples, Raven Ridge, Raven Ridge
.Luarch_zenp:          .asciz "Zen+"      # Rel. Apr 2018; 12nm;  Pinnacle Ridge, Colfax
.Luarch_zen2:          .asciz "Zen 2"     # Rel. Jul 2019;  7nm;  EPYC Rome,  Matisse, Renoir, Lucienne, Castle Peak
.Luarch_zen3:          .asciz "Zen 3"     # Rel. Nov 2020;  7nm+; EPYC Milan, Vermeer, Cezanne, Genesis Peak
.Luarch_zen3p:         .asciz "Zen 3+"    # Ann. Jan 2022;  6nm;  Rembrandt
.Luarch_zen4:          .asciz "Zen 4"     # Ann. Nov 2021;  5nm;  EPYC Genoa, Raphael, Phoenix
.Luarch_zen4c:         .asciz "Zen 4c"    # Ann. Nov 2021;  5nm;  EPYC Bergamo
.Luarch_zen5:          .asciz "Zen 5"     # Future (2023);  3nm;  EPYC Turin, Da Vinci, Granite Ridge, Strix Point

#
# Package Strings
#
# On AMD, the package type is reported in CPUID.80000001h.EBX[31:28]
#
.Lpackage_unknown:     .asciz "(unknown)" # Xh;  Unknown package
.Lpackage_fp5:         .asciz "FP5"       # 0h;  Mobile  Zen   / Zen+
.Lpackage_fp6:         .asciz "FP6"       # 0h;  Mobile  Zen 2 / Zen 3
.Lpackage_am4:         .asciz "AM4"       # 2h;  Desktop Zen/Zen+/Zen 2/Zen 3
.Lpackage_sp3:         .asciz "SP3"       # 4h;  EPYC Zen/Zen 2/Zen 3 Naples/Rome/Milan
.Lpackage_sp3r2:       .asciz "SP3r2"     # 7h;  a.k.a. TR4;   Zen / Zen+ Threadripper
.Lpackage_sp3r3:       .asciz "SP3r3"     # 7h;  a.k.a. sTRX4; Zen 2 Castle Peak Threadripper
.Lpackage_sp3r4:       .asciz "SP3r4"     # 4h;  a.k.a. sWRX8; Zen 2 Castle Peak Threadripper PRO
                                          #                    Zen 3 Chagall     Threadripper PRO
.Lpackage_sp4:         .asciz "SP4"       # Xh;  Embedded EPYC Zen; Snowy Owl
.Lpackage_sp4r2:       .asciz "SP4r2"     # Xh;  Embedded EPYC Zen; Snowy Owl
.Lpackage_fp7:         .asciz "FP7"       # Xh;  Mobile  Zen 3+ Rembrandt
.Lpackage_fp7r2:       .asciz "FP7r2"     # Xh;  Mobile  Zen 3+ Rembrandt
.Lpackage_fp8:         .asciz "FP8"       # Xh;  Mobile  Zen 4  Phoenix
.Lpackage_am5:         .asciz "AM5"       # Xh;  Desktop Zen 4  Raphael
.Lpackage_sp5:         .asciz "SP5"       # Xh;  EPYC Zen 4 Genoa?/Bergamo?

# Codename Strings
.Lcodename_unknown:            .asciz "(unknown)"         # Unknown
.Lcodename_unknown_intel:      .asciz "(unknown Intel)"   # Unknown Intel
.Lcodename_unknown_amd:        .asciz "(unknown AMD)"     # Unknown AMD
#   AMD
#     Family 17h
#       Zen,   14nm
.Lcodename_snowy_owl:          .asciz "Snowy Owl"         # Family 17h Model 01h;  Package SP4/SP4r2;  EPYC Embedded 3000-series, 4C/4T-16C/32T
.Lcodename_summit_ridge:       .asciz "Summit Ridge"      # Family 17h Model 01h;  Package AM4;        Ryzen (PRO?) 1000?-series, 4C/4T-8C/16T
.Lcodename_whitehaven:         .asciz "Whitehaven"        # Family 17h Model 01h;  Package SP3r2;      Ryzen Threadripper, 8C/16T-16C/32T
.Lcodename_naples:             .asciz "Naples"            # Family 17h Model 01h;  Package SP3;        EPYC 7xx1(P)-series, 8C/16T-32C/64T
.Lcodename_raven_ridge:        .asciz "Raven Ridge"       # Family 17h Model 11h;  Package AM4/FP5;    Ryzen (PRO?) 2x00?? -series, (PRO?) 2x0?? -series 2C/4T-4C/8T
.Lcodename_great_horned_owl:   .asciz "Great Horned Owl"  # Family 17h Model 11h;  Package FP5;        Ryzen Embedded V1000-series, 4C/8T except V1202B 2C/4T
.Lcodename_banded_kestrel:     .asciz "Banded Kestrel"    # Family 17h Model 18h;  Package FP5;        Ryzen Embedded R1000-series, 2C/4T
.Lcodename_dali:               .asciz "Dali"              # Family 17h Model 20h;  Package FP5;        Ryzen 3x50U-series, 2C/4T + Radeon Vega 2/3
.Lcodename_fireflight:         .asciz "FireFlight"        # Family 17h Model 50h;  Semi-custom AMD design for Subor Z+ gaming console (cancelled?)
#       Zen+,  12nm
.Lcodename_pinnacle_ridge:     .asciz "Pinnacle Ridge"    # Family 17h Model 08h;  Package AM4;        Ryzen (PRO?) 2x00?-series, 4C/4T-8C/16T
.Lcodename_colfax:             .asciz "Colfax"            # Family 17h Model 08h;  Package SP3r2;      Ryzen Threadripper 29x0(X|WX)-series (2nd-generation), 12C/24T-32C/64T
.Lcodename_picasso:            .asciz "Picasso"           # Family 17h Model 18h;  Package FP5;        Ryzen (PRO?) 3xx0?? -series, 4C/4T-8C/16T
#       Zen 2,  7nm  TSMC FinFET
.Lcodename_castle_peak:        .asciz "Castle Peak"       # Family 17h Model 31h;  Package SP3r3;      Ryzen Threadripper     39x0X-series (3rd-generation), 24C/48T-64C/128T
                                                          #                        Package SP3r4;      Ryzen Threadripper PRO 39x5X-series (3rd-generation), 12C/24T-64C/128T
.Lcodename_rome:               .asciz "Rome"              # Family 17h Model 31h;  Package SP3;        EPYC 7xx2(P)-series, 8C/16T-64C/128T
.Lcodename_xbox_series_x:      .asciz "Xbox Series X"     # Family 17h Model 47h;  Xbox Series X, 8C/16T.
                                                          #                        Faulty iGPU chips reissued as "AMD 4700S 8-Core Desktop Processor Kit"
                                                          #                        PkgType=0, 8BitBrandId=0, BrandId=0, LogicalProcessorCount=16 & ThreadsPerCore+1=2.
                                                          #                        https://twitter.com/InstLatX64/status/1384441961533292545/photo/1
.Lcodename_grey_hawk:          .asciz "Grey Hawk"         # Family 17h Model 60h;  Package FP6;        Ryzen Embedded V2000-series, 6C/12T or 8C/16T
.Lcodename_renoir:             .asciz "Renoir"            # Family 17h Model 60h;  Package FP6;        Ryzen (PRO?) 4x00?? -series, 4C/4T-8C/16T
.Lcodename_lucienne:           .asciz "Lucienne"          # Family 17h Model 68h;  Package FP6;        Ryzen 5x00U-series, 4C/8T-8C/16T
.Lcodename_matisse:            .asciz "Matisse"           # Family 17h Model 71h;  Package AM4;        Ryzen (PRO?) 3xx0?? -series, 6C/6T-16C/32T
.Lcodename_van_gogh:           .asciz "Van Gogh"          # Family 17h Model 90h; (Future; Rumour; 4C/8T?)
.Lcodename_mero:               .asciz "Mero"              # Family 17h Model 98h; (Future; Rumour; Mobile?)
#     Family 18h
#       Zen,   14nm
.Lcodename_dhyana:             .asciz "Dhyana"            # Family 18h Model 00h;  AMD-Hygon collaboration
#     Family 19h
#       Zen 3,  7nm+ TSMC FinFET
.Lcodename_genesis_peak:       .asciz "Genesis Peak"      # Family 19h Model XXh;  Package SP3r3;      Ryzen Threadripper 59x0?? -series (5th-generation)?
.Lcodename_milan:              .asciz "Milan"             # Family 19h Model 01h;  Package SP3;        EPYC 7xx3(P)-series, 8C/16T-64C/128T. Engineering Sample Model 00h also seen.
.Lcodename_milan_x:            .asciz "Milan-X"           # Family 19h Model 01h,
                                                          #         Stepping  B2;  Package SP3;        EPYC 7xx3(P)-series with 3D cache, 8C/16T-64C/128T.
.Lcodename_chagall:            .asciz "Chagall"           # Family 19h Model 08h;  Package SP3r4;      Ryzen Threadripper PRO 59x5WX-series (5th-generation?), 12C/24T-64C/128T
.Lcodename_vermeer:            .asciz "Vermeer"           # Family 19h Model 21h;  Package AM4;        Ryzen 5xx0(X?)-series Desktop
                                                          #            Model 22h also seen?
.Lcodename_trento:             .asciz "Trento"            # Family 19h Model 30h;  Package SP3;        EPYC 7xx3??? -series, used in Frontier supercomputer
.Lcodename_cezanne:            .asciz "Cezanne"           # Family 19h Model 51h;  Package AM4/FP6;    Ryzen 5000-series
                                                          #            Model 50h also seen?
#       Zen 3+, 6nm  TSMC FinFET
.Lcodename_rembrandt:          .asciz "Rembrandt"         # Family 19h Model 40h;  Package FP7/FP7r2;  Ryzen 6000-series Mobile
.Lcodename_embeddedv3000:      .asciz "?"                 # Family 19h Model XXh;  Package FP7r2;      Ryzen Embedded V3000-series, 6C/12T or 8C/16T
#       Zen 4,  5nm
.Lcodename_genoa:              .asciz "Genoa"             # Family 19h Model 10h;  Package SP5;        EPYC 7xx4??? -series, up to 96C/192T
.Lcodename_raphael:            .asciz "Raphael"           # Family 19h Model 60h;  Package AM5;        Ryzen 7000-series Desktop?
.Lcodename_phoenix:            .asciz "Phoenix"           # Family 19h Model 70h;  Package FP8;        Ryzen 7000-series Mobile?
#       Zen 4c, 5nm
.Lcodename_bergamo:            .asciz "Bergamo"           # Family 19h Model A0h;  Package SP5;        EPYC 7xx4??? -series, up to 128C/256T?
#       Zen 5,  3nm
.Lcodename_strix_point:        .asciz "Strix Point"       # Family 19h Model 18h;  Package FP8?;       Ryzen 8000-series Mobile?
.Lcodename_granite_ridge:      .asciz "Granite Ridge"     # Family 19h Model XXh;  Package AM5?;       Ryzen 8000-series Desktop?
.Lcodename_da_vinci:           .asciz "Da Vinci"          # Family 19h Model XXh;  Package SP5r2?;     Ryzen Threadripper?
.Lcodename_turin:              .asciz "Turin"             # Family 19h Model XXh;  Package SP5?;       EPYC 7xx5??? -series, up to 256C/512T?




.text
.align 64

#define K1          0b00010000010100010
#define KMmask      0b00001111100000000
#define KNmask      0b11100000000000000
#define KPmask      0b00000000001000000
#define KKmask      0b00000000000011100
#define KKMNPmask   (KMmask|KNmask|KPmask|KKmask)
#define KMshft      1
#define KNshft      7
#define KPshft      0
#define KKshft      4
#define FMS(f,m,s)  ((0x##f & 0xFF)<<12 | (0x##m & 0xFF)<<4 | (0x##s & 0xF))


#
# Nabla Convert uint32_t to full binary string of length 33.
#
#     char* nabla_uint32tobin(char buf[33], uint32_t v)
#
# Returns buf. Handy to print x2APIC ID.
#
.globl nabla_uint32tobin
nabla_uint32tobin:
    mov   rax,   rdi
    mov   edx,   32
0:  add   esi,   esi
    setc  cl
    add   cl,    '0'
    mov  [rdi],  cl
    inc   rdi
    dec   edx
    jnz   0b
    mov  [rdi],  dl
    retq


#
# Nabla Bit Extract from uint32_t
#
#     uint32_t nabla_pext32(uint32_t v, uint32_t sel);
#
# Returns selected bits placed contiguously. Handy to manipulate x2APIC ID.
#
.globl nabla_pext32
nabla_pext32:
    mov     eax,  edi
    cmp     esi,  ~0         # Early-exit if selector all-ones
    je 0f
    and     eax,  esi        # Early-exit if (sel&v) == 0
    jz 0f
    xor     eax,  eax        # Clear shift register
1:  lzcnt   ecx,  esi        # Detect MSB of next bitfield in selector.
    shl     esi,  cl         # Align selector to MSB
    shl     edi,  cl         # Align value    to MSB
    not     esi              # Negative selector polarity (since no leading-ones count)
    lzcnt   ecx,  esi        # Count consecutive bits to copy from value
    not     esi              # Positive selector polarity
    shld    eax,  edi, cl    # Inject value bits into EAX from the right
    shl     edi,  cl         # Eject copied value bits out the top
    shl     esi,  cl         # Eject equal count of selector bits
    jnz 1b                   # Continue iterating if selector still non-zero.
0:  retq


#
# Nabla Leading Zero Count from uint32_t
#
#     uint32_t nabla_lzcnt32(uint32_t v);
#
# Returns leading zero count. Handy to manipulate x2APIC ID.
#
.globl nabla_lzcnt32
nabla_lzcnt32:
    mov     eax,  32         # Prepare full-width count
    test    edi,  edi        # Check if input zero
    jz 0f                    # If 0, return 32
    lzcnt   eax,  edi        # Otherwise, return leading zero count
0:  retq                     # Return


#
# Nabla Trailing Zero Count from uint32_t
#
#     uint32_t nabla_tzcnt32(uint32_t v);
#
# Returns trailing zero count. Handy to manipulate x2APIC ID.
#
.globl nabla_tzcnt32
nabla_tzcnt32:
    mov     eax,  32         # Prepare full-width count
    test    edi,  edi        # Check if input zero
    jz 0f                    # If 0, return 32
    tzcnt   eax,  edi        # Otherwise, return trailing zero count
0:  retq                     # Return


#
# Nabla Population Count from uint32_t
#
#     uint32_t nabla_popcnt32(uint32_t v);
#
# Returns population count (Hamming Weight). Handy to manipulate x2APIC ID.
#
.globl nabla_popcnt32
nabla_popcnt32:
    mov     eax,  edi
    and     eax,  0xAAAAAAAA # Mask hi bits
    and     edi,  0x55555555 # Mask lo bits
    shr     eax,  1
    add     eax,  edi
    mov     edi,  eax
    and     eax,  0xCCCCCCCC # Mask hi twobits
    and     edi,  0x33333333 # Mask lo twobits
    shr     eax,  2
    add     eax,  edi
    mov     edi,  eax
    and     eax,  0xF0F0F0F0 # Mask hi nibbles
    and     edi,  0x0F0F0F0F # Mask lo nibbles
    shr     eax,  4
    add     eax,  edi
    imul    eax,  eax,  0x01010101
    shr     eax,  24
    retq


#
# Nabla RDTSC/RDTSCP/RDPID/RDPRU Access Functions
#
#      uint64_t nabla_x86_rdtsc()
#      uint64_t nabla_x86_rdtscp()
#      uint64_t nabla_x86_rdtscp_pid(uint32_t* p)
#      uint64_t nabla_x86_rdpid()
#      uint64_t nabla_x86_rdpru(uint64_t v)
#
# Execute RDTSC/RDTSCP/RDPID and returns result
# Execute RDTSCP and save processor ID to p
# Execute RDPRU  with RCX register value v and returns result.
#
.globl nabla_x86_rdtsc
.globl nabla_x86_rdtscp
.globl nabla_x86_rdtscp_pid
.globl nabla_x86_rdpid
.globl nabla_x86_rdpru

nabla_x86_rdtsc:
    rdtsc
    shl     rdx,   32
    or      rax,   rdx
    retq

nabla_x86_rdtscp:
    rdtscp
    shl     rdx,   32
    or      rax,   rdx
    test    rdi,   rdi
    retq

nabla_x86_rdtscp_pid:
    rdtscp
    shl     rdx,   32
    or      rax,   rdx
    test    rdi,   rdi
    mov    [rdi],  ecx
    retq

nabla_x86_rdpid:
    .byte 0xF3, 0x0F, 0xC7, 0xF8   # rdpid   rax
    retq

nabla_x86_rdpru:
    mov     rcx,   rdi
    .byte 0x0F, 0x01, 0xFD         # rdpru
    shl     rdx,   32
    or      rax,   rdx
    retq


#
# Nabla CPUID Access Function
#
#      uint32_t nabla_x86_cpuid(uint32_t buf[4], uint32_t leaf, uint32_t subleaf, int select)
#
# Executes CPUID with register values EAX:ECX and writes result into buf if non-NULL.
# The return value is one selected register from CPUID's output:
#     EAX=0    EBX=1    ECX=2    EDX=3
#
.globl nabla_x86_cpuid
nabla_x86_cpuid:
    mov     r8d,  ecx
    mov     eax,  esi
    mov     ecx,  edx
    mov     rsi,  rbx  # Save RBX
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
    mov     rbx,  rsi  # Restore RBX
    retq


#
# Nabla CPUID x86 CPUID is leaf supported?
#
#     uint32_t nabla_x86_cpuid_is_leaf_supported(uint32_t leaf)
#
# Returns 0 if unsupported, or the maximum supported leaf in the series
# (standard or extended) if supported. If the leaf is supported, the
# return value is always greater than or equal to the input.
#
# HACK: [FOR INTERNAL ASM USE ONLY]
# HACK: THIS FUNCTION HAS THE FOLLOWING SECRET RETURN VALUES
# HACK:     EAX      = 0, or maximum supported leaf >= x
# HACK:     EDI      = CPUID.x.EAX
# HACK:     ESI      = CPUID.x.EBX
# HACK:     ECX      = CPUID.x.ECX
# HACK:     EDX      = CPUID.x.EDX
# HACK:     EFLAGS.Z = !EAX
#
.globl nabla_x86_cpuid_is_leaf_supported
nabla_x86_cpuid_is_leaf_supported:
    mov     rsi,  rbx  # Save RBX
    mov     eax,  edi
    and     eax,  1<<31
    cpuid
    cmp     eax,  edi
    jb 0f              # Unsupported? Jump to Abort
    xchg    eax,  edi  # After swap: EDI contains max supported, EAX contains query
    xor     ecx,  ecx  # Force subleaf 0.
    cpuid
    xchg    eax,  edi  # After swap: EAX contains max supported, EDI contains CPUID.x.EAX
    xchg    rbx,  rsi  # Restore RBX
    test    eax,  eax  # Return: EAX=maximum supported leaf
                       #         EDI=CPUID.x.EAX
                       #         ESI=CPUID.x.EBX
                       #         ECX=CPUID.x.ECX
                       #         EDX=CPUID.x.EDX
    retq               #         (Z set to 0)
0:  mov     rbx,  rsi  # Restore RBX
    xor     edi,  edi  # Return: EAX=0
    xor     esi,  esi  #         EDI=CPUID.x.EAX=0
    xor     eax,  eax  #         ESI=CPUID.x.EBX=0
    xor     ecx,  ecx  #         ECX=CPUID.x.ECX=0
    xor     edx,  edx  #         EDX=CPUID.x.EDX=0
    retq               #         (Z already set to 1)

nabla_x86_cpuid_is_leaf_01_supported:
    mov     edi,  1
    jmp nabla_x86_cpuid_is_leaf_supported

nabla_x86_cpuid_is_leaf_0b_supported:
    mov     edi,  0x0b
    jmp nabla_x86_cpuid_is_leaf_supported

nabla_x86_cpuid_is_leaf_80000008_supported:
    mov     edi,  0x80000008
    jmp nabla_x86_cpuid_is_leaf_supported

#
##
## INTEL SDM (8.6 DETECTING HARDWARE MULTI-THREADING SUPPORT AND TOPOLOGY):
##
##    Software can detect the availability of the CPUID extended topology
##    enumeration leaf (0BH) by performing two steps:
##
##      - Check maximum input value for basic CPUID information by executing
##        CPUID with EAX= 0. If CPUID.0H:EAX is greater than or equal or 11 (0BH),
##        then proceed to next step,
##      - Check CPUID.EAX=0BH, ECX=0H:EBX is non-zero.
##
##    If both of the above conditions are true, extended topology enumeration
##    leaf is available. Note the presence of CPUID leaf 0BH in a processor does
##    not guarantee support that the local APIC supports x2APIC.
##    If CPUID.(EAX=0BH, ECX=0H):EBX returns zero and maximum input value for
##    basic CPUID information is greater than 0BH, then CPUID.0BH leaf is not
##    supported on that processor.
##
#
nabla_x86_cpuid_is_leaf_0b_usable:
    callq nabla_x86_cpuid_is_leaf_0b_supported
    jz 0f
    test    esi,  esi   # Leaf B only actually usable if subleaf 0 reports
    setnz   al          # CPUID.11[ECX=0].EBX = threads/SMT != 0
    and     eax,  1
0:  retq


#
# Nabla CPUID x86 Display Family, Model, Stepping
#
# Relies on inspection of CPUID[EAX=0].EAX and CPUID[EAX=1].EAX:
#    [27:20] ExtFamily   FF
#    [19:16] ExtModel      F
#    [15:12] Reserved       0
#    [11: 8] BaseFamily      F
#    [ 7: 4] BaseModel        F
#    [ 3: 0] Stepping          F
#
#     DisplayFamily = BaseFamily in {15}   ? BaseFamily + ExtFamily  : BaseFamily
#     DisplayModel  = BaseFamily in {6,15} ? BaseModel | ExtModel<<4 : BaseModel
#
# Returns 0 if family, model or stepping cannot be detected.
#
.globl nabla_x86_cpuid_family
.globl nabla_x86_cpuid_model
.globl nabla_x86_cpuid_stepping
.globl nabla_x86_cpuid_family_model_stepping
nabla_x86_cpuid_family:
    callq   nabla_x86_cpuid_family_model_stepping
    shr     eax,  12
    retq

nabla_x86_cpuid_model:
    callq   nabla_x86_cpuid_family_model_stepping
    shr     eax,  4
    and     eax,  0xFF
    retq

nabla_x86_cpuid_stepping:
    callq   nabla_x86_cpuid_family_model_stepping
    and     eax,  0xF
    retq

nabla_x86_cpuid_family_model_stepping:
    callq   nabla_x86_cpuid_is_leaf_01_supported
    jz 0f
    mov     ecx,  edi
    and     ecx,  0x000FF
    mov     eax,  edi
    shr     eax,  16
    shl     eax,  8
    or      eax,  ecx      # EAX = ExtFamily|ExtModel|BaseModel|Stepping, 20 bits
    and     edi,  0x00F00
    shl     edi,  4        # EDI = BaseFamily|0000|0000|0000, 16 bits
    cmp     edi,  15 << 12
    je 1f
    cmp     edi,  6  << 12
    je 2f
    and     eax,  0x000FF  # Entered directly if BaseFamily is neither 6 nor 15
2:  and     eax,  0x00FFF  # Entered directly if BaseFamily is 6,  harmless fallthrough
1:  add     eax,  edi      # Entered directly if BaseFamily is 15, harmless fallthrough
0:  retq


#
# Nabla CPUID x86 Initial APIC ID
# Nabla CPUID x86 x2APIC ID
#
#     uint32_t nabla_x86_cpuid_apicid_initial(void);
#     uint32_t nabla_x86_cpuid_apicid_extended(void);
#
# Returns 0 if Initial APIC ID cannot be detected.
# Returns Init APIC ID if x2APIC ID cannot be detected but Initial APIC ID can be.
#
.globl nabla_x86_cpuid_apicid_initial
.globl nabla_x86_cpuid_apicid_extended

nabla_x86_cpuid_apicid_initial:
    callq   nabla_x86_cpuid_is_leaf_01_supported
    mov     eax,  esi
    shr     eax,  24
    retq

nabla_x86_cpuid_apicid_extended:
    callq   nabla_x86_cpuid_is_leaf_0b_usable
    jz      nabla_x86_cpuid_apicid_initial # If Extended Topology Enumeration Leaf not available, tail-call for Init APIC ID
    mov     eax,  edx                      # [LEAF_Bh] Place x2APIC ID in EAX for return
    retq                                   # [LEAF_Bh] Return


#
# Nabla CPUID x86 APIC ID Mask Logical Core
#
#     uint32_t nabla_x86_cpuid_apicid_mask_core_logical(void);
#
# Returns the APIC ID mask for *logical* cores, including the thread sub-ID if any.
#
#   - If the mask cannot be detected, return all-ones mask (equivalently,
#     assume all logical cores are part of the same package)
#   - If package is 1C/1T, return all-zeroes mask.
#
.globl nabla_x86_cpuid_apicid_mask_core_logical
nabla_x86_cpuid_apicid_mask_core_logical:
    callq   nabla_x86_cpuid_is_amd_or_hygon
    jz    .Lnabla_x86_cpuid_apicid_mask_core_logical_try_leaf_0b
    callq   nabla_x86_cpuid_is_leaf_80000008_supported
    jz    .Lnabla_x86_cpuid_apicid_mask_core_logical_try_leaf_0b
    xor     eax,  eax        # [LEAF_80000008h] Set mask to all-zeroes
    and     ecx,  0xF0FF     # [LEAF_80000008h] Clear everything except ApicIdSize and NT
    jz  0f                   # [LEAF_80000008h] ApicIdSize=0 && NT=0 -> 1C/1T, 0 APIC bits
    not     eax              # [LEAF_80000008h] Materialize all-ones (-1) from all-zeroes (0)
    test    ecx,  0xF000     # [LEAF_80000008h] Check ApicIdSize > 0
    jnz 3f                   # [LEAF_80000008h] Use ApicIdSize if > 0
4:  lzcnt   ecx,  ecx        # [LEAF_80000008h] Count leading bits, cannot be zero
    shl     eax,  cl         # [LEAF_80000008h] Materialize mask over thread bits by...
    shr     eax,  cl         # [LEAF_80000008h] ... clearing upper (ECX) bits of EAX.
    not     eax              # [LEAF_80000008h] HACK: Reverse polarity, fallthrough.
                             # [LEAF_80000008h] HACK: (tricky branch-free trick)
3:  shr     ecx,  12         # [LEAF_80000008h] Isolate ApicIdSize
2:  shl     eax,  cl         # [LEAF_80000008h] Materialize mask over thread bits by...
1:  not     eax              # [LEAF_80000008h] clearing lower (ECX) bits of EAX and reversing
                             # [LEAF_80000008h] HACK: (if code falls through from above, the
                             # [LEAF_80000008h] HACK:  shift amount is guaranteed to be 0)
0:  retq                     # Return
.Lnabla_x86_cpuid_apicid_mask_core_logical_try_leaf_0b:
    callq   nabla_x86_cpuid_is_leaf_0b_usable
    jz    .Lnabla_x86_cpuid_apicid_mask_core_logical_try_leaf_01
    mov     rsi,  rbx        # [LEAF_Bh] Save RBX
    xor     ecx,  ecx        # [LEAF_Bh] Extended Topology Enumeration Subleaf select 0
5:  inc     ecx              # [LEAF_Bh] Extended Topology Enumeration Subleaf select increment
    and     ecx,  0xFF       # [LEAF_Bh] Extended Topology Enumeration Subleaf select mod-256
    mov     eax,  11         # [LEAF_Bh] Extended Topology Enumeration Leaf select
    cpuid                    # [LEAF_Bh] Extended Topology Enumeration Leaf read
    mov     rbx,  rsi        # [LEAF_Bh] Restore RBX
    mov     edx,  ecx        # [LEAF_Bh] Copy CPUID.B.ECX
    and     edx,  0xFF00     # [LEAF_Bh] Isolate CPUID.B.ECX[15:8] = Level type
    jz  1b                   # [LEAF_Bh] Level type = "Invalid"? -> EAX already clear & return all-ones mask
    cmp     edx,  2<<8       # [LEAF_Bh] Level type = "Core"?
    jne 5b                   # [LEAF_Bh] If != "Core", move to next subleaf
    mov     ecx,  eax        # [LEAF_Bh] Level type = "Core". Place shift amount in ECX.
    and     ecx,  0x1F       # [LEAF_Bh] Isolate CPUID.B.EAX[4:0]
    mov     eax,  -1         # [LEAF_Bh] Materialize all-ones mask in EAX.
    jmp 2b                   # [LEAF_Bh] Reuse SHL logic of Leaf 80000008
.Lnabla_x86_cpuid_apicid_mask_core_logical_try_leaf_01:
    callq   nabla_x86_cpuid_is_leaf_01_supported
    jz  1b                   # Mask not detectable; Return all-ones mask
    xor     eax,  eax        # [LEAF_1h] Materialize all-zeroes mask
    test    edx,  1<<28      # [LEAF_1h] Check if CPUID.1.EDX[HTT] bit set (possibly multi-core)
    jz  0b                   # [LEAF_1h] HTT unset; Must be 1C/1T; return all-zero mask
    shr     esi,  16         # [LEAF_1h] nextPowerOf2(CPUID.1.EBX[23:16]) = Package APIC IDs
    and     esi,  0xFF       # [LEAF_1h] ... continued
    dec     esi              # [LEAF_1h] Decrement
    jz  0b                   # [LEAF_1h] Was 1 APIC ID; Must be 1C/1T; return all-zero mask
    mov     ecx,  esi        # [LEAF_1h] Place biased logical core count in ECX
    not     eax              # [LEAF_1h] Materialize all-ones (-1) from all-zeroes (0)
    jmp 4b                   # [LEAF_1h] Reuse LZCNT logic of Leaf 80000008


#
# Nabla CPUID x86 APIC ID Mask Package
#
# Returns the APIC ID mask for packages (every bit above the logical processor)
#
#     uint32_t nabla_x86_cpuid_apicid_mask_package(void);
#
.globl nabla_x86_cpuid_apicid_mask_package
nabla_x86_cpuid_apicid_mask_package:
    callq   nabla_x86_cpuid_apicid_mask_core_logical
    not     eax
    retq


#
# Nabla CPUID x86 APIC ID Mask SMT
#
#     uint32_t nabla_x86_cpuid_apicid_mask_smt(void);
#
.globl nabla_x86_cpuid_apicid_mask_smt
nabla_x86_cpuid_apicid_mask_smt:
    callq   nabla_x86_cpuid_is_leaf_0b_usable
    jz 0f             # If Extended Topology Enumeration Leaf not usable, mask=0
    pushq   rdi       # [LEAF_Bh] Save RDI=CPUID.11.EAX
    callq   nabla_x86_cpuid_apicid_mask_core_logical
    popq    rcx       # [LEAF_Bh] Restore RCX=CPUID.11.EAX
    mov     edx,  1   # [LEAF_Bh] Begin creating SMT mask
    shl     edx,  cl  # [LEAF_Bh] Compute 1<<CPUID.11.EAX[4:0]
    dec     edx       # [LEAF_Bh] -1 sets all bits below bit CPUID.11.EAX[4:0]
    and     eax,  edx # [LEAF_Bh] SMT mask is strict subset of logical core mask
0:  retq              # Return


#
# Nabla CPUID x86 APIC ID Mask Physical Core within package
#
# Returns the APIC ID mask for *physical* cores, excluding the thread sub-ID.
#
#     uint32_t nabla_x86_cpuid_apicid_mask_core_physical(void);
#
.globl nabla_x86_cpuid_apicid_mask_core_physical
nabla_x86_cpuid_apicid_mask_core_physical:
    callq nabla_x86_cpuid_apicid_mask_smt
    pushq rax
    callq nabla_x86_cpuid_apicid_mask_core_logical
    popq  rcx
    xor   eax,  ecx   # Exclude SMT bits from logical core mask to get physical core mask
    retq


#
# Nabla CPUID x86 APIC ID Mask Last-Level Cache within package
#
# Returns the APIC ID mask for the last-level cache ID within a package.
# On AMD and Hygon CPUs, returns the logical-OR of the CCD and CCX masks.
# On CPUs other than AMD or Hygon (such as Intel), returns 0 (all cores within
# a package assumed to share same cache).
#
#     uint32_t nabla_x86_cpuid_apicid_mask_core_llc(void);
#
.globl nabla_x86_cpuid_apicid_mask_core_llc
nabla_x86_cpuid_apicid_mask_core_llc:
    callq   nabla_x86_cpuid_is_amd_or_hygon
    jz 0f
    callq   nabla_x86_cpuid_apicid_mask_amd_ccd
    pushq   rax
    callq   nabla_x86_cpuid_apicid_mask_amd_ccx
    popq    rcx
    or      eax,  ecx
0:  retq


#
# Nabla CPUID x86 APIC ID Mask AMD CCD and CCX within package
#
# Returns the APIC ID mask for the CCD ID within an AMD CPU package, and the
# APIC ID mask for a CCX ID within a CCD.
#
# On CPUs other than AMD or Hygon (such as Intel), returns 0 (there are no CCDs/CCXes)
#
#     uint32_t nabla_x86_cpuid_apicid_mask_amd_ccd(void);
#     uint32_t nabla_x86_cpuid_apicid_mask_amd_ccx(void);
#
.globl nabla_x86_cpuid_apicid_mask_amd_ccd
.globl nabla_x86_cpuid_apicid_mask_amd_ccx
nabla_x86_cpuid_apicid_mask_amd_ccd:
    callq   nabla_x86_cpuid_is_amd_or_hygon
    jz  0f                          # Not AMD or Hygon; No concept of CCX or CCD.
    callq   nabla_x86_cpuid_is_hygon_fam18h
    mov     eax,  -16               # Hygon Dhyana/Zen: Bits 4 and up identify CCD within package.
    jnz 1f
    callq   nabla_x86_cpuid_is_amd_fam17h
    jz  2f                          # AMD Zen 3 or newer, same logic as Zen 2.
    callq   nabla_x86_cpuid_is_amd_fam17h_zen2
    mov     eax,  -16               # AMD Zen/Zen+: Bits 4 and up identify CCD within package.
    jz  1f
2:  callq   nabla_x86_cpuid_apicid_mask_smt
    not     eax                     # Zen 2/Zen 3 and newer: 3 ID bits for physical cores within CCD;
    shl     eax,  3                 # SMT ID, if present, occupies additional low-order bits.
1:  pushq   rax
    callq   nabla_x86_cpuid_apicid_mask_core_logical
    popq    rcx                     # CCD ID bits are top-level within a package, so mask
    and     eax,  ecx               # them by the logical core mask.
0:  retq

nabla_x86_cpuid_apicid_mask_amd_ccx:
    callq   nabla_x86_cpuid_is_amd_or_hygon
    jz  0b                          # Not AMD or Hygon: No concept of CCX or CCD.
    callq   nabla_x86_cpuid_is_hygon_fam18h
    mov     eax,  0b1000            # Hygon Dhyana/Zen: Bit 3 identifies CCX within CCD.
    jnz 1b
    callq   nabla_x86_cpuid_is_amd_fam17h
    jz  0b                          # Not Hygon or AMD Zen/Zen+/Zen 2: No CCX distinct from CCD.
    callq   nabla_x86_cpuid_is_amd_fam17h_zen2
    mov     eax,  0b1000
    jz  1b                          # AMD Zen/Zen+: Bit 3 identifies CCX within CCD.
    callq   nabla_x86_cpuid_apicid_mask_smt
    inc     eax                     # AMD Zen 2: 2 ID bits for physical cores within CCX;
    shl     eax,  2                 # SMT ID, if present, occupies additional low-order bits.
    jmp 1b


#
# Nabla CPUID is AMD/Intel/Hygon
#
# NB: Hygon is a Chinese company that recently collaborated with AMD to produce
#     a Family 18h (Zen-class) processor that could, theoretically, execute the
#     same kernels as AMD Zen/Zen+ processors. On the off-chance this happens,
#     support detecting this x86_64 vendor.
#
# HACK: [FOR INTERNAL ASM USE ONLY]
# HACK: THIS FUNCTION HAS THE FOLLOWING SECRET RETURN VALUES
# HACK:     EFLAGS.Z = !EAX
#
.globl nabla_x86_cpuid_is_amd
.globl nabla_x86_cpuid_is_intel
.globl nabla_x86_cpuid_is_hygon
.globl nabla_x86_cpuid_is_amd_or_hygon
nabla_x86_cpuid_is_amd:
    mov     rsi,  rbx
    xor     eax,  eax
    cpuid
    xor     eax,  eax
    cmp     ebx,  'A' | 'u'<<8 | 't'<<16 | 'h'<<24; jne 0f  # Not AMD
    cmp     edx,  'e' | 'n'<<8 | 't'<<16 | 'i'<<24; jne 0f  # Not AMD
    cmp     ecx,  'c' | 'A'<<8 | 'M'<<16 | 'D'<<24; jne 0f  # Not AMD
    inc     eax
0:  mov     rbx,  rsi
    test    eax,  eax
    retq

nabla_x86_cpuid_is_intel:
    mov     rsi,  rbx
    xor     eax,  eax
    cpuid
    xor     eax,  eax
    cmp     ebx,  'G' | 'e'<<8 | 'n'<<16 | 'u'<<24; jne 0f  # Not Intel
    cmp     edx,  'i' | 'n'<<8 | 'e'<<16 | 'I'<<24; jne 0f  # Not Intel
    cmp     ecx,  'n' | 't'<<8 | 'e'<<16 | 'l'<<24; jne 0f  # Not Intel
    inc     eax
0:  mov     rbx,  rsi
    test    eax,  eax
    retq

nabla_x86_cpuid_is_hygon:
    mov     rsi,  rbx
    xor     eax,  eax
    cpuid
    xor     eax,  eax
    cmp     ebx,  'H' | 'y'<<8 | 'g'<<16 | 'o'<<24; jne 0f  # Not Hygon
    cmp     edx,  'n' | 'G'<<8 | 'e'<<16 | 'n'<<24; jne 0f  # Not Hygon
    cmp     ecx,  'u' | 'i'<<8 | 'n'<<16 | 'e'<<24; jne 0f  # Not Hygon
    inc     eax
0:  mov     rbx,  rsi
    test    eax,  eax
    retq

nabla_x86_cpuid_is_amd_or_hygon:
    callq   nabla_x86_cpuid_is_amd    # Unconditional straight call
    jz      nabla_x86_cpuid_is_hygon  # Conditional tail-call
    retq


#
# Nabla CPUID is AMD Family 17h/17h Zen 2/18h/19h
#
# Family 17h marks out a CPU as an AMD Zen, Zen+ or Zen 2 CPU.
# Family 18h marks out a CPU as a Hygon Dhyana Zen CPU.
# Family 19h marks out a CPU as an AMD Zen 3 or newer CPU.
#
# HACK: [FOR INTERNAL ASM USE ONLY]
# HACK: THIS FUNCTION HAS THE FOLLOWING SECRET RETURN VALUES
# HACK:     EFLAGS.Z = !EAX
#
nabla_x86_cpuid_is_amd_fam17h:
    callq   nabla_x86_cpuid_is_amd
    jz 0f
    callq   nabla_x86_cpuid_family
    cmp     eax,  0x17
    sete    al
    and     eax,  1
0:  retq

nabla_x86_cpuid_is_amd_fam17h_zen2:
    callq   nabla_x86_cpuid_is_amd_fam17h
    jz 0f
    callq   nabla_x86_cpuid_model
    mov     ecx,  eax
    shr     ecx,  3
    mov     eax,  0b11111111111111111111110011000000
    #                                     //  //|||\
    #                                    //  // ||\ Summit Ridge/Snowy Owl/Whitehaven/Naples, Zen
    #                    FireFlight, Zen+   //  |\ Pinnacle Ridge/Colfax, Zen+
    #                              Dali, Zen    | Raven Ridge/Great Horned Owl, Zen
    #                            Picasso/Banded Kestrel, Zen+/Zen
    shr     eax,  cl
    and     eax,  1
0:  retq

nabla_x86_cpuid_is_hygon_fam18h:
    callq   nabla_x86_cpuid_is_hygon
    jz 0f
    callq   nabla_x86_cpuid_family
    cmp     eax,  0x18
    sete    al
    and     eax,  1
0:  retq

nabla_x86_cpuid_is_amd_fam19h:
    callq   nabla_x86_cpuid_is_amd
    jz 0f
    callq   nabla_x86_cpuid_family
    cmp     eax,  0x19
    sete    al
    and     eax,  1
0:  retq


#
# Nabla CPUID x86 microarchitecture
#
.globl nabla_x86_cpuid_microarchitecture
nabla_x86_cpuid_microarchitecture:
    callq   nabla_x86_cpuid_is_amd_or_hygon
    jnz   .Lnabla_x86_cpuid_microarchitecture_amd_or_hygon
    callq   nabla_x86_cpuid_is_intel
    jnz   .Lnabla_x86_cpuid_microarchitecture_intel
    lea     rax, [rip+.Luarch_unknown]
    retq

.Lnabla_x86_cpuid_microarchitecture_amd_or_hygon:
    callq   nabla_x86_cpuid_is_amd_fam19h
    jnz   .Lnabla_x86_cpuid_microarchitecture_amd_fam19h
    callq   nabla_x86_cpuid_is_hygon_fam18h
    jnz   .Lnabla_x86_cpuid_microarchitecture_hygon_fam18h
    callq   nabla_x86_cpuid_is_amd_fam17h
    jnz   .Lnabla_x86_cpuid_microarchitecture_amd_fam17h
    lea     rax, [rip+.Luarch_unknown_amd]
    retq

.Lnabla_x86_cpuid_microarchitecture_amd_fam17h:
    #
    # Categorize AMD Family 17h microarchitectures.
    #
    # First eliminate the easy case, Zen 2.
    # Then attempt to distinguish between Zen and Zen+.
    #
    # Unfortunately, Banded Kestrel and Picasso cannot be distinguished by FMS
    # nor by package type, yet they differ in microarchitecture. Use core
    # configuration instead:
    #
    #   - Banded Kestrel has 2C/4T only
    #   - Picasso        has 4C/4T and upwards
    #
    callq   nabla_x86_cpuid_is_amd_fam17h_zen2
    lea     rax, [rip+.Luarch_zen2]
    jnz 0f
    callq   nabla_x86_cpuid_model
    mov     ecx,  eax
    shr     ecx,  3
    cmp     ecx,  0x18>>3          #   Family 17h Model 18h is ambiguous.
    je    .Lnabla_x86_cpuid_microarchitecture_amd_fam17h_model18h
    mov     edx,                        0b1100001010
    #                                     //  //|||\
    #                                    //  // ||\ Summit Ridge/Snowy Owl/Whitehaven/Naples, Zen
    #                    FireFlight, Zen+   //  |\ Pinnacle Ridge/Colfax, Zen+
    #                              Dali, Zen    | Raven Ridge/Great Horned Owl, Zen
    #                            Picasso/Banded Kestrel, Zen+/Zen
    shr     edx,  cl
    test    edx,  1                #   Family 17h, Zen+?
    lea     rax, [rip+.Luarch_zenp]
    jnz 0f
.Lnabla_x86_cpuid_microarchitecture_hygon_fam18h:
    lea     rax, [rip+.Luarch_zen] #   Family 17h, all other models assumed Zen.
0:  retq                           #   Family 18h is also always Hygon Dhyana Zen.

.Lnabla_x86_cpuid_microarchitecture_amd_fam17h_model18h:
    #
    # Family 17h Model 18h distinguisher using physical core count.Ey
    #
    # Use Leaf 0x0B and divide threads/package (Subleaf 1)
    #                       by threads/core    (Subleaf 0).
    #
    # We know these are the only topology levels reported by CPUID because we
    # can only get here if CPUID gives Family 17h Model 18h, and both Banded
    # Kestrel and Picasso have symmetric core designs. Banded Kestrel is very
    # unlikely; If there are any failures, assume Picasso, Zen+.
    #
    callq   nabla_x86_cpuid_is_leaf_0b_usable
    lea     rax, [rip+.Luarch_zenp]
    jz  0f             # Leaf 0x0B unusable, assume  Picasso, Zen+
    pushq   rbx        # [LEAF_Bh] Save RBX
    mov     eax,  11   # [LEAF_Bh] Extended Topology Enumeration Leaf select
    mov     ecx,  1    # [LEAF_Bh] Extended Topology Enumeration Subleaf 1 select
    cpuid              # [LEAF_Bh] Extended Topology Enumeration Subleaf 1 read
    tzcnt   ecx,  esi  # [LEAF_Bh] Compute threads/core trailing-zero count from CPUID.11.[ECX=0].EBX[15:0]
    shr     ebx,  cl   # [LEAF_Bh] Divide  threads/package / threads/core -> cores/package
    cmp     ebx,  2    # [LEAF_Bh] Compare against Banded Kestrel's physical core count.
    popq    rbx        # [LEAF_Bh] Restore RBX
    lea     rax, [rip+.Luarch_zenp]
    jne 0f             # [LEAF_Bh] Core count != 2, assume  Picasso, Zen+
    lea     rax, [rip+.Luarch_zen]
0:  retq               # [LEAF_Bh] Core count == 2, must be Banded Kestrel, Zen

.Lnabla_x86_cpuid_microarchitecture_amd_fam19h:
    callq   nabla_x86_cpuid_model
    mov     ecx,  eax
    shr     ecx,  3
    lea     rax, [rip+.Luarch_zen3]
    mov     edx,  0b00000000000000000000010001010011
    #                                    /   / \  |\
    #                                   /   /   \  \ Genesis Peak/Milan/Milan-X
    #                            Cezanne   /     \ Chagall
    #                                  Trento   Vermeer
    shr     edx,  cl
    test    edx,  1
    jnz 0f
    lea     rax, [rip+.Luarch_zen3p]
    mov     edx,  0b00000000000000000000000100000000
    #                                      |
    #                                  Rembrandt
    shr     edx,  cl
    test    edx,  1
    jnz 0f
    lea     rax, [rip+.Luarch_zen4]
    mov     edx,  0b00000000000000000101000000000100
    #                                / \         |
    #                         Phoenix  Raphael  Genoa
    shr     edx,  cl
    test    edx,  1
    jnz 0f
    lea     rax, [rip+.Luarch_zen4c]
    mov     edx,  0b00000000000100000000000000000000
    #                          |
    #                       Bergamo
    shr     edx,  cl
    test    edx,  1
    jnz 0f
    lea     rax, [rip+.Luarch_zen5]
    mov     edx,  0b00000000000000000000000000001000
    #                                           |
    #                                      Strix Point?
    shr     edx,  cl
    test    edx,  1
    jnz 0f
    lea     rax, [rip+.Luarch_unknown_amd]
0:  retq

.Lnabla_x86_cpuid_microarchitecture_intel:
    lea     rax, [rip+.Luarch_unknown_intel]
    retq


#
# SGEMM Modulo-Decrement Test Function
#
# Coordinate System:
#
#     Name:                  n :  m :  p : k4 : 1
#     Max:                   4   31    1   31   1
#     Bits:                  3    6    2    6   1
#     Offset:               15    9    7    1   0
#
.globl sgemm_mod_count
sgemm_mod_count:
    mov     edi,   (           (63^31) << 9 | (3^1)<< 7 | (63^31) << 1)
    mov     edx,   ( 4 << 15 |     31  << 9 |    1 << 7 |     31  << 1)|1
    xor     eax,   eax
0:
    # Independent count of iterations
    inc     eax
    
    # Modulo-bump
    sub     edx,   2
    mov     ecx,   edx
    and     ecx,   0b000100000101000001
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
# SGEMM tester
#
#                        RDI,      RSI,      RDX,      RCX,    R8,          R9,                   XMM0,        XMM1
# extern void sgemm_test(float* A, float* B, float* C, int K0, int counter, int prefetch_counter, float alpha, float beta);
#
.globl sgemm_test
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
    or           r8d,    2                               # Ensure correctness of counter
    or           r9d,    2                               # Ensure correctness of prefetch counter
    mov          r12d,   ecx                             # Install R12 = K0 control constant
    mov          r13,    rdi                             # Install R13 = A-base-pointer
    mov          r14,    rsi                             # Install R14 = B-base-pointer
    mov          r15,    rdx                             # Install R15 = C-base-pointer
    
    mov          ecx,    r8d                             # = NEXT COUNTER
    and          ecx,           KNmask                   # = (n/32 << 14) = (n << 9)
    shr          ecx,           KNshft                   # = (n << 2) = n*sizeof(float)
    
    mov          esi,    r8d                             # = NEXT COUNTER
    and          esi,           KPmask                   # = (n&16) << 2
    shr          esi,           KPshft                   # = (n&16) << 2 = (n&16)*sizeof(float)
    add          ecx,    esi                             # = (n+p)*sizeof(float)
    
    mov          esi,    r8d                             # = NEXT COUNTER
    and          esi,           KMmask                   # = (m/5 << 8)
    shl          esi,           2-KMshft                 # = (m/5 << 9) = m/5*128*sizeof(float)
    lea          esi,   [esi+esi*4]                      # = m*128*sizeof(float)
    
    leaq         rax,   [r13+rsi]                        # Install A-pointer
    leaq         rbx,   [r14+rcx]                        # Install B-pointer
    
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
    jmp .Lsgemm_zen2_bu_core_16x_unroll_accumulate       # EXECUTE
0:  sfence
    vzeroupper
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
.align 64
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

#
# SGEMM, Idea 4
#
#     A[M=160][K=128]
#     B[K=128][N=160]
#     C[M=160][N=160]
#
#   - Dtype: float32
#   - Basic unit: A{5,128} x B{128,16} = C{5,16} (Accumulator: 10x YMM registers)
#     - Cost:
#       - Insn:    10x128 = 1280 FMA (bottleneck; IPC throughput)
#       - Insn:     7x128 =  896 LD  (total: 128*(16+5)*4  = 10.5    KB)
#       - Insn:     5x2   =   10 ST  (total:  10*32 = 320B =  0.3125 KB, NT-hinted?)
#       - Time: 640 cc
#       - L1d occupancy:      128*(16+5)*4     = 10.5   KB   < 32 KB
#       - L1d  -> Core Rd BW: 128*(16+5)*4/640 = 16.8   B/cc < 64 B/cc
#       - Core -> L1d  Wr BW:        10*32/640 =  0.5   B/cc < 32 B/cc
#
#   - Pair: The execution of two side-by-side basic units
#              |   B0  |   B1  |
#        ------+-------+-------+
#          A0  |  A0B0 |  A0B1 |
#     requiring the same 128B supercacheline for B-slice data.
#     - Cost:
#       - Insn:   2x10x128 = 2560 FMA (bottleneck; IPC throughput)
#       - Insn:    2x7x128 = 1792 LD  (total: 128*(32+5)*4  = 18.5    KB)
#       - Insn:    2x5x2   =   20 ST  (total:  20*32 = 640B =  0.625  KB, NT-hinted?)
#       - Time: 1280 cc
#       - L1d occupancy:      128*(32+5)*4      = 18.5   KB   < 32 KB
#       - L1d  -> Core Rd BW: 256*(16+5)*4/1280 = 16.8   B/cc < 64 B/cc
#       - Core -> L1d  Wr BW:        20*32/1280 =  0.5   B/cc < 32 B/cc
#
#   - Panel: The execution of thirty-two pairs
#              |   B0:B1  |
#        ------+----------+
#          A0  |   A0B01  |
#          A1  |   A1B01  |
#          A2  |   A2B01  |
#          A3  |   A3B01  |
#             .........
#          A28 |  A28B01  |
#          A29 |  A29B01  |
#          A30 |  A30B01  |
#          A31 |  A31B01  |
#     reusing the same two B-slices until exhaustion of all A-slices.
#     - Cost:
#       - Insn:  81920 FMA, 57344 LD, 640 ST
#       - Time:  40960 cc
#       - L2 occupancy:       128*(5*32+32)*4       =  96     KB   < 512 KB
#       - L2   -> L1d  Rd BW: 128*(5*32+32)*4/40960 =   2.4   B/cc < 32 B/cc
#                                                     (+0.5 if consuming accumulators!)
#       - L1d  -> L2   Wr BW:        32*20*32/40960 =   0.5   B/cc < 32 B/cc
#
#   - Superpanel: The execution of five side-by-side panels
#              | B0:B1 | B2:B3 | B4:B5 | B6:B7 | B8:B9 |
#        ------+-------+-------+-------+-------+-------+
#        A0:A31|  AB01 |  AB32 |  AB45 |  AB67 |  AB89 |
#     streaming 5 times all A-slices and loading once each pair of B-slices.
#     - Cost:
#       - Insn:  409600 FMA, 286720 LD, 3200 ST
#       - Time:  204800 cc
#       - L2 occupancy:       128*(5*32+5*32)*4        = 160     KB   < 512 KB
#       - L2   -> L1d  Rd BW: 128*(5*32+5*32)*4/204800 =   0.8   B/cc < 32 B/cc
#                                                        (+0.5 if consuming accumulators!)
#       - L1d  -> L2   Wr BW:        5*32*20*32/204800 =   0.5   B/cc < 32 B/cc
#


#
# SGEMM Basic Unit Kernel, 16x unrolled.
#
# The SGEMM basic unit is a matrix multiplication of C(5,16) += A(5xK) x B(Kx16)
# sliced out of C(160x160) += A(160xK) x B(Kx160) matrix tiles. There are 320
# basic units per tile operation. K is divisible by the unroll factor 16 such
# that 16 <= K <= 128.
#
# An SGEMM basic unit executes K sets of 10 FMAs.
#
.align 4096
.globl sgemm_zen2_bu_core_16x_unroll_accumulate
sgemm_zen2_bu_core_16x_unroll_accumulate:
.Lsgemm_zen2_bu_core_16x_unroll_accumulate:#************ BU CORE 16X UNROLL ************
                                           #
                                           #             MAIN ARITHMETIC BODY
                                           #           REGISTERS USED: RAX, RBX, YMMx
                                           # [ARITH] K=0
    vmovaps      ymm4,  [rbx+0*160*4]      # [ARITH] Load B[k+0, n  :n+ 8]
    vmovaps      ymm5,  [rbx+0*160*4+32]   # [ARITH] Load B[k+0, n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+0*128*4]  # [ARITH] Load A[m+0, k+0]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+0] * B[k+0,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+0] * B[k+0,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+1*128*4]  # [ARITH] Load A[m+1, k+0]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+0] * B[k+0,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+0] * B[k+0,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+2*128*4]  # [ARITH] Load A[m+2, k+0]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+0] * B[k+0,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+0] * B[k+0,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+3*128*4]  # [ARITH] Load A[m+3, k+0]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+0] * B[k+0,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+0] * B[k+0,n+8:n+16]
    vbroadcastss ymm3,  [rax+0*4+4*128*4]  # [ARITH] Load A[m+4, k+0]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+0] * B[k+0,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+0] * B[k+0,n+8:n+16]
                                           # [ARITH] K=1
    vmovaps      ymm4,  [rbx+1*160*4]      # [ARITH] Load B[k+1, n  :n+ 8]
    vmovaps      ymm5,  [rbx+1*160*4+32]   # [ARITH] Load B[k+1, n+8:n+16]
    vbroadcastss ymm3,  [rax+1*4+0*128*4]  # [ARITH] Load A[m+0, k+1]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+1] * B[k+1,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+1] * B[k+1,n+8:n+16]
    vbroadcastss ymm3,  [rax+1*4+1*128*4]  # [ARITH] Load A[m+1, k+1]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+1] * B[k+1,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+1] * B[k+1,n+8:n+16]
    vbroadcastss ymm3,  [rax+1*4+2*128*4]  # [ARITH] Load A[m+2, k+1]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+1] * B[k+1,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+1] * B[k+1,n+8:n+16]
    vbroadcastss ymm3,  [rax+1*4+3*128*4]  # [ARITH] Load A[m+3, k+1]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+1] * B[k+1,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+1] * B[k+1,n+8:n+16]
    vbroadcastss ymm3,  [rax+1*4+4*128*4]  # [ARITH] Load A[m+4, k+1]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+1] * B[k+1,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+1] * B[k+1,n+8:n+16]
                                           # [ARITH] K=2
    vmovaps      ymm4,  [rbx+2*160*4]      # [ARITH] Load B[k+2, n  :n+ 8]
    vmovaps      ymm5,  [rbx+2*160*4+32]   # [ARITH] Load B[k+2, n+8:n+16]
    vbroadcastss ymm3,  [rax+2*4+0*128*4]  # [ARITH] Load A[m+0, k+2]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+2] * B[k+2,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+2] * B[k+2,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*4+1*128*4]  # [ARITH] Load A[m+1, k+2]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+2] * B[k+2,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+2] * B[k+2,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*4+2*128*4]  # [ARITH] Load A[m+2, k+2]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+2] * B[k+2,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+2] * B[k+2,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*4+3*128*4]  # [ARITH] Load A[m+3, k+2]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+2] * B[k+2,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+2] * B[k+2,n+8:n+16]
    vbroadcastss ymm3,  [rax+2*4+4*128*4]  # [ARITH] Load A[m+4, k+2]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+2] * B[k+2,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+2] * B[k+2,n+8:n+16]
                                           # [ARITH] K=3
    vmovaps      ymm4,  [rbx+3*160*4]      # [ARITH] Load B[k+3, n  :n+ 8]
    vmovaps      ymm5,  [rbx+3*160*4+32]   # [ARITH] Load B[k+3, n+8:n+16]
    vbroadcastss ymm3,  [rax+3*4+0*128*4]  # [ARITH] Load A[m+0, k+3]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+3] * B[k+3,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+3] * B[k+3,n+8:n+16]
    vbroadcastss ymm3,  [rax+3*4+1*128*4]  # [ARITH] Load A[m+1, k+3]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+3] * B[k+3,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+3] * B[k+3,n+8:n+16]
                                                                                                #
                                                                                                #             CURRENT POINTER C COMPUTATION &
                                                                                                #             CURRENT MODULO COUNTER (R8) DECREMENT &
                                                                                                #             CURRENT/NEXT POINTER A & B COMPUTATION
                                                                                                #
                                                                                                #           REGISTERS I: R8, R12, R13, R14, R15
                                                                                                #           REGISTERS O: R8, RCX, RDX, RDI, RSI
                                                                                                #           REGISTERS available:   RCX, RDX, RDI, RSI, R10, R11
                                                                                                #           REGISTERS unavailable: RAX, RBX, R9
                                                                                                #
                                                                                                # [COUNT] A-current-pointer (float A[M=160][K=128])
                                                                                                # [COUNT] B-current-pointer (float B[K=128][N=160])
                                                                                                # [COUNT] C-current-pointer (float C[M=160][N=160])
                                                                                                # [COUNT] 
                                                                                                # [COUNT] Coordinate System:
                                                                                                # [COUNT] 
                                                                                                # [COUNT]     Name:                  n/32 : m/5 : n&16 : k/8 : 1
                                                                                                # [COUNT]     Max:                     4     31    1      15   1
                                                                                                # [COUNT]     Bits:                    3      6    2       5   1
                                                                                                # [COUNT]     Offset:                 14      8    6       1   0
                                                                                                # [COUNT]
                                                mov          edx,    r8d                        # [COUNT] = CURRENT COUNTER
                                                and          edx,           KMmask              # [COUNT] = (m/5) << 8
    vbroadcastss ymm3,  [rax+3*4+2*128*4]  # [ARITH] Load A[m+2, k+3]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+3] * B[k+3,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+3] * B[k+3,n+8:n+16]
    vbroadcastss ymm3,  [rax+3*4+3*128*4]  # [ARITH] Load A[m+3, k+3]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+3] * B[k+3,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+3] * B[k+3,n+8:n+16]
                                                shr          edx,           KMshft              # [COUNT] = (m/5) << 7 = m/5*32*sizeof(float)
    vbroadcastss ymm3,  [rax+3*4+4*128*4]  # [ARITH] Load A[m+4, k+3]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+3] * B[k+3,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+3] * B[k+3,n+8:n+16]
                                           # [ARITH] K=4
    vmovaps      ymm4,  [rbx+4*160*4]      # [ARITH] Load B[k+4, n  :n+ 8]
    vmovaps      ymm5,  [rbx+4*160*4+32]   # [ARITH] Load B[k+4, n+8:n+16]
                                                lea          edx,   [edx+edx*4]                 # [COUNT] = m*32*sizeof(float)
    vbroadcastss ymm3,  [rax+4*4+0*128*4]  # [ARITH] Load A[m+0, k+4]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+4] * B[k+4,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+4] * B[k+4,n+8:n+16]
                                                lea          edx,   [edx+edx*4]                 # [COUNT] = m*160*sizeof(float)
                                                addq         rdx,    r15                        # [COUNT] = &C[m,0]
    vbroadcastss ymm3,  [rax+4*4+1*128*4]  # [ARITH] Load A[m+1, k+4]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+4] * B[k+4,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+4] * B[k+4,n+8:n+16]
    vbroadcastss ymm3,  [rax+4*4+2*128*4]  # [ARITH] Load A[m+2, k+4]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+4] * B[k+4,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+4] * B[k+4,n+8:n+16]
                                                mov          ecx,    r8d                        # [COUNT] = CURRENT COUNTER
                                                and          ecx,           KNmask              # [COUNT] = (n/32) << 14 = (n << 9)
    vbroadcastss ymm3,  [rax+4*4+3*128*4]  # [ARITH] Load A[m+3, k+4]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+4] * B[k+4,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+4] * B[k+4,n+8:n+16]
    vbroadcastss ymm3,  [rax+4*4+4*128*4]  # [ARITH] Load A[m+4, k+4]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+4] * B[k+4,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+4] * B[k+4,n+8:n+16]
                                                shr          ecx,           KNshft              # [COUNT] = (n << 2) = n*sizeof(float)
                                                addq         rdx,    rcx                        # [COUNT] = &C[m,n]
                                           # [ARITH] K=5
    vmovaps      ymm4,  [rbx+5*160*4]      # [ARITH] Load B[k+5, n  :n+ 8]
    vmovaps      ymm5,  [rbx+5*160*4+32]   # [ARITH] Load B[k+5, n+8:n+16]
    vbroadcastss ymm3,  [rax+5*4+0*128*4]  # [ARITH] Load A[m+0, k+5]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+5] * B[k+5,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+5] * B[k+5,n+8:n+16]
    vbroadcastss ymm3,  [rax+5*4+1*128*4]  # [ARITH] Load A[m+1, k+5]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+5] * B[k+5,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+5] * B[k+5,n+8:n+16]
                                                mov          ecx,    r8d                        # [COUNT] = CURRENT COUNTER
                                                and          ecx,           KPmask              # [COUNT] = (n&16) << 2
    vbroadcastss ymm3,  [rax+5*4+2*128*4]  # [ARITH] Load A[m+2, k+5]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+5] * B[k+5,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+5] * B[k+5,n+8:n+16]
    vbroadcastss ymm3,  [rax+5*4+3*128*4]  # [ARITH] Load A[m+3, k+5]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+5] * B[k+5,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+5] * B[k+5,n+8:n+16]
                                                shr          ecx,           KPshft              # [COUNT] = (n&16) << 2 = (n&16)*sizeof(float)
                                                addq         rdx,    rcx                        # [COUNT] = &C[m,n+p]
    vbroadcastss ymm3,  [rax+5*4+4*128*4]  # [ARITH] Load A[m+4, k+5]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+5] * B[k+5,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+5] * B[k+5,n+8:n+16]
                                           # [ARITH] K=6
    vmovaps      ymm4,  [rbx+6*160*4]      # [ARITH] Load B[k+6, n  :n+ 8]
    vmovaps      ymm5,  [rbx+6*160*4+32]   # [ARITH] Load B[k+6, n+8:n+16]
    vbroadcastss ymm3,  [rax+6*4+0*128*4]  # [ARITH] Load A[m+0, k+6]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+6] * B[k+6,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+6] * B[k+6,n+8:n+16]
                                                mov          edi,    r8d                        # [COUNT] CURRENT COUNTER save
                                                sub          r8,     4                          # [COUNT] CURRENT COUNTER Bump (R8)
    vbroadcastss ymm3,  [rax+6*4+1*128*4]  # [ARITH] Load A[m+1, k+6]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+6] * B[k+6,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+6] * B[k+6,n+8:n+16]
    vbroadcastss ymm3,  [rax+6*4+2*128*4]  # [ARITH] Load A[m+2, k+6]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+6] * B[k+6,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+6] * B[k+6,n+8:n+16]
                                                mov          ecx,    r8d                        # [COUNT] CURRENT COUNTER Bump (R8)
                                                and          ecx,    K1                         # [COUNT] CURRENT COUNTER Bump (R8)
    vbroadcastss ymm3,  [rax+6*4+3*128*4]  # [ARITH] Load A[m+3, k+6]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+6] * B[k+6,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+6] * B[k+6,n+8:n+16]
    vbroadcastss ymm3,  [rax+6*4+4*128*4]  # [ARITH] Load A[m+4, k+6]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+6] * B[k+6,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+6] * B[k+6,n+8:n+16]
                                                lzcnt        ecx,    ecx                        # [COUNT] CURRENT COUNTER Bump (R8)
                                                mov          esi,    r12d                       # [COUNT] CURRENT COUNTER Bump (R8)
                                           # [ARITH] K=7
    vmovaps      ymm4,  [rbx+7*160*4]      # [ARITH] Load B[k+7, n  :n+ 8]
    vmovaps      ymm5,  [rbx+7*160*4+32]   # [ARITH] Load B[k+7, n+8:n+16]
    vbroadcastss ymm3,  [rax+7*4+0*128*4]  # [ARITH] Load A[m+0, k+7]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+7] * B[k+7,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+7] * B[k+7,n+8:n+16]
    vbroadcastss ymm3,  [rax+7*4+1*128*4]  # [ARITH] Load A[m+1, k+7]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+7] * B[k+7,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+7] * B[k+7,n+8:n+16]
                                                shl          esi,    cl                         # [COUNT] CURRENT COUNTER Bump (R8)
                                                shr          esi,    cl                         # [COUNT] CURRENT COUNTER Bump (R8)
    vbroadcastss ymm3,  [rax+7*4+2*128*4]  # [ARITH] Load A[m+2, k+7]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+7] * B[k+7,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+7] * B[k+7,n+8:n+16]
    vbroadcastss ymm3,  [rax+7*4+3*128*4]  # [ARITH] Load A[m+3, k+7]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+7] * B[k+7,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+7] * B[k+7,n+8:n+16]
                                                xor          r8,     rsi                        # [COUNT] CURRENT COUNTER becomes NEXT
                                                mov          ecx,    r8d                        # [COUNT] = NEXT COUNTER
    vbroadcastss ymm3,  [rax+7*4+4*128*4]  # [ARITH] Load A[m+4, k+7]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+7] * B[k+7,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+7] * B[k+7,n+8:n+16]
                                           # [ARITH] K=8
    vmovaps      ymm4,  [rbx+8*160*4]      # [ARITH] Load B[k+8, n  :n+ 8]
    vmovaps      ymm5,  [rbx+8*160*4+32]   # [ARITH] Load B[k+8, n+8:n+16]
    vbroadcastss ymm3,  [rax+8*4+0*128*4]  # [ARITH] Load A[m+0, k+8]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+8] * B[k+8,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+8] * B[k+8,n+8:n+16]
                                                and          ecx,           KNmask              # [COUNT] = (n/32 << 14) = (n << 9)
                                                shr          ecx,           KNshft              # [COUNT] = (n << 2) = n*sizeof(float)
    vbroadcastss ymm3,  [rax+8*4+1*128*4]  # [ARITH] Load A[m+1, k+8]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+8] * B[k+8,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+8] * B[k+8,n+8:n+16]
    vbroadcastss ymm3,  [rax+8*4+2*128*4]  # [ARITH] Load A[m+2, k+8]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+8] * B[k+8,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+8] * B[k+8,n+8:n+16]
                                                mov          esi,    r8d                        # [COUNT] = NEXT COUNTER
                                                and          esi,           KPmask              # [COUNT] = (n&16) << 2
    vbroadcastss ymm3,  [rax+8*4+3*128*4]  # [ARITH] Load A[m+3, k+8]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+8] * B[k+8,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+8] * B[k+8,n+8:n+16]
    vbroadcastss ymm3,  [rax+8*4+8*128*4]  # [ARITH] Load A[m+4, k+8]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+8] * B[k+8,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+8] * B[k+8,n+8:n+16]
                                                shr          esi,           KPshft              # [COUNT] = (n&16) << 2 = (n&16)*sizeof(float)
                                                add          ecx,    esi                        # [COUNT] = n*sizeof(float)
                                           # [ARITH] K=9
    vmovaps      ymm4,  [rbx+9*160*4]      # [ARITH] Load B[k+9, n  :n+ 8]
    vmovaps      ymm5,  [rbx+9*160*4+32]   # [ARITH] Load B[k+9, n+8:n+16]
    vbroadcastss ymm3,  [rax+9*4+0*128*4]  # [ARITH] Load A[m+0, k+9]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+9] * B[k+9,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+9] * B[k+9,n+8:n+16]
    vbroadcastss ymm3,  [rax+9*4+1*128*4]  # [ARITH] Load A[m+1, k+9]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+9] * B[k+9,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+9] * B[k+9,n+8:n+16]
                                                mov          esi,    r8d                        # [COUNT] = NEXT COUNTER
                                                and          esi,           KMmask              # [COUNT] = (m/5 << 8)
    vbroadcastss ymm3,  [rax+9*4+2*128*4]  # [ARITH] Load A[m+2, k+9]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+9] * B[k+9,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+9] * B[k+9,n+8:n+16]
    vbroadcastss ymm3,  [rax+9*4+3*128*4]  # [ARITH] Load A[m+3, k+9]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+9] * B[k+9,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+9] * B[k+9,n+8:n+16]
                                                shl          esi,           2-KMshft            # [COUNT] = (m/5 << 9) = m/5*128*sizeof(float)
                                                lea          esi,   [esi+esi*4]                 # [COUNT] = m*128*sizeof(float)
    vbroadcastss ymm3,  [rax+9*4+4*128*4]  # [ARITH] Load A[m+4, k+9]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+9] * B[k+9,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+9] * B[k+9,n+8:n+16]
                                           # [ARITH] K=10
    vmovaps      ymm4,  [rbx+10*160*4]     # [ARITH] Load B[k+10, n  :n+ 8]
    vmovaps      ymm5,  [rbx+10*160*4+32]  # [ARITH] Load B[k+10, n+8:n+16]
    vbroadcastss ymm3,  [rax+10*4+0*128*4] # [ARITH] Load A[m+0, k+10]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+10] * B[k+10,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+10] * B[k+10,n+8:n+16]
    vbroadcastss ymm3,  [rax+10*4+1*128*4] # [ARITH] Load A[m+1, k+10]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+10] * B[k+10,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+10] * B[k+10,n+8:n+16]
    vbroadcastss ymm3,  [rax+10*4+2*128*4] # [ARITH] Load A[m+2, k+10]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+10] * B[k+10,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+10] * B[k+10,n+8:n+16]
    vbroadcastss ymm3,  [rax+10*4+3*128*4] # [ARITH] Load A[m+3, k+10]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+10] * B[k+10,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+10] * B[k+10,n+8:n+16]
    vbroadcastss ymm3,  [rax+10*4+4*128*4] # [ARITH] Load A[m+4, k+10]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+10] * B[k+10,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+10] * B[k+10,n+8:n+16]
                                           # [ARITH] K=11
    vmovaps      ymm4,  [rbx+11*160*4]     # [ARITH] Load B[k+11, n  :n+ 8]
    vmovaps      ymm5,  [rbx+11*160*4+32]  # [ARITH] Load B[k+11, n+8:n+16]
    vbroadcastss ymm3,  [rax+11*4+0*128*4] # [ARITH] Load A[m+0, k+11]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+11] * B[k+11,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+11] * B[k+11,n+8:n+16]
    vbroadcastss ymm3,  [rax+11*4+1*128*4] # [ARITH] Load A[m+1, k+11]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+11] * B[k+11,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+11] * B[k+11,n+8:n+16]
    vbroadcastss ymm3,  [rax+11*4+2*128*4] # [ARITH] Load A[m+2, k+11]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+11] * B[k+11,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+11] * B[k+11,n+8:n+16]
    vbroadcastss ymm3,  [rax+11*4+3*128*4] # [ARITH] Load A[m+3, k+11]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+11] * B[k+11,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+11] * B[k+11,n+8:n+16]
    vbroadcastss ymm3,  [rax+11*4+4*128*4] # [ARITH] Load A[m+4, k+11]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+11] * B[k+11,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+11] * B[k+11,n+8:n+16]
                                           # [ARITH] K=12
    vmovaps      ymm4,  [rbx+12*160*4]     # [ARITH] Load B[k+12, n  :n+ 8]
    vmovaps      ymm5,  [rbx+12*160*4+32]  # [ARITH] Load B[k+12, n+8:n+16]
    vbroadcastss ymm3,  [rax+12*4+0*128*4] # [ARITH] Load A[m+0, k+12]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+12] * B[k+12,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+12] * B[k+12,n+8:n+16]
    vbroadcastss ymm3,  [rax+12*4+1*128*4] # [ARITH] Load A[m+1, k+12]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+12] * B[k+12,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+12] * B[k+12,n+8:n+16]
    vbroadcastss ymm3,  [rax+12*4+2*128*4] # [ARITH] Load A[m+2, k+12]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+12] * B[k+12,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+12] * B[k+12,n+8:n+16]
    vbroadcastss ymm3,  [rax+12*4+3*128*4] # [ARITH] Load A[m+3, k+12]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+12] * B[k+12,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+12] * B[k+12,n+8:n+16]
    vbroadcastss ymm3,  [rax+12*4+4*128*4] # [ARITH] Load A[m+4, k+12]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+12] * B[k+12,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+12] * B[k+12,n+8:n+16]
                                           # [ARITH] K=13
    vmovaps      ymm4,  [rbx+13*160*4]     # [ARITH] Load B[k+13, n  :n+ 8]
    vmovaps      ymm5,  [rbx+13*160*4+32]  # [ARITH] Load B[k+13, n+8:n+16]
    vbroadcastss ymm3,  [rax+13*4+0*128*4] # [ARITH] Load A[m+0, k+13]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+13] * B[k+13,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+13] * B[k+13,n+8:n+16]
    vbroadcastss ymm3,  [rax+13*4+1*128*4] # [ARITH] Load A[m+1, k+13]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+13] * B[k+13,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+13] * B[k+13,n+8:n+16]
    vbroadcastss ymm3,  [rax+13*4+2*128*4] # [ARITH] Load A[m+2, k+13]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+13] * B[k+13,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+13] * B[k+13,n+8:n+16]
    vbroadcastss ymm3,  [rax+13*4+3*128*4] # [ARITH] Load A[m+3, k+13]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+13] * B[k+13,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+13] * B[k+13,n+8:n+16]
    vbroadcastss ymm3,  [rax+13*4+4*128*4] # [ARITH] Load A[m+4, k+13]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+13] * B[k+13,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+13] * B[k+13,n+8:n+16]
                                           # [ARITH] K=14
    vmovaps      ymm4,  [rbx+14*160*4]     # [ARITH] Load B[k+14, n  :n+ 8]
    vmovaps      ymm5,  [rbx+14*160*4+32]  # [ARITH] Load B[k+14, n+8:n+16]
    vbroadcastss ymm3,  [rax+14*4+0*128*4] # [ARITH] Load A[m+0, k+14]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+14] * B[k+14,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+14] * B[k+14,n+8:n+16]
    vbroadcastss ymm3,  [rax+14*4+1*128*4] # [ARITH] Load A[m+1, k+14]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+14] * B[k+14,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+14] * B[k+14,n+8:n+16]
    vbroadcastss ymm3,  [rax+14*4+2*128*4] # [ARITH] Load A[m+2, k+14]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+14] * B[k+14,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+14] * B[k+14,n+8:n+16]
    vbroadcastss ymm3,  [rax+14*4+3*128*4] # [ARITH] Load A[m+3, k+14]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+14] * B[k+14,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+14] * B[k+14,n+8:n+16]
    vbroadcastss ymm3,  [rax+14*4+4*128*4] # [ARITH] Load A[m+4, k+14]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+14] * B[k+14,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+14] * B[k+14,n+8:n+16]
                                           # [ARITH] K=15
    vmovaps      ymm4,  [rbx+15*160*4]     # [ARITH] Load B[k+15, n  :n+ 8]
    vmovaps      ymm5,  [rbx+15*160*4+32]  # [ARITH] Load B[k+15, n+8:n+16]
    vbroadcastss ymm3,  [rax+15*4+0*128*4] # [ARITH] Load A[m+0, k+15]
    vfmadd231ps  ymm6,   ymm3,  ymm4       # [ARITH]  => acc00 += A[0,k+15] * B[k+15,n:n+8]
    vfmadd231ps  ymm7,   ymm3,  ymm5       # [ARITH]  => acc01 += A[0,k+15] * B[k+15,n+8:n+16]
    vbroadcastss ymm3,  [rax+15*4+1*128*4] # [ARITH] Load A[m+1, k+15]
    vfmadd231ps  ymm8,   ymm3,  ymm4       # [ARITH]  => acc10 += A[1,k+15] * B[k+15,n:n+8]
    vfmadd231ps  ymm9,   ymm3,  ymm5       # [ARITH]  => acc11 += A[1,k+15] * B[k+15,n+8:n+16]
    vbroadcastss ymm3,  [rax+15*4+2*128*4] # [ARITH] Load A[m+2, k+15]
    vfmadd231ps  ymm10,  ymm3,  ymm4       # [ARITH]  => acc20 += A[2,k+15] * B[k+15,n:n+8]
    vfmadd231ps  ymm11,  ymm3,  ymm5       # [ARITH]  => acc21 += A[2,k+15] * B[k+15,n+8:n+16]
    vbroadcastss ymm3,  [rax+15*4+3*128*4] # [ARITH] Load A[m+3, k+15]
    vfmadd231ps  ymm12,  ymm3,  ymm4       # [ARITH]  => acc30 += A[3,k+15] * B[k+15,n:n+8]
    vfmadd231ps  ymm13,  ymm3,  ymm5       # [ARITH]  => acc31 += A[3,k+15] * B[k+15,n+8:n+16]
    vbroadcastss ymm3,  [rax+15*4+4*128*4] # [ARITH] Load A[m+4, k+15]
    vfmadd231ps  ymm14,  ymm3,  ymm4       # [ARITH]  => acc40 += A[4,k+15] * B[k+15,n:n+8]
    vfmadd231ps  ymm15,  ymm3,  ymm5       # [ARITH]  => acc41 += A[4,k+15] * B[k+15,n+8:n+16]
    addq         rax,    16*4              # [ARITH] Pointer Bump A[m, k+=16]
    addq         rbx,    16*160*4          # [ARITH] Pointer Bump B[k+=16, n]
    
    #
    # Inner Loop Exit Test
    #
    test         edi,    KKmask            # [ILOOP] Exit if old K == 0
    jnz .Lsgemm_zen2_bu_core_16x_unroll_accumulate
    
    #
    # Eject accumulators and clear.
    #
    vmovntps    [rdx+0*160*4],    ymm6     # [EJECT] C[0][n:n+8]
    vmovntps    [rdx+0*160*4+32], ymm7     # [EJECT] C[0][n+8:n+16]
    vxorps       ymm6,   ymm6,    ymm6
    vxorps       ymm7,   ymm7,    ymm7
    vmovntps    [rdx+1*160*4],    ymm8     # [EJECT] C[1][n:n+8]
    vmovntps    [rdx+1*160*4+32], ymm9     # [EJECT] C[1][n+8:n+16]
    vmovaps      ymm8,   ymm6
    vmovaps      ymm9,   ymm7
    vmovntps    [rdx+2*160*4],    ymm10    # [EJECT] C[2][n:n+8]
    vmovntps    [rdx+2*160*4+32], ymm11    # [EJECT] C[2][n+8:n+16]
    vmovaps      ymm10,  ymm6
    vmovaps      ymm11,  ymm7
    vmovntps    [rdx+3*160*4],    ymm12    # [EJECT] C[3][n:n+8]
    vmovntps    [rdx+3*160*4+32], ymm13    # [EJECT] C[3][n+8:n+16]
    vmovaps      ymm12,  ymm6
    vmovaps      ymm13,  ymm7
    vmovntps    [rdx+4*160*4],    ymm14    # [EJECT] C[4][n:n+8]
    vmovntps    [rdx+4*160*4+32], ymm15    # [EJECT] C[4][n+8:n+16]
    vmovaps      ymm14,  ymm6
    vmovaps      ymm15,  ymm7
    leaq         rax,   [r13+rsi]          # [EJECT] Install A-pointer
    leaq         rbx,   [r14+rcx]          # [EJECT] Install B-pointer
    
    #
    # Outer Loop Exit Test and Return R10
    #
    test         edi,    KKMNPmask         # [OLOOP] Test if old countdown register == 0
    jnz .Lsgemm_zen2_bu_core_16x_unroll_accumulate
    jmp          r10                       # [RET]   Return to *r10



    #
    ## Old eject logic
    #
    # leaq         rax,   [r13+rsi]          # [EJECT] Install A-pointer
    # leaq         rbx,   [r14+rcx]          # [EJECT] Install B-pointer
    # vmovaps      ymm4,  [rbx+0*160*4]      # [EJECT]     Load B[k+0, n  :n+ 8]
    # vmovaps      ymm5,  [rbx+0*160*4+32]   # [EJECT]     Load B[k+0, n+8:n+16]
    # vmovntps    [rdx+0*160*4],    ymm6     # [EJECT] C[0][n:n+8]
    # vmovntps    [rdx+0*160*4+32], ymm7     # [EJECT] C[0][n+8:n+16]
    # vbroadcastss ymm3,  [rax+0*4+0*128*4]  # [EJECT]     Load A[m+0, k+0]
    # vmulps       ymm6,   ymm3,  ymm4       # [EJECT]      => acc00 += A[0,k+0] * B[k,n:n+8]
    # vmulps       ymm7,   ymm3,  ymm5       # [EJECT]      => acc01 += A[0,k+0] * B[k,n+8:n+16]
    # vmovntps    [rdx+1*160*4],    ymm8     # [EJECT] C[1][n:n+8]
    # vmovntps    [rdx+1*160*4+32], ymm9     # [EJECT] C[1][n+8:n+16]
    # vbroadcastss ymm3,  [rax+0*4+1*128*4]  # [EJECT]     Load A[m+1, k+0]
    # vmulps       ymm8,   ymm3,  ymm4       # [EJECT]      => acc10 += A[1,k+0] * B[k,n:n+8]
    # vmulps       ymm9,   ymm3,  ymm5       # [EJECT]      => acc11 += A[1,k+0] * B[k,n+8:n+16]
    # vmovntps    [rdx+2*160*4],    ymm10    # [EJECT] C[2][n:n+8]
    # vmovntps    [rdx+2*160*4+32], ymm11    # [EJECT] C[2][n+8:n+16]
    # vbroadcastss ymm3,  [rax+0*4+2*128*4]  # [EJECT]     Load A[m+2, k+0]
    # vmulps       ymm10,  ymm3,  ymm4       # [EJECT]      => acc20 += A[2,k+0] * B[k,n:n+8]
    # vmulps       ymm11,  ymm3,  ymm5       # [EJECT]      => acc21 += A[2,k+0] * B[k,n+8:n+16]
    # vmovntps    [rdx+3*160*4],    ymm12    # [EJECT] C[3][n:n+8]
    # vmovntps    [rdx+3*160*4+32], ymm13    # [EJECT] C[3][n+8:n+16]
    # vbroadcastss ymm3,  [rax+0*4+3*128*4]  # [EJECT]     Load A[m+3, k+0]
    # vmulps       ymm12,  ymm3,  ymm4       # [EJECT]      => acc30 += A[3,k+0] * B[k,n:n+8]
    # vmulps       ymm13,  ymm3,  ymm5       # [EJECT]      => acc31 += A[3,k+0] * B[k,n+8:n+16]
    # vmovntps    [rdx+4*160*4],    ymm14    # [EJECT] C[4][n:n+8]
    # vmovntps    [rdx+4*160*4+32], ymm15    # [EJECT] C[4][n+8:n+16]
    # vbroadcastss ymm3,  [rax+0*4+4*128*4]  # [EJECT]     Load A[m+4, k+0]
    # vmulps       ymm14,  ymm3,  ymm4       # [EJECT]      => acc40 += A[4,k+0] * B[k,n:n+8]
    # vmulps       ymm15,  ymm3,  ymm5       # [EJECT]      => acc41 += A[4,k+0] * B[k,n+8:n+16]
    # test         edi,    KKMNPmask         # [OLOOP] Test if old countdown register == 0
    # jnz .Lsgemm_zen2_bu_core_16x_unroll_skip_first_iter

