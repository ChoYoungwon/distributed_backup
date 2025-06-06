#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <iostream>
#include <omp.h>
#include <map>
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

__global__ void rabin_kernel_fixed(uint8_t* file_data, size_t data_size, size_t global_offset, 
                                   ChunkResult* chunk_results, int* chunk_count_per_block) {
    
    __shared__ int shared_chunk_count;
    
    int thread_id = blockDim.x * blockIdx.x + threadIdx.x;
    int local_thread_id = threadIdx.x;
    
    if (local_thread_id == 0) {
        shared_chunk_count = 0;
    }
    __syncthreads();

    if (thread_id >= TOTAL_THREADS_PER_STREAM) return;

    size_t total_threads = gridDim.x * blockDim.x;
    size_t chunk_per_thread = (data_size + total_threads - 1) / total_threads;
    size_t thread_start = thread_id * chunk_per_thread;
    size_t thread_end = min(thread_start + chunk_per_thread, data_size);

    if (thread_start >= data_size) return;

    // 🔧 수정: Rabin 윈도우 초기화 개선
    uint8_t slide_window[WINDOW_SIZE];
    memset(slide_window, 0, WINDOW_SIZE);
    
    size_t current_chunk_start = thread_start;
    size_t current_pos = thread_start;
    uint64_t fingerprint = 0;
    int local_chunk_count = 0;
    
    while (current_pos < thread_end && local_chunk_count < MAX_CHUNKS_PER_THREAD) {
        size_t chunk_size = 0;
        current_chunk_start = current_pos;
        
        // 🔧 수정: 윈도우 상태 추적 개선
        bool window_ready = false;
        size_t window_pos = 0;
        
        while (current_pos < thread_end && chunk_size < MAX_CHUNK_SIZE) {
            uint8_t b = file_data[current_pos];
            current_pos++;
            chunk_size++;
            
            // 슬라이딩 윈도우 업데이트
            if (chunk_size <= WINDOW_SIZE) {
                slide_window[chunk_size - 1] = b;
                if (chunk_size == WINDOW_SIZE) {
                    // 🔧 수정: 정확한 초기 핑거프린트 계산
                    fingerprint = 0;
                    for (int i = 0; i < WINDOW_SIZE; i++) {
                        fingerprint = (fingerprint << 8) ^ d_rabin_table[(fingerprint >> 56) ^ slide_window[i]];
                    }
                    window_ready = true;
                    window_pos = WINDOW_SIZE;
                }
            } else {
                // 🔧 수정: 정확한 슬라이딩 윈도우 계산
                if (window_ready) {
                    uint8_t out_byte = slide_window[window_pos % WINDOW_SIZE];
                    slide_window[window_pos % WINDOW_SIZE] = b;
                    
                    // 정확한 슬라이딩 해시 계산
                    fingerprint ^= d_out_table[out_byte];
                    fingerprint = (fingerprint << 8) ^ d_rabin_table[(fingerprint >> 56) ^ b];
                    
                    window_pos++;
                }
            }

            // 🔧 수정: 청크 경계 조건 개선
            if (window_ready && chunk_size >= MIN_CHUNK_SIZE) {
                // 자연적 경계 조건 확인
                bool natural_boundary = ((fingerprint & CHUNK_MASK) == 0);
                
                // 🔧 추가: 더 나은 경계 조건들
                bool size_boundary = (chunk_size >= AVG_CHUNK_SIZE && (fingerprint & (CHUNK_MASK >> 1)) == 0);
                bool force_split = (chunk_size >= MAX_CHUNK_SIZE);
                
                if (natural_boundary || size_boundary || force_split) {
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
    }

    // 카운터 업데이트
    if (local_chunk_count > 0) {
        atomicAdd(&shared_chunk_count, local_chunk_count);
    }
    
    __syncthreads();
    
    if (local_thread_id == 0 && shared_chunk_count > 0) {
        atomicAdd(&chunk_count_per_block[blockIdx.x], shared_chunk_count);
    }
}

void chunk_and_process(const char *filepath, const char *metadata_path) {
    cudaEvent_t start, stop, kernel_start, kernel_stop, memcpy_start, memcpy_stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventCreate(&kernel_start);
    cudaEventCreate(&kernel_stop);
    cudaEventCreate(&memcpy_start);
    cudaEventCreate(&memcpy_stop);
    
    cudaEventRecord(start);
    
    rabin_init_tables();
    
    struct stat st;
    if (stat(filepath, &st) != 0) {
        perror("stat failed");
        return;
    }
    
    const size_t FILE_SIZE = st.st_size;
    const size_t SEGMENT_SIZE = FILE_SIZE / NUM_STREAMS;
    
    std::cout << "=== 성능 진단 정보 ===" << std::endl;
    std::cout << "파일 크기: " << FILE_SIZE / (1024*1024) << " MB" << std::endl;
    std::cout << "스트림당 처리량: " << SEGMENT_SIZE / (1024*1024) << " MB" << std::endl;
    std::cout << "예상 청크 수: " << FILE_SIZE / AVG_CHUNK_SIZE << std::endl;
    
    // 메모리 맵핑
    int fd = open(filepath, O_RDONLY);
    uint8_t* mapped_file = (uint8_t*)mmap(NULL, FILE_SIZE, PROT_READ, MAP_PRIVATE, fd, 0);
    
    // GPU 메모리 할당
    uint8_t* d_file_data;
    ChunkResult* d_chunk_results;
    int* d_chunk_counts;
    
    const size_t TOTAL_CHUNKS_NEEDED = NUM_STREAMS * CHUNKS_PER_STREAM;
    const size_t TOTAL_BLOCKS_NEEDED = NUM_STREAMS * NUM_BLOCKS;
    
    cudaMalloc(&d_file_data, FILE_SIZE);
    cudaMalloc(&d_chunk_results, sizeof(ChunkResult) * TOTAL_CHUNKS_NEEDED);
    cudaMalloc(&d_chunk_counts, sizeof(int) * TOTAL_BLOCKS_NEEDED);
    
    ChunkResult* h_chunk_results = (ChunkResult*)malloc(sizeof(ChunkResult) * TOTAL_CHUNKS_NEEDED);
    int* h_chunk_counts = (int*)calloc(TOTAL_BLOCKS_NEEDED, sizeof(int));
    
    cudaStream_t streams[NUM_STREAMS];
    for (int i = 0; i < NUM_STREAMS; ++i) {
        cudaStreamCreate(&streams[i]);
    }
    
    // 🔍 메모리 복사 시간 측정
    cudaEventRecord(memcpy_start);
    for (int i = 0; i < NUM_STREAMS; ++i) {
        size_t offset = SEGMENT_SIZE * i;
        size_t size = (i == NUM_STREAMS - 1) ? (FILE_SIZE - offset) : SEGMENT_SIZE;
        
        cudaMemcpyAsync(d_file_data + offset, mapped_file + offset, size, 
                       cudaMemcpyHostToDevice, streams[i]);
    }
    cudaDeviceSynchronize();
    cudaEventRecord(memcpy_stop);
    
    // 🔍 커널 실행 시간 측정
    cudaEventRecord(kernel_start);
    for (int i = 0; i < NUM_STREAMS; ++i) {
        size_t offset = SEGMENT_SIZE * i;
        size_t size = (i == NUM_STREAMS - 1) ? (FILE_SIZE - offset) : SEGMENT_SIZE;
        
        dim3 blockDim(THREADS_PER_BLOCK);
        dim3 gridDim(NUM_BLOCKS);
        
        size_t chunk_result_offset = i * CHUNKS_PER_STREAM;
        size_t chunk_count_offset = i * NUM_BLOCKS;
        
        rabin_kernel_fixed<<<gridDim, blockDim, 0, streams[i]>>>(
            d_file_data + offset, size, offset, 
            d_chunk_results + chunk_result_offset, 
            d_chunk_counts + chunk_count_offset
        );
    }
    cudaDeviceSynchronize();
    cudaEventRecord(kernel_stop);
    
    // 결과 복사
    cudaMemcpy(h_chunk_results, d_chunk_results, 
               sizeof(ChunkResult) * TOTAL_CHUNKS_NEEDED, 
               cudaMemcpyDeviceToHost);
    cudaMemcpy(h_chunk_counts, d_chunk_counts, 
               sizeof(int) * TOTAL_BLOCKS_NEEDED, 
               cudaMemcpyDeviceToHost);
    
    cudaEventRecord(stop);
    
    // 🔍 성능 분석
    float total_time, memcpy_time, kernel_time;
    cudaEventElapsedTime(&total_time, start, stop);
    cudaEventElapsedTime(&memcpy_time, memcpy_start, memcpy_stop);
    cudaEventElapsedTime(&kernel_time, kernel_start, kernel_stop);
    
    std::cout << "\n=== 상세 성능 분석 ===" << std::endl;
    std::cout << "총 처리 시간: " << total_time << " ms" << std::endl;
    std::cout << "메모리 복사 시간: " << memcpy_time << " ms (" 
              << (memcpy_time/total_time)*100 << "%)" << std::endl;
    std::cout << "커널 실행 시간: " << kernel_time << " ms (" 
              << (kernel_time/total_time)*100 << "%)" << std::endl;
    
    // 메모리 대역폭 계산
    float bandwidth_gb_s = (FILE_SIZE * 2) / (memcpy_time / 1000.0) / (1024*1024*1024);
    std::cout << "메모리 대역폭: " << bandwidth_gb_s << " GB/s" << std::endl;
    
    // 처리 속도 계산
    float throughput_mb_s = (FILE_SIZE / (1024*1024)) / (kernel_time / 1000.0);
    std::cout << "처리 속도: " << throughput_mb_s << " MB/s" << std::endl;
    
    // 🔍 청크 크기 분포 분석
    std::map<size_t, int> size_distribution;
    int total_chunks = 0;
    size_t min_chunk = SIZE_MAX, max_chunk = 0;
    
    for (int i = 0; i < TOTAL_CHUNKS_NEEDED; i++) {
        if (h_chunk_results[i].valid && h_chunk_results[i].size > 0) {
            size_t size = h_chunk_results[i].size;
            size_distribution[size]++;
            total_chunks++;
            min_chunk = std::min(min_chunk, size);
            max_chunk = std::max(max_chunk, size);
        }
    }
    
    std::cout << "\n=== 청크 크기 분석 ===" << std::endl;
    std::cout << "총 청크 수: " << total_chunks << std::endl;
    std::cout << "최소 청크 크기: " << min_chunk << " bytes" << std::endl;
    std::cout << "최대 청크 크기: " << max_chunk << " bytes" << std::endl;
    std::cout << "평균 청크 크기: " << FILE_SIZE / total_chunks << " bytes" << std::endl;
    
    // 크기별 분포 (상위 5개)
    std::cout << "크기별 분포 (상위 5개):" << std::endl;
    auto it = size_distribution.rbegin();
    for (int i = 0; i < 5 && it != size_distribution.rend(); ++it, ++i) {
        std::cout << "  " << it->first << " bytes: " << it->second << "개 ("
                  << (double)it->second/total_chunks*100 << "%)" << std::endl;
    }
    
    // 🚨 문제 진단
    if (max_chunk == MAX_CHUNK_SIZE) {
        std::cout << "\n⚠️  경고: 모든 청크가 최대 크기로 분할됨" << std::endl;
        std::cout << "   → Rabin 핑거프린팅이 작동하지 않을 가능성" << std::endl;
        std::cout << "   → 윈도우 초기화 또는 해시 계산 문제 의심" << std::endl;
    }
    
    // GPU 사용률 진단
    if (kernel_time < memcpy_time * 0.5) {
        std::cout << "\n💡 최적화 제안: 커널이 메모리 복사보다 너무 빠름" << std::endl;
        std::cout << "   → 더 복잡한 작업을 GPU에서 처리할 수 있음" << std::endl;
        std::cout << "   → 청크 검증, 압축 등 추가 작업 고려" << std::endl;
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
    
    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    cudaEventDestroy(kernel_start);
    cudaEventDestroy(kernel_stop);
    cudaEventDestroy(memcpy_start);
    cudaEventDestroy(memcpy_stop);
}
