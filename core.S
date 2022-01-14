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

#define K1     0b0000010000100001000100010000
#define KMmask 0b0111100000111110000000000000
#define KNmask 0b0000011111000001111000000000
#define KKmask 0b0000000000000000000111100000
#define KMmixm (25<<0|5<<10)
#define KNmixm ((5<<0|1<<9)<<5)
#define KMshft 23
#define KNshft 19
#define FMS(f,m,s) ((0x##f & 0xFF)<<12 | (0x##m & 0xFF)<<4 | (0x##s & 0xF))


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
    shld    eax,  edi, cl    # Shift in value bits into EAX from the right
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
# Nabla CPUID Access Function
#
#      uint32_t nabla_cpuid_x86(uint32_t buf[4], uint32_t ECX, uint32_t EAX, int select)
#
# Executes CPUID with register values ECX:EAX and writes result into buf if non-NULL.
# The return value is one selected register from CPUID's output:
#     EAX=0    EBX=1    ECX=2    EDX=3
#
.globl nabla_cpuid_x86
nabla_cpuid_x86:
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
#     uint32_t nabla_cpuid_x86_is_leaf_supported(uint32_t leaf)
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
.globl nabla_cpuid_x86_is_leaf_supported
nabla_cpuid_x86_is_leaf_supported:
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

nabla_cpuid_x86_is_leaf_01_supported:
    mov     edi,  1
    jmp nabla_cpuid_x86_is_leaf_supported

nabla_cpuid_x86_is_leaf_0b_supported:
    mov     edi,  0x0b
    jmp nabla_cpuid_x86_is_leaf_supported

nabla_cpuid_x86_is_leaf_80000008_supported:
    mov     edi,  0x80000008
    jmp nabla_cpuid_x86_is_leaf_supported


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
.globl nabla_cpuid_x86_family
.globl nabla_cpuid_x86_model
.globl nabla_cpuid_x86_stepping
.globl nabla_cpuid_x86_family_model_stepping
nabla_cpuid_x86_family:
    callq   nabla_cpuid_x86_family_model_stepping
    shr     eax,  12
    retq

nabla_cpuid_x86_model:
    callq   nabla_cpuid_x86_family_model_stepping
    shr     eax,  4
    and     eax,  0xFF
    retq

nabla_cpuid_x86_stepping:
    callq   nabla_cpuid_x86_family_model_stepping
    and     eax,  0xF
    retq

nabla_cpuid_x86_family_model_stepping:
    callq   nabla_cpuid_x86_is_leaf_01_supported
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
#
#     uint32_t nabla_cpuid_x86_apicid_initial(void);
#
# Returns 0 if Initial APIC ID cannot be detected.
#
.globl nabla_cpuid_x86_apicid_initial
nabla_cpuid_x86_apicid_initial:
    callq   nabla_cpuid_x86_is_leaf_01_supported
    mov     eax,  esi
    shr     eax,  24
    retq


#
# Nabla CPUID x86 x2APIC ID
#
#     uint32_t nabla_cpuid_x86_apicid_extended(void);
#
# Returns Init APIC ID if x2APIC ID cannot be detected.
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
.globl nabla_cpuid_x86_apicid_extended
nabla_cpuid_x86_apicid_extended:
    callq   nabla_cpuid_x86_is_leaf_0b_supported
    jz nabla_cpuid_x86_apicid_initial # If Extended Topology Enumeration Leaf not available, tail-call for Init APIC ID
    test    esi,  esi                 # [LEAF_Bh] Test if LogicalProcessorCount > 0.
    jz nabla_cpuid_x86_apicid_initial # [LEAF_Bh] ... if not usable, tail-call for Init APIC ID
    mov     eax,  edx                 # [LEAF_Bh] Place x2APIC ID in EAX for return
    retq                              # [LEAF_Bh] Return


