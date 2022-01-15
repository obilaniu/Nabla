/* Includes */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <pthread.h>

#include <sched.h>
#include <unistd.h>
#include <sys/mman.h>



/* Defines */
#define CL_SIZE 64



/* Data Structure Declaration */
typedef struct nabla_cpuid_generic_t       nabla_cpuid_t;
typedef struct nabla_cpuid_generic_t       nabla_cpuid_generic_t;
typedef struct nabla_cpuid_0000000b_t      nabla_cpuid_0000000b_t;
typedef struct nabla_cpuid_80000001_amd_t  nabla_cpuid_80000001_amd_t;
typedef struct nabla_cpuid_80000008_amd_t  nabla_cpuid_80000008_amd_t;
typedef struct nabla_cpuid_8000001d_amd_t  nabla_cpuid_8000001d_amd_t;
typedef struct nabla_cpuid_8000001e_amd_t  nabla_cpuid_8000001e_amd_t;
struct nabla_cpuid_generic_t{
    uint32_t eax, ebx, ecx, edx;
};
struct nabla_cpuid_0000000b_t{
    /* EAX */
    uint32_t next_level_shift  :  5;
    uint32_t _pad0             : 27;
    /* EBX */
    uint32_t logical_proc_count: 16;
    uint32_t _pad1             : 16;
    /* ECX */
    uint32_t input             :  8;
    uint32_t level_type        :  8;/* 00h: Invalid, 01h: Thread, 02h: Processor */
    uint32_t _pad2             : 16;
    /* EDX */
    uint32_t ext_apic_id;
};
struct nabla_cpuid_80000001_amd_t{
    /* EAX */
    uint32_t stepping          :  4;
    uint32_t base_model        :  4;
    uint32_t base_family       :  4;
    uint32_t _pad0             :  4;
    uint32_t ext_model         :  4;
    uint32_t ext_family        :  8;
    uint32_t _pad1             :  4;
    /* EBX */
    uint32_t brand_id          : 16;
    uint32_t _pad2             : 12;
    uint32_t pkg_type          :  4;
    /* ECX */
    uint32_t lahf_lm           :  1; /* LAHF/SAHF in long mode */
    uint32_t cmp_legacy        :  1; /* Core multi-processing legacy */
    uint32_t svm               :  1;
    uint32_t extapic           :  1;
    uint32_t cr8_legacy        :  1; /*  4 */
    uint32_t abm               :  1;
    uint32_t sse4a             :  1;
    uint32_t misalignsse       :  1;
    uint32_t threednowprefetch :  1; /* PREFETCH[W] instructions */
    uint32_t osvw              :  1;
    uint32_t ibs               :  1;
    uint32_t xop               :  1;
    uint32_t skinit            :  1; /* 12 */
    uint32_t wdt               :  1;
    uint32_t _pad3             :  1;
    uint32_t lwp               :  1;
    uint32_t fma4              :  1; /* 16 */
    uint32_t tce               :  1;
    uint32_t cvt16             :  1;
    uint32_t nodeid_msr        :  1;
    uint32_t _pad4             :  1; /* 20 */
    uint32_t tbm               :  1;
    uint32_t topoext           :  1; /* 22 */
    uint32_t perfctr_core      :  1;
    uint32_t perfctr_nb        :  1; /* 24 */
    uint32_t _pad5             :  1;
    uint32_t bpext             :  1;
    uint32_t perftsc           :  1;
    uint32_t perfctr_llc       :  1; /* 28 */
    uint32_t mwaitx            :  1;
    uint32_t addr_mask_extn    :  1;
    uint32_t _pad6             :  1;
    /* EDX */
    uint32_t fpu               :  1; /* x87 FPU */
    uint32_t vme               :  1; /* Virtual Mode Extensions */
    uint32_t de                :  1; /* Debug Extensions */
    uint32_t pse               :  1; /* Page Size Extension */
    uint32_t tsc               :  1; /* Time Stamp Counter */
    uint32_t msr               :  1; /* Model Specific Register */
    uint32_t pae               :  1; /* Physical Address Extension */
    uint32_t mce               :  1; /* Machine Check Exception */
    uint32_t cx8               :  1; /* CMPXCHG8B */
    uint32_t apic              :  1; /* Advanced Programmable Interrupt Controller exists and enabled */
    uint32_t _pad7             :  1;
    uint32_t sep               :  1; /* SYSENTER/SYSEXIT */
    uint32_t mtrr              :  1; /* 12 */
    uint32_t pge               :  1;
    uint32_t mca               :  1;
    uint32_t cmov              :  1;
    uint32_t pat               :  1; /* 16 */
    uint32_t pse36             :  1;
    uint32_t _pad8             :  2;
    uint32_t nx                :  1; /* 20 */
    uint32_t _pad9             :  1;
    uint32_t mmxext            :  1;
    uint32_t mmx               :  1;
    uint32_t fxsr              :  1; /* 24 */
    uint32_t fxsr_opt          :  1;
    uint32_t pdpe1gb           :  1; /* 1GB pages */
    uint32_t rdtscp            :  1;
    uint32_t _pad10            :  1; /* 28 */
    uint32_t lm                :  1; /* Long Mode */
    uint32_t threednowext      :  1; /* 3DNow! Extensions */
    uint32_t threednow         :  1; /* 3DNow! */
};
struct nabla_cpuid_80000008_amd_t{
    /* EAX */
    uint32_t phys_addr_size         :  8;
    uint32_t lin_addr_size          :  8;
    uint32_t guest_phys_addr_size   :  8;
    uint32_t _pad0                  :  8;
    /* EBX */
    uint32_t clzero                 :  1;/* Clear Zero Instruction */
    uint32_t irperf                 :  1;/* Instructions Retired Count support */
    uint32_t xsaveerptr             :  1;
    uint32_t _pad1                  :  1;
    uint32_t rdpru                  :  1;/* Read APERF/MPERF at user level */
    uint32_t _pad2                  :  1;
    uint32_t mbe                    :  1;/* Memory Bandwidth Enforcement */
    uint32_t _pad3                  :  1;
    uint32_t mcommit                :  1;
    uint32_t wbnoinvd               :  1;
    uint32_t _pad4                  :  2;
    uint32_t ibpb                   :  1;/* Indirect Branch Prediction Barrier */
    uint32_t int_wbinvd             :  1;/* Interruptible WBINVD/WBNOINVD */
    uint32_t ibrs                   :  1;/* Indirect Branch Restricted Speculation */
    uint32_t stibp                  :  1;/* Single Thread Indirect Branch Prediction */
    uint32_t _pad5                  :  1;/* 16 */
    uint32_t stibp_always_on        :  1;/* STIBP Always On */
    uint32_t ibrs_preferred         :  1;/* IBRS Preferred */
    uint32_t ibrs_same_mode_prot    :  1;/* IBRS provides Same Mode Protection */
    uint32_t efer_lmsle_unsupported :  1;/* Long Mode Segment Limit Enable check is not supported */
    uint32_t _pad6                  :  2;/* 21-22 */
    uint32_t ppin                   :  1;/* Protected Processor Inventory Number */
    uint32_t ssbd                   :  1;/* Speculative Store Bypass Disable */
    uint32_t _pad7                  :  2;/* 25-26 */
    uint32_t cppc                   :  1;/* Collaborative Processor Performance Control */
    uint32_t psfd                   :  1;/* Predictive Store Forward Disable */
    uint32_t _pad8                  :  3;/* 29-31 */
    /* ECX */
    uint32_t nc                     :  8;/* Number of Threads in Package. Biased - 1 */
    uint32_t _pad9                  :  4;
    uint32_t apic_id_size           :  4;
    uint32_t perf_tsc_size          :  2;
    uint32_t _pad10                 : 14;
    /* EDX */
    uint32_t _pad11                 : 16;
    uint32_t rdpru_max              :  8;/* Maximum input in ECX to RDPRU instruction. */
    uint32_t _pad12                 :  8;
};
struct nabla_cpuid_8000001d_amd_t{
    /* EAX */
    uint32_t type        :  5;
    uint32_t level       :  3;
    uint32_t self_init   :  1;
    uint32_t fully_assoc :  1;
    uint32_t _pad0       :  4;
    uint32_t num_sharing : 12;
    uint32_t _pad1       :  6;
    /* EBX */
    uint32_t L           : 12;/* Cache Line Size,             biased - 1 */
    uint32_t P           : 10;/* Cache Physical Partitions,   biased - 1 */
    uint32_t W           : 10;/* Cache Ways of Associativity, biased - 1 */
    /* ECX */
    uint32_t S;               /* Cache Sets,                  biased - 1 */
    /* EDX */
    uint32_t wbinvd      :  1;
    uint32_t inclusive   :  1;
    uint32_t _pad2       : 30;
};
struct nabla_cpuid_8000001e_amd_t{
    /* EAX */
    uint32_t ext_apic_id;
    /* EBX */
    uint32_t core_id             :  8;
    uint32_t threads_per_core    :  8;/* Biased - 1 */
    uint32_t _pad0               : 16;
    /* ECX */
    uint32_t node_id             :  8;
    uint32_t nodes_per_processor :  3;/* Biased - 1 */
    uint32_t _pad1               : 21;
    /* EDX */
    uint32_t _pad2;
};



