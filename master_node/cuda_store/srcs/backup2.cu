#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <iostream>
#include <omp.h>
#include <openssl/sha.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mman.h>

#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "chunker.h"
#include "config.h"
#include "network.h"
#include "timer.h"
#include "DS_timer.h"
#include "sha256.cuh"

#define MIN_CHUNK_SIZE          (4 * 1024)
#define AVG_CHUNK_SIZE          (16 * 1024)
#define MAX_CHUNK_SIZE          (64 * 1024)
#define CHUNK_MASK              (AVG_CHUNK_SIZE - 1)
#define WINDOW_SIZE             48
#define POLY                    0x3DA3358B4DC173ULL


#define NUM_STREAMS             4
#define THREADS_PER_BLOCK       256
#define NUM_BLOCKS              16
#define MAX_CHUNKS_PER_THREAD   4
#define SHARED_BUFFER_SIZE      (32 * 1024) // 공유 버퍼 크기
#define MAX_CHUNKS_PER_STREAM   (NUM_BLOCKS * THREADS_PER_BLOCK * MAX_CHUNKS_PER_THREAD)

// ✅ 올바른 메모리 할당 크기 계산
#define TOTAL_THREADS_PER_STREAM    (NUM_BLOCKS * THREADS_PER_BLOCK)
#define CHUNKS_PER_STREAM          (TOTAL_THREADS_PER_STREAM * MAX_CHUNKS_PER_THREAD)
#define TOTAL_CHUNKS               (NUM_STREAMS * CHUNKS_PER_STREAM)

__constant__ uint64_t d_rabin_table[256];
__constant__ uint64_t d_out_table[256];

static FILE *map_fp = NULL;
static int chunk_count = 0;

// 청크 정보 구조체
typedef struct __align__(16) {
    char chunk_id[65];
    size_t offset;
    size_t size;
    int valid;
    uint8_t padding[7];
} ChunkResult;

void write_chunk_map(const char *chunk_id, const char *ip, int port, const char *metadata_path) {
    if (map_fp == NULL) {
        map_fp = fopen(metadata_path, "w");
        fprintf(map_fp, "[\n");
        chunk_count = 0;
    }

    if (chunk_count > 0) {
        fprintf(map_fp, ",\n");
    }

    fprintf(map_fp, "  {\"chunk_id\": \"%s\", \"node\": \"%s:%d\"}", chunk_id, ip, port);
    chunk_count++;
    fflush(map_fp);
}

void rabin_init_tables() {
    uint64_t h_rabin_table[256];
    uint64_t h_out_table[256];

    for (int b = 0; b < 256; b++) {
        uint64_t fp = b;
        for (int i = 0; i < 8; i++) {
            if (fp & 1)
                fp = (fp >> 1) ^ POLY;
            else
                fp = (fp >> 1);
        }
        h_rabin_table[b] = fp;
    }

    for (int b = 0; b < 256; b++) {
        uint64_t h = b;
        for (int i = 0; i < WINDOW_SIZE - 1; i++) {
            h = (h << 8) ^ h_rabin_table[0];
        }
        h_out_table[b] = h;
    }

    cudaMemcpyToSymbol(d_rabin_table, h_rabin_table, sizeof(h_rabin_table));
    cudaMemcpyToSymbol(d_out_table, h_out_table, sizeof(h_out_table));
}

void finish_chunk_map() {
    if (map_fp) {
        fprintf(map_fp, "\n]\n");
        fclose(map_fp);
        map_fp = NULL;
    }
}

// 파일 크기 확인
long get_file_size(const char *filepath) {
    struct stat st;
    if(stat(filepath, &st) == 0) {
        return st.st_size;
    }
    return -1;
}

// 🚀 최적화 3: 더 빠른 SHA256 계산 (인라인 최적화)
__device__ __forceinline__ void calculate_sha256_device(uint8_t* data, size_t size, BYTE* hash) {
    CUDA_SHA256_CTX ctx;
    cuda_sha256_init(&ctx);
    cuda_sha256_update(&ctx, data, size);
    cuda_sha256_final(&ctx, hash);
}

