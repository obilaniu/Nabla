/* Includes */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#include <pthread.h>

#include <sched.h>
#include <unistd.h>
#include <sys/mman.h>



/* Defines */
#define CL_SIZE 64



/* Static Assert */
_Static_assert(sizeof(pthread_mutex_t) <= CL_SIZE, "pthread mutex larger than a cacheline!");



/**
 * Main
 */

int main(int argc, char* argv[]){
    (void)argc;
    (void)argv;
    
    int i,j;
    
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
    extern void sgemm_test(float* A, float* B, float* C, float alpha);
    
    for(i=0;i<10000;i++){
        /*int ret = sgemm_frag('N', 'N', 320, 320, 64, 1.f, &A[0][0],  64*sizeof(float),
                                                      &B[0][0], 320*sizeof(float),
                                           i?1.f:0.f, &C[0][0], 320*sizeof(float), L);
        if(ret)
            return ret;*/
        sgemm_test(L+0, L+320*64, L+2*320*64, 1.0f);
    }
    
    return 0;
}