/* Static Asserts */
_Static_assert(sizeof(pthread_mutex_t) <= CL_SIZE,
               "pthread mutex larger than a cacheline!");
_Static_assert(sizeof(nabla_cpuid_generic_t) == 16,
               "struct nabla_cpuid_generic_t must be exactly 16 bytes!");
_Static_assert(sizeof(nabla_cpuid_0000000b_t) == sizeof(nabla_cpuid_generic_t),
               "struct nabla_cpuid_0000000b_t must be exactly of the same size as nabla_cpuid_generic_t!");
_Static_assert(sizeof(nabla_cpuid_80000001_amd_t) == sizeof(nabla_cpuid_generic_t),
               "struct nabla_cpuid_80000001_amd_t must be exactly of the same size as nabla_cpuid_generic_t!");
_Static_assert(sizeof(nabla_cpuid_80000008_amd_t) == sizeof(nabla_cpuid_generic_t),
               "struct nabla_cpuid_80000008_amd_t must be exactly of the same size as nabla_cpuid_generic_t!");
_Static_assert(sizeof(nabla_cpuid_8000001d_amd_t) == sizeof(nabla_cpuid_generic_t),
               "struct nabla_cpuid_8000001d_amd_t must be exactly of the same size as nabla_cpuid_generic_t!");