#
# Nabla CPUID x86 APIC ID Mask Logical Core
#
#     uint32_t nabla_cpuid_x86_apicid_mask_core_logical(void);
#
# Returns the APIC ID mask for *logical* cores, including the thread sub-ID if any.
#
#   - If the mask cannot be detected, return all-ones mask (equivalently,
#     assume all logical cores are part of the same package)
#   - If package is 1C/1T, return all-zeroes mask.
#
.globl nabla_cpuid_x86_apicid_mask_core_logical
nabla_cpuid_x86_apicid_mask_core_logical:
    callq   nabla_cpuid_x86_is_amd_or_hygon
    jz    .Lnabla_cpuid_x86_apicid_mask_core_logical_try_leaf_0b
    callq   nabla_cpuid_x86_is_leaf_80000008_supported
    jz    .Lnabla_cpuid_x86_apicid_mask_core_logical_try_leaf_0b
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
.Lnabla_cpuid_x86_apicid_mask_core_logical_try_leaf_0b:
    callq   nabla_cpuid_x86_is_leaf_0b_supported
    jz    .Lnabla_cpuid_x86_apicid_mask_core_logical_try_leaf_01
    test    ebx,  ebx        # [LEAF_Bh] Check Leaf B usable
    jz    .Lnabla_cpuid_x86_apicid_mask_core_logical_try_leaf_01
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
.Lnabla_cpuid_x86_apicid_mask_core_logical_try_leaf_01:
    callq   nabla_cpuid_x86_is_leaf_01_supported
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
#     uint32_t nabla_cpuid_x86_apicid_mask_package(void);
#
.globl nabla_cpuid_x86_apicid_mask_package
nabla_cpuid_x86_apicid_mask_package:
    callq nabla_cpuid_x86_apicid_mask_core_logical
    not   eax
    retq


#
# Nabla CPUID x86 APIC ID Mask SMT
#
#     uint32_t nabla_cpuid_x86_apicid_mask_smt(void);
#
.globl nabla_cpuid_x86_apicid_mask_smt
nabla_cpuid_x86_apicid_mask_smt:
    callq   nabla_cpuid_x86_is_leaf_0b_supported
    jz 0f             # If Extended Topology Enumeration Leaf not available, mask=0
    xor     eax,  eax # [LEAF_Bh] Prepare Indeterminate SMT Mask
    test    esi,  esi # [LEAF_Bh] Test if LogicalProcessorCount > 0.
    jz 0f             # [LEAF_Bh] ... if not usable, return 0
    push    rbx       # [LEAF_Bh] Save RBX
    mov     ecx,  edi # [LEAF_Bh] Prepare shift count from CPUID.11.EAX[4:0]
    mov     ebx,  1   # [LEAF_Bh] Begin creating SMT mask
    shl     ebx,  cl  # [LEAF_Bh] Compute 1<<CPUID.11.EAX[4:0]
    dec     ebx       # [LEAF_Bh] -1 sets all bits below bit CPUID.11.EAX[4:0]
    callq   nabla_cpuid_x86_apicid_mask_core_logical
    and     eax,  ebx # [LEAF_Bh] SMT mask is strict subset of thread mask
    popq    rbx       # [LEAF_Bh] Restore RBX
0:  retq              # Return


#
# Nabla CPUID x86 APIC ID Mask Physical Core within package
#
# Returns the APIC ID mask for *physical* cores, excluding the thread sub-ID.
#
#     uint32_t nabla_cpuid_x86_apicid_mask_core_physical(void);
#
.globl nabla_cpuid_x86_apicid_mask_core_physical
nabla_cpuid_x86_apicid_mask_core_physical:
    callq nabla_cpuid_x86_apicid_mask_smt
    pushq rax
    callq nabla_cpuid_x86_apicid_mask_core_logical
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
#     uint32_t nabla_cpuid_x86_apicid_mask_core_llc(void);
#
.globl nabla_cpuid_x86_apicid_mask_core_llc
nabla_cpuid_x86_apicid_mask_core_llc:
    callq   nabla_cpuid_x86_is_amd_or_hygon
    jz 0f
    callq   nabla_cpuid_x86_apicid_mask_amd_ccd
    pushq   rax
    callq   nabla_cpuid_x86_apicid_mask_amd_ccx
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
#     uint32_t nabla_cpuid_x86_apicid_mask_amd_ccd(void);
#     uint32_t nabla_cpuid_x86_apicid_mask_amd_ccx(void);
#
.globl nabla_cpuid_x86_apicid_mask_amd_ccd
.globl nabla_cpuid_x86_apicid_mask_amd_ccx
nabla_cpuid_x86_apicid_mask_amd_ccd:
    callq   nabla_cpuid_x86_is_amd_or_hygon
    jz  0f
    callq   nabla_cpuid_x86_family_model_stepping
    mov     edx,  eax
    xor     eax,  eax
    cmp     edx,  FMS(17,00,0)      # Pre-Zen AMD CPUs
    jl  0f
    cmp     edx,  FMS(19,FF,F)      # Very new, unknown post-Zen 5 AMD CPU
    jg  0f
    callq   nabla_cpuid_x86_microarchitecture
    mov     rdi,  rax
    mov     eax,  -16
    leaq    rdx, [rip+.Luarch_zen]  # Zen/Zen+: Bits 4 and up identify CCD within package.
    cmpq    rdx,  rdi
    je  1f
    leaq    rdx, [rip+.Luarch_zenp] # Zen/Zen+: Bits 4 and up identify CCD within package.
    cmpq    rdx,  rdi
    je  1f
    callq   nabla_cpuid_x86_apicid_mask_smt
    not     eax                     # Zen 2/Zen 3 (and above?): 8 physical cores per CCD;
    shl     eax,  3                 # SMT ID, if present, occupies additional low-order bits.
