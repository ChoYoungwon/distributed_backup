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
#include <vector>

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
                                   ChunkResult* chunk_results) {
    
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
}

void chunk_and_process(const char *filepath, const char *metadata_path) {
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    cudaEventRecord(start);
    cudaEventRecord(start);
    
    rabin_init_tables();
    
    struct stat st;
    if (stat(filepath, &st) != 0) {
        perror("stat failed");
        return;
    }
    
    const size_t FILE_SIZE = st.st_size;
    const size_t SEGMENT_SIZE = FILE_SIZE / NUM_STREAMS;
    
    std::cout << "=== 파이프라인 스트리밍 처리 ===" << std::endl;
    std::cout << "파일 크기: " << FILE_SIZE / (1024*1024) << " MB" << std::endl;
    std::cout << "세그먼트 크기: " << SEGMENT_SIZE / (1024*1024) << " MB" << std::endl;
    
    int fd = open(filepath, O_RDONLY);
    if (fd == -1) {
        perror("open failed");
        return;
    }

    // 🔥 더블 버퍼링을 위한 자원 준비
    const int BUFFER_COUNT = 2;  // 더블 버퍼링
    int current_buffer = 0;

    // 각 버퍼를 위한 리소스
    uint8_t* h_pinned_buffers[BUFFER_COUNT];
    uint8_t* d_segment_buffers[BUFFER_COUNT];
    ChunkResult* d_chunk_results[BUFFER_COUNT];
    ChunkResult* h_chunk_results[BUFFER_COUNT];
    cudaStream_t streams[BUFFER_COUNT];
    cudaEvent_t events[BUFFER_COUNT];
    
    // 버퍼 초기화
    for (int i = 0; i < BUFFER_COUNT; i++) {
        size_t max_segment_size = SEGMENT_SIZE + (FILE_SIZE % NUM_STREAMS);
        
        cudaMallocHost(&h_pinned_buffers[i], max_segment_size);
        cudaMalloc(&d_segment_buffers[i], max_segment_size);
        cudaMalloc(&d_chunk_results[i], sizeof(ChunkResult) * CHUNKS_PER_STREAM);
        cudaMallocHost(&h_chunk_results[i], sizeof(ChunkResult) * CHUNKS_PER_STREAM);
        
        cudaStreamCreate(&streams[i]);
        cudaEventCreate(&events[i]);
    }
    
    std::vector<ChunkResult> all_chunk_results;

    for (int seg_id = 0; seg_id < NUM_STREAMS + BUFFER_COUNT - 1; ++seg_id) {
        int read_seg_id = seg_id;
        int process_seg_id = seg_id - BUFFER_COUNT + 1;

        if (read_seg_id < NUM_STREAMS) {
            size_t offset = SEGMENT_SIZE * read_seg_id;
            size_t segment_size = (read_seg_id == NUM_STREAMS - 1) ?
                (FILE_SIZE - offset) : SEGMENT_SIZE;
            
            // 비동기 파일 읽기 시뮬레이션 (실제로는 동기식이지만 GPU 작업과 오버랩)
            lseek(fd, offset, SEEK_SET);
            size_t total_read = 0;
            while (total_read < segment_size) {
                ssize_t bytes_read = read(fd, 
                                        h_pinned_buffers[current_buffer] + total_read, 
                                        segment_size - total_read);
                if (bytes_read <= 0) break;
                total_read += bytes_read;
            }
            
            // 🚀 STAGE 2: GPU로 전송 + 커널 실행 (비동기)
            cudaMemcpyAsync(d_segment_buffers[current_buffer], 
                           h_pinned_buffers[current_buffer], 
                           segment_size, 
                           cudaMemcpyHostToDevice, 
                           streams[current_buffer]
            );
            dim3 blockDim(THREADS_PER_BLOCK);
            dim3 gridDim(NUM_BLOCKS);

            rabin_kernel_fixed<<<gridDim, blockDim, 0, streams[current_buffer]>>>(
                d_segment_buffers[current_buffer], segment_size, offset,
                d_chunk_results[current_buffer]
            );

            // 결과 복사 (비동기)
            cudaMemcpyAsync(h_chunk_results[current_buffer], 
                           d_chunk_results[current_buffer],
                           sizeof(ChunkResult) * CHUNKS_PER_STREAM, 
                           cudaMemcpyDeviceToHost, 
                           streams[current_buffer]
            );

            // 이 버퍼의 작업 완료를 표시
            cudaEventRecord(events[current_buffer], streams[current_buffer]);

        }

        // 이전 버퍼의 결과 처리 (CPU)
        if (process_seg_id >= 0) {
            int process_buffer = (current_buffer + 1) % BUFFER_COUNT;
            
            // 이전 버퍼의 GPU 작업이 완료될 때까지 대기
            cudaEventSynchronize(events[process_buffer]);
            
            // 결과 수집 (CPU 작업, 다음 GPU 작업과 오버랩)
            for (int i = 0; i < CHUNKS_PER_STREAM; i++) {
                if (h_chunk_results[process_buffer][i].valid && 
                    h_chunk_results[process_buffer][i].size > 0) {
                    all_chunk_results.push_back(h_chunk_results[process_buffer][i]);
                    
                    const char* ip = "127.0.0.1";
                    int port = 8080 + (process_seg_id % 4);
                    write_chunk_map(h_chunk_results[process_buffer][i].chunk_id, 
                                  ip, port, metadata_path);
                }
            }
            
        }
        // 버퍼 전환
        current_buffer = (current_buffer + 1) % BUFFER_COUNT;
    }

    close(fd);
    finish_chunk_map();
    
    // 성능 측정
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    float total_time;
    cudaEventElapsedTime(&total_time, start, stop);
    
    std::cout << "\n=== 파이프라인 처리 결과 ===" << std::endl;
    std::cout << "총 처리 시간: " << total_time << " ms" << std::endl;
    std::cout << "총 청크 수: " << all_chunk_results.size() << std::endl;
    std::cout << "처리 속도: " << (FILE_SIZE / (1024*1024)) / (total_time / 1000) 
              << " MB/s" << std::endl;
    
    // 정리
    for (int i = 0; i < BUFFER_COUNT; i++) {
        cudaFreeHost(h_pinned_buffers[i]);
        cudaFreeHost(h_chunk_results[i]);
        cudaFree(d_segment_buffers[i]);
        cudaFree(d_chunk_results[i]);
        cudaStreamDestroy(streams[i]);
        cudaEventDestroy(events[i]);
    }
    
    cudaEventDestroy(start);
    cudaEventDestroy(stop);
}