_Static_assert(sizeof(nabla_cpuid_8000001e_amd_t) == sizeof(nabla_cpuid_generic_t),
               "struct nabla_cpuid_8000001e_amd_t must be exactly of the same size as nabla_cpuid_generic_t!");



/* Extern Function Declarations */
extern char*       nabla_uint32tobin(char buf[33], uint32_t v);
extern uint32_t    nabla_pext32(uint32_t v, uint32_t sel);
extern uint32_t    nabla_lzcnt32(uint32_t v);
extern uint32_t    nabla_tzcnt32(uint32_t v);
extern uint32_t    nabla_popcnt32(uint32_t v);
extern uint32_t    nabla_cpuid_x86(void* regs, uint32_t leaf, uint32_t subleaf, int sel);
extern uint32_t    nabla_cpuid_x86_is_leaf_supported(uint32_t leaf);
extern uint32_t    nabla_cpuid_x86_family(void);
extern uint32_t    nabla_cpuid_x86_model(void);
extern uint32_t    nabla_cpuid_x86_stepping(void);
extern uint32_t    nabla_cpuid_x86_family_model_stepping(void);
extern int         nabla_cpuid_x86_is_amd(void);
extern int         nabla_cpuid_x86_is_intel(void);
extern int         nabla_cpuid_x86_is_hygon(void);
extern int         nabla_cpuid_x86_is_amd_or_hygon(void);
extern const char* nabla_cpuid_x86_microarchitecture(void);
extern uint32_t    nabla_cpuid_x86_apicid_initial(void);
extern uint32_t    nabla_cpuid_x86_apicid_extended(void);
extern uint32_t    nabla_cpuid_x86_apicid_mask_smt(void);
extern uint32_t    nabla_cpuid_x86_apicid_mask_core_logical(void);
extern uint32_t    nabla_cpuid_x86_apicid_mask_core_physical(void);
extern uint32_t    nabla_cpuid_x86_apicid_mask_core_llc(void);
extern uint32_t    nabla_cpuid_x86_apicid_mask_package(void);
extern uint32_t    nabla_cpuid_x86_apicid_mask_amd_ccd(void);
extern uint32_t    nabla_cpuid_x86_apicid_mask_amd_ccx(void);