1:  pushq   rax
    callq   nabla_cpuid_x86_apicid_mask_core_logical
    popq    rcx                     # CCD ID bits are top-level within a package, so mask
    and     eax,  ecx               # them by the logical core mask.
0:  retq

nabla_cpuid_x86_apicid_mask_amd_ccx:
    callq   nabla_cpuid_x86_is_amd_or_hygon
    jz  0b
    callq   nabla_cpuid_x86_microarchitecture
    mov     rdi,  rax
    mov     eax,  0b1000
    leaq    rdx, [rip+.Luarch_zen]  # Zen/Zen+: Bit 3 identifies CCX within CCD.
    cmpq    rdx,  rdi
    je  1b
    leaq    rdx, [rip+.Luarch_zenp] # Zen/Zen+: Bit 3 identifies CCX within CCD.
    cmpq    rdx,  rdi
    je  1b
    xor     eax,  eax
    leaq    rdx, [rip+.Luarch_zen2] # Not Zen/Zen+/Zen 2: No CCX distinct from CCD.
    cmpq    rdx,  rdi
    jne 0b
    callq   nabla_cpuid_x86_apicid_mask_smt
    inc     eax                     # Zen 2: 4 physical cores per CCD;
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
.globl nabla_cpuid_x86_is_amd
.globl nabla_cpuid_x86_is_intel
.globl nabla_cpuid_x86_is_hygon
.globl nabla_cpuid_x86_is_amd_or_hygon
nabla_cpuid_x86_is_amd:
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

nabla_cpuid_x86_is_intel:
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

nabla_cpuid_x86_is_hygon:
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

nabla_cpuid_x86_is_amd_or_hygon:
    callq   nabla_cpuid_x86_is_amd    # Unconditional straight call
    jz      nabla_cpuid_x86_is_hygon  # Conditional tail-call
    retq


#
# Nabla CPUID x86 microarchitecture
#
.globl nabla_cpuid_x86_microarchitecture
nabla_cpuid_x86_microarchitecture:
    pushq   rbx        # Save RBX
    callq   nabla_cpuid_x86_is_amd_or_hygon
    jnz   .Lnabla_cpuid_x86_microarchitecture_amd
    callq   nabla_cpuid_x86_is_intel
    jnz   .Lnabla_cpuid_x86_microarchitecture_intel
    lea     rdi, [rip+.Luarch_unknown]
0:  mov     rax,  rdi
    popq    rbx        # Restore RBX
    retq

.Lnabla_cpuid_x86_microarchitecture_amd:
    callq   nabla_cpuid_x86_family_model_stepping
    mov     ecx,  eax
    shr     ecx,  7
    
    # [FAMILY UNKNOWN]
    lea     rdi, [rip+.Luarch_unknown_amd]
    test    eax,  eax
    jz  0b
    
    # [FAMILY <15h, Extremely old, 32-bit (<K8)]
    cmp     eax,  FMS(15,00,0)
    jl  0b
    
    # [FAMILY <17h, Old, 64-bit (<Zen)]
    cmp     eax,  FMS(17,00,0)
    jl  0b
    
    # [FAMILY  17h (Zen/Zen+/Zen 2)]
    cmp     eax,  FMS(17,FF,F)
    jg  2f
    lea     rdi, [rip+.Luarch_zen2]
    mov     edx,  0b11111111111111111111110011000000
    #                                     //  //|||\
    #                                    //  // ||\ Summit Ridge/Snowy Owl/Whitehaven/Naples, Zen
    #                    FireFlight, Zen+   //  |\ Pinnacle Ridge/Colfax, Zen+
    #                              Dali, Zen    | Raven Ridge/Great Horned Owl, Zen
    #                            Picasso/Banded Kestrel, Zen+/Zen
    shr     edx,  cl
    test    edx,  1
    jnz 0b
    lea     rdi, [rip+.Luarch_zenp]
    cmp     ecx,  FMS(17,18,0)>>7  #   Family 17h Model 18h is ambiguous.
    je  1f
    mov     edx,                        0b1100001010
    #                                     //  //|||\
    #                                    //  // ||\ Summit Ridge/Snowy Owl/Whitehaven/Naples, Zen
    #                    FireFlight, Zen+   //  |\ Pinnacle Ridge/Colfax, Zen+
    #                              Dali, Zen    | Raven Ridge/Great Horned Owl, Zen
    #                            Picasso/Banded Kestrel, Zen+/Zen
    shr     edx,  cl
    test    edx,  1                #   Family 17h, Zen+?
    jnz 0b
    lea     rdi, [rip+.Luarch_zen] #   Family 17h, all other models assumed Zen.
    jmp 0b
    #
    # Unfortunately, Banded Kestrel and Picasso cannot be distinguished by FMS,
    # yet they differ in microarchitecture. Use core configuration instead:
    #
    #   - Banded Kestrel has 2C/4T only
    #   - Picasso        has 4C/4T and upwards
    #
    # Use Leaf 0x0B and divide threads/package (Subleaf 1)
    #                       by threads/core    (Subleaf 0).
    # We know these are the only topology levels reported by CPUID because we
    # can only get here if CPUID gives Family 17h Model 18h, and both Banded
    # Kestrel and Picasso have symmetric core designs. Banded Kestrel is very
    # unlikely; If there are any failures, assume Picasso, Zen+.
    #
