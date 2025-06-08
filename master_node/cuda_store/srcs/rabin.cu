#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <omp.h>
#include <openssl/sha.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include "rabin.h"
#include "config.h"

__constant__ uint64_t d_rabin_table[256];
__constant__ uint64_t d_out_table[256];

void rabin_init_tables() {
    for (int b = 0; b < 256; b++) {
        uint64_t fp = b;
        for (int i = 0; i < 8; i++) {
            if (fp & 1)
                fp = (fp >> 1) ^ POLY;
            else
                fp = (fp >> 1);
        }
        rabin_table[b] = fp;
    }

    for (int b = 0; b < 256; b++) {
        uint64_t h = b;
        for (int i = 0; i < WINDOW_SIZE - 1; i++) {
            h = (h << 8) ^ rabin_table[0];
        }
        out_table[b] = h;
    }
    cudaMemcpyToSymbol(d_rabin_table, rabin_table, sizeof(rabin_table));
    cudaMemcpyToSymbol(d_out_table, out_table, sizeof(out_table));
}

__device__ uint64_t rabin_slide_hash(uint64_t fp, uint8_t out_byte, uint8_t in_byte) {
    fp ^= d_out_table[out_byte];
    fp = (fp << 8) ^ d_rabin_table[(fp >> 56) ^ in_byte];
    return fp;
}

__device__ uint64_t rabin_rolling_hash(uint8_t *window) {
    uint64_t fp = 0;
    for (int i = 0; i < WINDOW_SIZE; i++) {
        fp = (fp << 8) ^ d_rabin_table[(fp >> 56) ^ window[i]];
    }
    return fp;
}

__global__ void rabin_kernel(uint8_t *file_data, size_t file_size,
                                   int *chunk_offsets, int *chunk_lengths, int *chunk_count) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    long start = tid * STRIDE;
    if (start >= file_size) return;

    long end = start + STRIDE + MAX_CHUNK_SIZE;
    if (end > file_size) end = file_size;

    uint8_t slide_window[WINDOW_SIZE];
    size_t chunk_size = 0;
    uint64_t fingerprint = 0;
    int window_pos = 0;

    for (long i = start; i < end; i++) {
        uint8_t b = file_data[i];

        if (chunk_size < WINDOW_SIZE) {
            slide_window[window_pos++ % WINDOW_SIZE] = b;
            chunk_size++;
            if (chunk_size == WINDOW_SIZE)
                fingerprint = rabin_rolling_hash(slide_window);
            continue;
        }

        fingerprint = rabin_slide_hash(fingerprint, slide_window[window_pos % WINDOW_SIZE], b);
        slide_window[window_pos++ % WINDOW_SIZE] = b;
        chunk_size++;

        if ((fingerprint & CHUNK_MASK) == 0 || chunk_size >= MAX_CHUNK_SIZE) {
            int idx = atomicAdd(chunk_count, 1);
            chunk_offsets[idx] = i - chunk_size + 1;
            chunk_lengths[idx] = chunk_size;
            chunk_size = 0;
        }
    }

    if (chunk_size > 0) {
        int idx = atomicAdd(chunk_count, 1);
        chunk_offsets[idx] = end - chunk_size;
        chunk_lengths[idx] = chunk_size;
    }
}

void rabin_kernel_call(uint8_t *h_file_data, size_t file_size, int **h_chunk_offsets, int **h_chunk_lengths, int *h_chunk_count) {
    // 디바이스 메모리 포인터
    uint8_t *d_file_data;
    int *d_chunk_offsets, *d_chunk_lengths, *d_chunk_count;

    // chunk 개수 초기화
    int zero = 0;
    cudaMalloc(&d_chunk_count, sizeof(int));
    cudaMemcpy(d_chunk_count, &zero, sizeof(int), cudaMemcpyHostToDevice);

    // 파일 데이터 복사
    cudaMalloc(&d_file_data, file_size);
    cudaMemcpy(d_file_data, h_file_data, file_size, cudaMemcpyHostToDevice);

    // 청크 결과 공간 할당 (대충 최대 10만 개라 가정)
    size_t max_chunks = 100000;
    cudaMalloc(&d_chunk_offsets, sizeof(int) * max_chunks);
    cudaMalloc(&d_chunk_lengths, sizeof(int) * max_chunks);

    // 커널 실행
    int threadsPerBlock = 256;
    int blocksPerGrid = (file_size + STRIDE - 1) / STRIDE;
    rabin_kernel<<<blocksPerGrid, threadsPerBlock>>>(
        d_file_data, file_size,
        d_chunk_offsets, d_chunk_lengths, d_chunk_count
    );
    cudaDeviceSynchronize();

    // 청크 개수 받아오기
    int count = 0;
    cudaMemcpy(&count, d_chunk_count, sizeof(int), cudaMemcpyDeviceToHost);
    *h_chunk_count = count;

    // 결과 복사
    *h_chunk_offsets = (int *)malloc(sizeof(int) * count);
    *h_chunk_lengths = (int *)malloc(sizeof(int) * count);
    cudaMemcpy(*h_chunk_offsets, d_chunk_offsets, sizeof(int) * count, cudaMemcpyDeviceToHost);
    cudaMemcpy(*h_chunk_lengths, d_chunk_lengths, sizeof(int) * count, cudaMemcpyDeviceToHost);

    // 메모리 해제
    cudaFree(d_file_data);
    cudaFree(d_chunk_offsets);
    cudaFree(d_chunk_lengths);
    cudaFree(d_chunk_count);
}