__device__ __forceinline__ uint64_t rabin_rolling_hash_device(uint8_t *window, size_t len) {
    uint64_t fp = 0;
    #pragma unroll 8
    for (size_t i = 0; i < len; i++) {
        fp = (fp << 8) ^ d_rabin_table[(fp >> 56) ^ window[i]];
    }
    return fp;
}

__device__ __forceinline__ uint64_t rabin_slide_hash_device(uint64_t fp, uint8_t out_byte, uint8_t in_byte) {
    fp ^= d_out_table[out_byte];
    fp = (fp << 8) ^ d_rabin_table[(fp >> 56) ^ in_byte];
    return fp;
}

// 32byte 바이너리 -> 64자리 16진수 문자열로 변환
__device__ __forceinline__ void format_chunk_id_device(uint8_t* hash, char* chunk_id) {
    const char hex[] = "0123456789abcdef";
    #pragma unroll
    for (int i = 0; i < 32; i++) {
        chunk_id[i * 2] = hex[(hash[i] >> 4) & 0xF];
        chunk_id[i * 2 + 1] = hex[hash[i] & 0xF];
    }
    chunk_id[64] = '\0';
}

__device__ __forceinline__ void create_chunk_optimized(uint8_t* file_data, size_t chunk_start, 
                                                      size_t chunk_size, ChunkResult* results, 
                                                      int chunk_idx, size_t global_offset) {
    if (chunk_size == 0 || chunk_idx >= CHUNKS_PER_STREAM) return;
    
    uint8_t hash[32];
    calculate_sha256_device(file_data + chunk_start, chunk_size, hash);

    format_chunk_id_device(hash, results[chunk_idx].chunk_id);
    results[chunk_idx].offset = global_offset + chunk_start;
    results[chunk_idx].size = chunk_size;
    results[chunk_idx].valid = 1;
}

__global__ void rabin_kernel_optimized(uint8_t* file_data, size_t data_size, size_t global_offset, 
                                      ChunkResult* chunk_results, int* chunk_count_per_block) {
    
    // 🚀 공유 메모리 사용으로 메모리 대역폭 절약
    __shared__ uint8_t shared_buffer[SHARED_BUFFER_SIZE];
    __shared__ int shared_chunk_count;
    
    int thread_id = blockDim.x * blockIdx.x + threadIdx.x;
    int local_thread_id = threadIdx.x;
    
    if (local_thread_id == 0) {
        shared_chunk_count = 0;
    }
    __syncthreads();

    if (thread_id >= TOTAL_THREADS_PER_STREAM) return;

    // 🚀 최적화 6: 더 큰 청크로 작업 분할 (오버헤드 감소)
    size_t total_threads = gridDim.x * blockDim.x;
    size_t chunk_per_thread = (data_size + total_threads - 1) / total_threads;
    size_t thread_start = thread_id * chunk_per_thread;
    size_t thread_end = min(thread_start + chunk_per_thread, data_size);

    if (thread_start >= data_size) return;

    // 로컬 변수들
    uint8_t slide_window[WINDOW_SIZE];
    size_t current_chunk_start = thread_start;
    size_t current_pos = thread_start;
    size_t window_pos = 0;
    uint64_t fingerprint = 0;
    bool window_initialized = false;
    int local_chunk_count = 0;

    // 🚀 최적화 7: 연속 메모리 접근 패턴
    while (current_pos < thread_end && local_chunk_count < MAX_CHUNKS_PER_THREAD) {
        size_t chunk_size = 0;
        current_chunk_start = current_pos;
        
        // 청크 경계 찾기
        while (current_pos < thread_end && chunk_size < MAX_CHUNK_SIZE) {
            uint8_t b = file_data[current_pos];
            
            // 슬라이딩 윈도우 업데이트
            slide_window[window_pos % WINDOW_SIZE] = b;
            chunk_size++;
            current_pos++;
            
            if (chunk_size <= WINDOW_SIZE) {
                window_pos++;
                if (chunk_size == WINDOW_SIZE) {
                    fingerprint = rabin_rolling_hash_device(slide_window, WINDOW_SIZE);
                    window_initialized = true;
                }
            } else {
                if (window_initialized) {
                    uint8_t out_byte = slide_window[(window_pos - WINDOW_SIZE) % WINDOW_SIZE];
                    fingerprint = rabin_slide_hash_device(fingerprint, out_byte, b);
                }
                window_pos++;
            }

            // 청크 경계 조건 확인
            if (window_initialized && chunk_size >= MIN_CHUNK_SIZE) {
                bool natural_boundary = ((fingerprint & CHUNK_MASK) == 0);
                bool force_split = (chunk_size >= MAX_CHUNK_SIZE);
                
                if (natural_boundary || force_split) {
                    break;
                }
            }
        }

        // 청크 생성
        if (chunk_size > 0) {
            int result_idx = blockIdx.x * THREADS_PER_BLOCK * MAX_CHUNKS_PER_THREAD + 
                           local_thread_id * MAX_CHUNKS_PER_THREAD + local_chunk_count;
            
            if (result_idx < CHUNKS_PER_STREAM) {
                create_chunk_optimized(file_data, current_chunk_start, chunk_size, 
                                     chunk_results, result_idx, global_offset);
                local_chunk_count++;
            }
        }
        
        // 상태 리셋
        window_pos = 0;
        fingerprint = 0;
        window_initialized = false;
        memset(slide_window, 0, WINDOW_SIZE);
    }

    // 🚀 최적화 8: 원자적 카운터 업데이트 최소화
    if (local_chunk_count > 0) {
        atomicAdd(&shared_chunk_count, local_chunk_count);
    }
    
    __syncthreads();
    
    if (local_thread_id == 0 && shared_chunk_count > 0) {
        atomicAdd(&chunk_count_per_block[blockIdx.x], shared_chunk_count);
    }
}

