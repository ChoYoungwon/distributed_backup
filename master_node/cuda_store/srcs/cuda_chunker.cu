// 필수 CUDA 헤더
#include <cuda_runtime.h>
#include <device_launch_parameters.h>

// 타입 정의
#include <stdint.h>
#include <stddef.h>   // size_t 정의

#define WINDOW_SIZE 48
#define POLY 0x3DA3358B4DC173ULL

// GPU 전용 Rabin 테이블 (전역 상수 메모리)
__device__ __constant__ uint64_t d_rabin_table[256];

// 슬라이딩 해시 함수 - GPU에서 호출됨
__device__ inline uint64_t slide_hash(uint64_t fp, uint8_t out_byte, uint8_t in_byte, const uint64_t* rabin_table) {
    uint64_t out_val = 0;
    for (int i = 0; i < WINDOW_SIZE - 1; i++)
        out_val = (out_val << 8) ^ rabin_table[0];
    fp ^= (out_byte * out_val); // simplified rolling out
    fp = (fp << 8) ^ rabin_table[(fp >> 56) ^ in_byte];
    return fp;
}

// GPU 커널 - 각 쓰레드가 하나의 fingerprint 계산
__global__ void fingerprint_kernel(uint8_t* input, uint64_t* fps, size_t length) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx + WINDOW_SIZE >= length) return;

    uint64_t fp = 0;
    for (int i = 0; i < WINDOW_SIZE; i++) {
        fp = (fp << 8) ^ d_rabin_table[(fp >> 56) ^ input[idx + i]];
    }

    fps[idx] = fp;
}

extern "C" void upload_rabin_table(const uint64_t* table_host) {
    cudaMemcpyToSymbol(d_rabin_table, table_host, 256 * sizeof(uint64_t));
}

