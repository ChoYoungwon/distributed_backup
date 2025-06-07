// 필수 CUDA 헤더
#include <cuda_runtime.h>
#include <device_launch_parameters.h>

#include <stdint.h>
#include <stddef.h>

#define WINDOW_SIZE 48
#define POLY 0x3DA3358B4DC173ULL

__device__ __constant__ uint64_t d_rabin_table[256];

__device__ inline uint64_t slide_hash(uint64_t fp, uint8_t out_byte, uint8_t in_byte, const uint64_t* rabin_table) {
    uint64_t out_val = 0;
    for (int i = 0; i < WINDOW_SIZE - 1; i++)
        out_val = (out_val << 8) ^ rabin_table[0];
    fp ^= (out_byte * out_val);
    fp = (fp << 8) ^ rabin_table[(fp >> 56) ^ in_byte];
    return fp;
}

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