1:  callq   nabla_cpuid_x86_is_leaf_0b_supported
    lea     rdi, [rip+.Luarch_zenp]
    jz 0b              # Leaf 0x0B unavailable
    test    esi,  esi  # Check threads/core > 0
    jz 0b              # Leaf 0x0B available but unusable
    mov     eax,  11
    mov     ecx,  1
    cpuid
    tzcnt   ecx,  esi  # Compute threads/core trailing-zero count
    shr     ebx,  cl   # Divide  threads/package / threads/core -> cores/package
    lea     rdi, [rip+.Luarch_zenp]
    cmp     ebx,  2
    jne 0b             # Leaf 0x0B unavailable or core count != 2, assume  Picasso, Zen+
    lea     rdi, [rip+.Luarch_zen]
    jmp 0b             # Leaf 0x0B available  and core count == 2, must be Banded Kestrel, Zen
    
    
    # [FAMILY  18h, Hygon Dhyana (Zen)]
2:  lea     rdi, [rip+.Luarch_zen]
    cmp     eax,  FMS(18,FF,F)
    jle 0b
    
    
    # [FAMILY  19h (Zen 3/Zen 3+/Zen 4/Zen 4c/Zen 5/...)]
    lea     rdi, [rip+.Luarch_unknown_amd]
    cmp     eax,  FMS(19,FF,F)     # Too new, unknown processor models newer than Zen 4/Zen 5.
    jg  0b
    lea     rdi, [rip+.Luarch_zen3]
    mov     edx,  0b00000000000000000000010001010011
    #                                    /   / \  |\
    #                                   /   /   \  \ Genesis Peak/Milan/Milan-X
    #                            Cezanne   /     \ Chagall
    #                                  Trento   Vermeer
    shr     edx,  cl
    test    edx,  1
    jnz 0b
    lea     rdi, [rip+.Luarch_zen3p]
    mov     edx,  0b00000000000000000000000100000000
    #                                      |
    #                                  Rembrandt
    shr     edx,  cl
    test    edx,  1
    jnz 0b
    lea     rdi, [rip+.Luarch_zen4]
    mov     edx,  0b00000000000000000101000000000100
    #                                / \         |
    #                         Phoenix  Raphael  Genoa
    shr     edx,  cl
    test    edx,  1
    jnz 0b
    lea     rdi, [rip+.Luarch_zen4c]
    mov     edx,  0b00000000000100000000000000000000
    #                          |
    #                       Bergamo
    shr     edx,  cl
    test    edx,  1
    jnz 0b
    lea     rdi, [rip+.Luarch_zen5]
    mov     edx,  0b00000000000000000000000000001000
    #                                           |
    #                                      Strix Point?
    shr     edx,  cl
    test    edx,  1
    jnz 0b
    lea     rdi, [rip+.Luarch_unknown_amd]
    jmp 0b

.Lnabla_cpuid_x86_microarchitecture_intel:
    lea     rdi, [rip+.Luarch_unknown_intel]
    mov     eax,  1
    cpuid
    lea     rdi, [rip+.Luarch_unknown_intel]
    jmp 0b


#
# SGEMM Modulo-Decrement Test Function
#
# Coordinate System:
#     Name:                 Mb : Nb : Ma : Na : k8 : 00000
#     Max:                  15    4    4    4    7   0
#     Bits:                  5    5    5    4    4   5
#     Offset:               23   18   13    9    5   0
#
.globl sgemm_mod_count
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
.globl sgemm_bu_core_entry    # Purely for debug information, DO NOT CALL DIRECTLY!
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