void chunk_and_process(const char *filepath, const char *metadata_path) {
    rabin_init_tables();

    struct stat st;
    if (stat(filepath, &st) != 0) {
        perror("stat failed");
        return;
    }
    
    const size_t FILE_SIZE = st.st_size;
    const size_t SEGMENT_SIZE = FILE_SIZE / NUM_STREAMS;
    
    std::cout << "=== 최적화된 설정 ===" << std::endl;
    std::cout << "스트림 수: " << NUM_STREAMS << std::endl;
    std::cout << "블록당 스레드: " << THREADS_PER_BLOCK << std::endl;
    std::cout << "총 메모리 사용량: " << (TOTAL_CHUNKS * sizeof(ChunkResult)) / (1024*1024) << " MB" << std::endl;

    // 메모리 맵핑
    int fd = open(filepath, O_RDONLY);
    if (fd == -1) {
        perror("open failed");
        return;
    }
    
    uint8_t* mapped_file = (uint8_t*)mmap(NULL, FILE_SIZE, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mapped_file == MAP_FAILED) {
        perror("mmap failed");
        close(fd);
        return;
    }

    // 🚀 최적화 10: 단일 큰 할당으로 메모리 오버헤드 감소
    uint8_t* d_file_data;
    ChunkResult* d_chunk_results;
    int* d_chunk_counts;

    const size_t TOTAL_CHUNKS_NEEDED = NUM_STREAMS * CHUNKS_PER_STREAM;
    const size_t TOTAL_BLOCKS_NEEDED = NUM_STREAMS * NUM_BLOCKS;

    cudaMalloc(&d_file_data, FILE_SIZE);
    cudaMalloc(&d_chunk_results, sizeof(ChunkResult) * TOTAL_CHUNKS_NEEDED);
    cudaMalloc(&d_chunk_counts, sizeof(int) * TOTAL_BLOCKS_NEEDED);

    // 호스트 메모리
    ChunkResult* h_chunk_results = (ChunkResult*)malloc(sizeof(ChunkResult) * TOTAL_CHUNKS_NEEDED);
    int* h_chunk_counts = (int*)calloc(TOTAL_BLOCKS_NEEDED, sizeof(int));

    // 🚀 최적화 11: CUDA 스트림 최적화
    cudaStream_t streams[NUM_STREAMS];
    for (int i = 0; i < NUM_STREAMS; ++i) {
        cudaStreamCreate(&streams[i]);
    }

    // 비동기 메모리 복사
    for (int i = 0; i < NUM_STREAMS; ++i) {
        size_t offset = SEGMENT_SIZE * i;
        size_t size = (i == NUM_STREAMS - 1) ? (FILE_SIZE - offset) : SEGMENT_SIZE;
        
        cudaMemcpyAsync(d_file_data + offset, mapped_file + offset, size, 
                       cudaMemcpyHostToDevice, streams[i]);
    }

    // 🚀 최적화 12: 커널 실행 최적화
    for (int i = 0; i < NUM_STREAMS; ++i) {
        size_t offset = SEGMENT_SIZE * i;
        size_t size = (i == NUM_STREAMS - 1) ? (FILE_SIZE - offset) : SEGMENT_SIZE;
        
        dim3 blockDim(THREADS_PER_BLOCK);
        dim3 gridDim(NUM_BLOCKS);

        size_t chunk_result_offset = i * CHUNKS_PER_STREAM;
        size_t chunk_count_offset = i * NUM_BLOCKS;
        
        std::cout << "스트림 [" << i << "] 실행 - 오프셋: " << offset 
                  << ", 크기: " << size << std::endl;
        
        rabin_kernel_optimized<<<gridDim, blockDim, 0, streams[i]>>>(
            d_file_data + offset, 
            size, 
            offset, 
            d_chunk_results + chunk_result_offset, 
            d_chunk_counts + chunk_count_offset
        );
    }

    // 동기화 및 결과 복사
    cudaDeviceSynchronize();

    cudaMemcpy(h_chunk_results, d_chunk_results, 
               sizeof(ChunkResult) * TOTAL_CHUNKS_NEEDED, 
               cudaMemcpyDeviceToHost);
    cudaMemcpy(h_chunk_counts, d_chunk_counts, 
               sizeof(int) * TOTAL_BLOCKS_NEEDED, 
               cudaMemcpyDeviceToHost);

    // 결과 처리
    int total_chunks = 0;
    for (int i = 0; i < TOTAL_BLOCKS_NEEDED; i++) {
        total_chunks += h_chunk_counts[i];
    }

    std::cout << "[INFO] 총 청크 수: " << total_chunks << std::endl;

    int processed_chunks = 0;
    for (int stream_id = 0; stream_id < NUM_STREAMS; ++stream_id) {
        size_t stream_offset = SEGMENT_SIZE * stream_id;
        size_t stream_size = (stream_id == NUM_STREAMS - 1) ? (FILE_SIZE - stream_offset) : SEGMENT_SIZE;
        size_t stream_chunk_start = stream_id * CHUNKS_PER_STREAM;

        for (int chunk_idx = 0; chunk_idx < CHUNKS_PER_STREAM; chunk_idx++) {
            size_t global_chunk_idx = stream_chunk_start + chunk_idx;
            ChunkResult* chunk = &h_chunk_results[global_chunk_idx];
            
            if (chunk->valid && chunk->size > 0) {
                if (chunk->offset >= stream_offset && 
                    chunk->offset < stream_offset + stream_size &&
                    chunk->offset + chunk->size <= stream_offset + stream_size) {
                    
                    const char* ip = "127.0.0.1";
                    int port = 8080 + (processed_chunks % 4);
                    
                    write_chunk_map(chunk->chunk_id, ip, port, metadata_path);
                    processed_chunks++;
                }
            }
        }
    }

    finish_chunk_map();
    
    std::cout << "[INFO] 처리된 청크 수: " << processed_chunks << std::endl;
    
    if (processed_chunks > 0) {
        size_t avg_chunk_size = FILE_SIZE / processed_chunks;
        std::cout << "[INFO] 평균 청크 크기: " << avg_chunk_size << " bytes" << std::endl;
        std::cout << "[INFO] 처리 효율성: " << (double)processed_chunks / TOTAL_CHUNKS_NEEDED * 100 << "%" << std::endl;
    }

    // 정리
    for (int i = 0; i < NUM_STREAMS; i++) {
        cudaStreamDestroy(streams[i]);
    }

    cudaFree(d_file_data);
    cudaFree(d_chunk_results);
    cudaFree(d_chunk_counts);
    free(h_chunk_results);
    free(h_chunk_counts);
    munmap(mapped_file, FILE_SIZE);
    close(fd);
}