/**
 * Main
 */

int main(int argc, char* argv[]){
    (void)argc;
    (void)argv;
    int i,j;
    
#if 1
    const int EAX=0, EBX=1, ECX=2, EDX=3;
    int       smt;
    char      procbrand[64];
    char      x2apicidbin[33];
    uint32_t  initapicid, x2apicid, x2apicidsupport;
    uint32_t  masklvl, masksub, maskccx, maskccd,
              masksmt, masklog, maskphy, maskpkg;
    nabla_cpuid_generic_t      manubrand;
    nabla_cpuid_0000000b_t     topoleaf;
    nabla_cpuid_80000001_amd_t featuresext;
    nabla_cpuid_80000008_amd_t leafx08;
    nabla_cpuid_8000001d_amd_t cachelv;
    nabla_cpuid_8000001e_amd_t extapicid;
    
    if(!nabla_cpuid_x86_is_leaf_supported(1))
        return fprintf(stderr, "No CPUID leaves!\n"), 1;
    if(!nabla_cpuid_x86_is_leaf_supported(0x80000001))
        return fprintf(stderr, "No CPUID extended leaves!\n"), 1;
    
    nabla_cpuid_x86(&manubrand,    0,          0, EAX);
    nabla_cpuid_x86(&featuresext,  0x80000001, 0, EAX);
    nabla_cpuid_x86(procbrand+ 0,  0x80000002, 0, EAX);
    nabla_cpuid_x86(procbrand+16,  0x80000003, 0, EBX);
    nabla_cpuid_x86(procbrand+32,  0x80000004, 0, ECX);
    nabla_cpuid_x86(procbrand+48,  0x80000005, 0, EDX);
    nabla_cpuid_x86(&leafx08,      0x80000008, 0, EAX);
    nabla_cpuid_x86(&extapicid,    0x8000001E, 0, EAX);
    initapicid      = nabla_cpuid_x86_apicid_initial();
    x2apicid        = nabla_cpuid_x86_apicid_extended();
    x2apicidsupport = nabla_cpuid_x86_is_leaf_supported(0x0B) &&
                      nabla_cpuid_x86(0, 0x0B, 0, EBX);
    nabla_uint32tobin(x2apicidbin, x2apicid);
    smt     = nabla_cpuid_x86_is_leaf_supported(0x8000001E) &&
              extapicid.threads_per_core > 0;
    masksmt = nabla_cpuid_x86_apicid_mask_smt();
    masklog = nabla_cpuid_x86_apicid_mask_core_logical();
    maskphy = nabla_cpuid_x86_apicid_mask_core_physical();
    maskpkg = nabla_cpuid_x86_apicid_mask_package();
    maskccx = nabla_cpuid_x86_apicid_mask_amd_ccx();
    maskccd = nabla_cpuid_x86_apicid_mask_amd_ccd();
    masksub = maskphy^maskccx^maskccd;
    
    fprintf(stdout,
            "Manufacturer Brand String:     %4.4s%4.4s%4.4s%s\n"
            "Processor Brand String:        %s\n"
            "Processor CPUID Code:          %06X\n"
            "Processor Family:              %Xh (%d)\n"
            "Processor Model:               %Xh (%d)\n"
            "Processor Stepping:            %d\n"
            "Processor Microarchitecture:   %s\n"
            "Max CPUID leaf/extended leaf:  %02Xh/%08Xh\n"
            "SMT:                           %d-way\n"
            "Init APIC ID:                  %u\n"
            "x2APIC ID:                     %-10u%s\n"
            "APIC SMT ID:                   %-10u (mask: %08x)\n"
            "APIC Logical Core ID:          %-10u (mask: %08x, %d bits)\n"
            "APIC Physical Core ID:         %-10u (mask: %08x)\n"
            "APIC Package ID:               %-10u (mask: %08x)\n",
            (const char*)&manubrand.ebx,
            (const char*)&manubrand.edx,
            (const char*)&manubrand.ecx,
            (nabla_cpuid_x86_is_amd()   ? " (AMD)"   :
             nabla_cpuid_x86_is_intel() ? " (Intel)" :
             nabla_cpuid_x86_is_hygon() ? " (Hygon)" : ""),
            procbrand,
            nabla_cpuid_x86(0, 1, 0, EAX),
            nabla_cpuid_x86_family(),   nabla_cpuid_x86_family(),
            nabla_cpuid_x86_model(),    nabla_cpuid_x86_model(),
            nabla_cpuid_x86_stepping(), nabla_cpuid_x86_microarchitecture(),
            nabla_cpuid_x86_is_leaf_supported(0),
            nabla_cpuid_x86_is_leaf_supported(0x80000000),
            smt+1, initapicid, x2apicid,
            x2apicidsupport ? " (x2APIC ID available)" : " (inferred as initial APIC ID)",
            nabla_pext32(x2apicid, masksmt), masksmt,
            nabla_pext32(x2apicid, masklog), masklog, nabla_popcnt32(masklog),
            nabla_pext32(x2apicid, maskphy), maskphy,
            nabla_pext32(x2apicid, maskpkg), maskpkg);
    
    if(nabla_cpuid_x86_is_amd_or_hygon())
        fprintf(stdout,
                "APIC AMD CCD ID:               %-10u (mask: %08x)\n"
                "APIC AMD CCX ID:               %-10u (mask: %08x)\n",
                nabla_pext32(x2apicid, maskccd), maskccd,
                nabla_pext32(x2apicid, maskccx), maskccx);
    
    if(nabla_cpuid_x86_is_leaf_supported(0x0B)){
        for(i=j=0; nabla_cpuid_x86(&topoleaf, 0x0B, i, 0),
                   topoleaf.level_type; i++,j=topoleaf.next_level_shift){
            if(!i)
                fprintf(stdout,
                        "PROCESSOR HIERARCHY\n"
                        "  TYPE   #PROCS  BITFIELD  SHIFT   X2APICID:---+---|---+---:---+---| = %u\n",
                        topoleaf.ext_apic_id);
            
            masklvl = (1U<<topoleaf.next_level_shift) - (1U<<j);
            fprintf(stdout,
                    "  %-8s %4d  [%2d+:%-2d] %4d      %*.*s%*s = %u\n",
                    (topoleaf.level_type == 1 ? "SMT"  : (
                     topoleaf.level_type == 2 ? "Core" : "?")),
                    topoleaf.logical_proc_count,
                    nabla_tzcnt32(masklvl),
                    nabla_popcnt32(masklvl),
                    topoleaf.next_level_shift,
                    32-nabla_tzcnt32(masklvl),
                    nabla_popcnt32(masklvl),
                    x2apicidbin+nabla_lzcnt32(masklvl),
                    nabla_tzcnt32(masklvl), "",
                    nabla_pext32(x2apicid, masklvl));
            
            if(nabla_cpuid_x86_is_amd_or_hygon() &&
               topoleaf.level_type == 2){
                if(masksub && (maskccx || maskccd))
                    fprintf(stdout,
                            "  %-8s       [%2d+:%-2d]           %*.*s%*s = %u\n",
                            "+SubCore",
                            nabla_tzcnt32(masksub),
                            nabla_popcnt32(masksub),
                            32-nabla_tzcnt32(masksub),
                            nabla_popcnt32(masksub),
                            x2apicidbin+nabla_lzcnt32(masksub),
                            nabla_tzcnt32(masksub), "",
                            nabla_pext32(x2apicid, masksub));
                
                if(maskccx)
                    fprintf(stdout,
                            "  %-8s       [%2d+:%-2d]           %*.*s%*s = %u\n",
                            "+CCX",
                            nabla_tzcnt32(maskccx),
                            nabla_popcnt32(maskccx),
                            32-nabla_tzcnt32(maskccx),
                            nabla_popcnt32(maskccx),
                            x2apicidbin+nabla_lzcnt32(maskccx),
                            nabla_tzcnt32(maskccx), "",
                            nabla_pext32(x2apicid, maskccx));
                
                if(maskccd)
                    fprintf(stdout,
                            "  %-8s       [%2d+:%-2d]           %*.*s%*s = %u\n",
                            "+CCD",
                            nabla_tzcnt32(maskccd),
                            nabla_popcnt32(maskccd),
                            32-nabla_tzcnt32(maskccd),
                            nabla_popcnt32(maskccd),
                            x2apicidbin+nabla_lzcnt32(maskccd),
                            nabla_tzcnt32(maskccd), "",
                            nabla_pext32(x2apicid, maskccd));
            }
        }
    }
    
    if(nabla_cpuid_x86_is_amd_or_hygon() &&
       nabla_cpuid_x86_is_leaf_supported(0x8000001D)){
        for(i=0; nabla_cpuid_x86(&cachelv, 0x8000001D, i, 0), cachelv.type; i++){
            if(!i)
                fprintf(stdout,
                        "CACHE HIERARCHY\n"
                        "  LVL$ SI? FA? INC? #WAYS x #SETS =     #CL x CLSZ =     SIZE / #CORE\n");
            {
                fprintf(stdout,
                        "  L%c%c   %c   %c   %c  %5u    %5u   %7u   %3u  %10u    %4u\n",
                        "?12345 "[cachelv.level],
                        " di    "[cachelv.type],
                        "ny"     [cachelv.self_init],
                        "ny"     [cachelv.fully_assoc],
                        "ny"     [cachelv.inclusive],
                        (cachelv.W+1),
                        (cachelv.S+1),
                        (cachelv.W+1) * (cachelv.S+1),
                        (cachelv.L+1),
                        (cachelv.W+1) * (cachelv.S+1) * (cachelv.L+1),
                        (cachelv.num_sharing+1));
            }
        }
    }
#endif
#if 0
    extern int sgemm_mod_count(void);
    printf("%d\n", sgemm_mod_count());
#endif
    
    float* L   = NULL;
    size_t Lsz = 4 << 20; /* 4 MiB */
    if(posix_memalign((void**)&L, Lsz, Lsz) != 0){
        fprintf(stderr, "Error posix_memalign()'ing memory!\n");
        return 1;
    }
    madvise(L, Lsz, MADV_HUGEPAGE);
    madvise(L, Lsz, MADV_DONTDUMP);
    madvise(L, Lsz, MADV_UNMERGEABLE);
    madvise(L, Lsz, MADV_WILLNEED);
    madvise(L, Lsz, MADV_RANDOM);
    mlock  (L, Lsz);
    
    float (*A)[64]  = (void*)(L + 0);  /* float A[400][ 64]; */
    float (*B)[400] = (void*)(A + 400);/* float B[ 64][400]; */
    float (*C)[400] = (void*)(B + 64); /* float C[400][400]; */
    
    for(i=0;i<400;i++){
        for(j=0;j<64;j++){
            A[i][j] = 1.0f;    /* A is ones() */
            B[j][i] = (j+i)&63;/* B is circulant(range(64)) */
        }
        for(j=0;j<400;j++){
            C[j][i] = 0;       /* C is zeroes() */
        }
    }
    
    extern int sgemm_frag(int transA, int transB,
                          size_t M, size_t N, size_t K,
                          float  alpha,
                          float* A, ssize_t LDA,
                          float* B, ssize_t LDB,
                          float  beta,
                          float* C, ssize_t LDC,
                          float* L);
    extern void sgemm_test(float* A, float* B, float* C,
                           int K0, int counter, int prefetch_counter, float alpha, float beta);
    
    for(i=0;i<10000;i++){
        sgemm_test(L+0, L+400*64, L+2*400*64,                        /* A, B & C pointers */
                            32-5<<18 | 32-5<<13 | 16-5<<9 | 16-8<<5, /* K0                */
                   15<<23 |    4<<18 |    4<<13 |    4<<9,           /* counter           */
                   15<<23 |    4<<18 |    4<<13 |    4<<9 |    5<<5, /* prefetch counter  */
                   1.0f, 0.0f);                                      /* alpha & beta      */
    }
    
    return 0;
}
