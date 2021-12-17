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



/* Static Assert */
_Static_assert(sizeof(pthread_mutex_t) <= CL_SIZE, "pthread mutex larger than a cacheline!");



/* Extern Function Declarations */
extern uint32_t nabla_cpuid_x86(void* regs, uint32_t eax, uint32_t ecx, int sel);



/**
 * Main
 */

int main(int argc, char* argv[]){
    (void)argc;
    (void)argv;
    int i,j;
    
#if 0
    const int EAX=0, EBX=1, ECX=2, EDX=3;
    char     manubrand[17] = {0};
    char     procbrand[64];
    uint32_t tmp;
    uint32_t maxleaf   = nabla_cpuid_x86(manubrand, 0,          0, EAX);
    uint32_t maxleafex = nabla_cpuid_x86(0,         0x80000000, 0, EAX);
    uint32_t leaf01[4];
    uint32_t leaf0Becx0[4];
    if(maxleaf == 0){
        fprintf(stderr, "No CPUID leaves!\n");
        return 1;
    }
    if(maxleafex <= 0x80000000L){
        fprintf(stderr, "No CPUID extended leaves!\n");
        return 1;
    }
    memcpy(&tmp,         manubrand+8,  4);
    memcpy(manubrand+8,  manubrand+12, 4);
    memcpy(manubrand+12, &tmp,         4);
    nabla_cpuid_x86(leaf01,                1, 0, EAX);
    nabla_cpuid_x86(leaf0Becx0,   0x0000000B, 0, EAX);
    nabla_cpuid_x86(procbrand+ 0, 0x80000002, 0, EAX);
    nabla_cpuid_x86(procbrand+16, 0x80000003, 0, EAX);
    nabla_cpuid_x86(procbrand+32, 0x80000004, 0, EAX);
    nabla_cpuid_x86(procbrand+48, 0x80000005, 0, EAX);
    uint32_t extendedtopo  = nabla_cpuid_x86(0, 0x0B, 0, EBX);
    uint32_t x2apicsupport = (nabla_cpuid_x86(0, 0x01, 0, ECX) >> 21)&1;
    uint32_t x2apicid      = nabla_cpuid_x86(0, 0x0B, 0, EDX);
    uint32_t level0_type   = (nabla_cpuid_x86(0, 0x0B, 0, ECX) >> 8) & 0xFF;
    uint32_t level1_type   = (nabla_cpuid_x86(0, 0x0B, 1, ECX) >> 8) & 0xFF;
    uint32_t level2_type   = (nabla_cpuid_x86(0, 0x0B, 2, ECX) >> 8) & 0xFF;
    uint32_t level3_type   = (nabla_cpuid_x86(0, 0x0B, 3, ECX) >> 8) & 0xFF;
    uint32_t level0_width  = nabla_cpuid_x86(0, 0x0B, 0, EAX) & 31;
    uint32_t level1_width  = nabla_cpuid_x86(0, 0x0B, 1, EAX) & 31;
    uint32_t level2_width  = nabla_cpuid_x86(0, 0x0B, 2, EAX) & 31;
    uint32_t level3_width  = nabla_cpuid_x86(0, 0x0B, 3, EAX) & 31;
    uint32_t level0_max    = nabla_cpuid_x86(0, 0x0B, 0, EBX) & 65535;
    uint32_t level1_max    = nabla_cpuid_x86(0, 0x0B, 1, EBX) & 65535;
    uint32_t level2_max    = nabla_cpuid_x86(0, 0x0B, 2, EBX) & 65535;
    uint32_t level3_max    = nabla_cpuid_x86(0, 0x0B, 3, EBX) & 65535;
    uint32_t level0_shift  = 0;
    uint32_t level1_shift  = level0_shift+level0_width;
    uint32_t level2_shift  = level1_shift+level1_width;
    uint32_t level3_shift  = level2_shift+level2_width;
    uint32_t proctopoeax   = nabla_cpuid_x86(0, 0x8000001E, 0, EAX);
    uint32_t proctopoebx   = nabla_cpuid_x86(0, 0x8000001E, 0, EBX);
    uint32_t proctopoecx   = nabla_cpuid_x86(0, 0x8000001E, 0, ECX);
    uint32_t proctopoedx   = nabla_cpuid_x86(0, 0x8000001E, 0, EDX);
    
    fprintf(stdout,
            "Manufacturer Brand String:     %s\n"
            "Processor Brand String:        %s\n"
            "Max CPUID leaf:                %08x\n"
            "Max CPUID extended leaf:       %08x\n"
            "Extended topology enumeration: %d\n"
            "x2APIC support:                %d\n"
            "x2APIC ID:                     %d\n"
            "Level 0 (SMT): Type %3d  [%d +: %d] max logical %d\n"
            "Level 1:       Type %3d  [%d +: %d] max logical %d\n"
            "Level 2:       Type %3d  [%d +: %d] max logical %d\n"
            "Level 3:       Type %3d  [%d +: %d] max logical %d\n"
            "%08x %08x %08x %08x\n",
            manubrand+4, procbrand, maxleaf, maxleafex,
            extendedtopo, x2apicsupport, x2apicid,
            level0_type, level0_shift, level0_width, level0_max,
            level1_type, level1_shift, level1_width, level1_max,
            level2_type, level2_shift, level2_width, level2_max,
            level3_type, level3_shift, level3_width, level3_max,
            proctopoeax, proctopoebx,  proctopoecx,  proctopoedx);
#endif
    
    float A[320][64];
    float B[64][320];
    float C[320][320];
    float* L = mmap(NULL, 4 << 20, /* 4 MiB */
                    PROT_READ|PROT_WRITE,
                    MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE,
                    -1, 0);
    if(L == MAP_FAILED){
        fprintf(stderr, "Error mmap()'ing memory!\n");
        return 1;
    }
    
    for(i=0;i<320;i++){
        for(j=0;j<64;j++){
            A[i][j] = 1.0f;    /* A is ones() */
            B[j][i] = (j+i)&63;/* B is circulant(range(64)) */
        }
        for(j=0;j<320;j++){
            C[i][j] = 0;       /* C is zeroes() */
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
    extern void sgemm_test(float* A, float* B, float* C, float alpha, float beta);
    
    for(i=0;i<10000;i++){
        /*int ret = sgemm_frag('N', 'N', 320, 320, 64, 1.f, &A[0][0],  64*sizeof(float),
                                                      &B[0][0], 320*sizeof(float),
                                           i?1.f:0.f, &C[0][0], 320*sizeof(float), L);
        if(ret)
            return ret;*/
        sgemm_test(L+0, L+320*64, L+2*320*64, 1.0f, 0.0f);
    }
    
    return 0;
}
