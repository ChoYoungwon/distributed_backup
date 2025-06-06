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


#define NUM_STREAMS             2
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

// __device__ __forceinline__ void create_or_merge_chunk(uint8_t* chunk_buf, size_t chunk_size, 
//                                      ChunkResult* results, int thread_id, 
//                                      int local_count, size_t offset, size_t current_pos,
//                                      uint8_t* _file_data, bool is_final_merge = false) {
//     if (chunk_size == 0) return;
    
//     int chunk_idx = thread_id * MAX_CHUNKS_PER_THREAD + local_count;
//     if (chunk_idx >= CHUNKS_PER_STREAM) {  // 스트림별 최대 청크 수 검사
//         return;
//     }

//     // ✅ 마지막 청크에서 오버플로우 시 이전 청크와 병합
//     if (is_final_merge && local_count > 0) {
//         int prev_chunk_idx = thread_id * MAX_CHUNKS_PER_THREAD + (local_count - 1);
        
//         if (prev_chunk_idx < MAX_CHUNKS_PER_STREAM && results[prev_chunk_idx].valid) {
//             // ✅ 전체 병합된 데이터의 정확한 해시 계산
//             size_t prev_start = results[prev_chunk_idx].offset - offset;
//             size_t total_size = results[prev_chunk_idx].size + chunk_size;
            
//             uint8_t hash[32];
//             calculate_sha256_device(_file_data + prev_start, total_size, hash);
            
//             // 이전 청크를 확장된 크기로 업데이트
//             format_chunk_id_device(hash, results[prev_chunk_idx].chunk_id);
//             results[prev_chunk_idx].size = total_size;  // 전체 크기로 설정
            
//             printf("[DEBUG] Thread %d: Merged chunk %d (total_size=%zu)\n", 
//                    thread_id, local_count - 1, total_size);
//             return;
//         }
//     }
    
//     // ✅ 일반적인 청크 생성
//     if (chunk_idx >= MAX_CHUNKS_PER_STREAM) {
//         return;
//     }
    
//     uint8_t hash[32];
//     calculate_sha256_device(chunk_buf, chunk_size, hash);

//     format_chunk_id_device(hash, results[chunk_idx].chunk_id);
//     results[chunk_idx].offset = offset + current_pos - chunk_size;
//     results[chunk_idx].size = chunk_size;
//     results[chunk_idx].valid = 1;
// }

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


// 청크 초기화
__device__ void reset_chunk_state(size_t* chunk_size, size_t* window_pos, 
                                 uint64_t* fingerprint, uint8_t* slide_window,
                                 bool* window_initialized) {  
    *chunk_size = 0;
    *window_pos = 0;
    *fingerprint = 0;
    *window_initialized = false;  
    
    #pragma unroll
    for (int i = 0; i < WINDOW_SIZE; i++) {
        slide_window[i] = 0;
    }
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

// __global__ void rabin_kernel(uint8_t* _file_data, size_t _data_size, size_t _offset, 
//                               ChunkResult* _chunk_result, int* _chunk_count_per_block,
//                             uint8_t* _chunk_buffer
//                             ) {
//     int thread_id = blockDim.x * blockIdx.x + threadIdx.x;

//     // ✅ 경계 검사 강화
//     if (thread_id >= TOTAL_THREADS_PER_STREAM) {
//         return;  // 스트림 내 스레드 범위 초과 시 종료
//     }

//     size_t total_threads = gridDim.x * blockDim.x;
//     size_t per_thread_area = _data_size / total_threads;
//     size_t thread_start = thread_id * per_thread_area;
//     size_t thread_end = thread_start + per_thread_area;

//     thread_end = (thread_id == total_threads - 1) ? _data_size : thread_end;

//     if (thread_start >= _data_size || thread_end <= thread_start || thread_end <= WINDOW_SIZE) {
//         return;
//     }

//     uint8_t* chunk_buf = _chunk_buffer + (thread_id * MAX_CHUNK_SIZE);
    
//     uint8_t slide_window[WINDOW_SIZE] = {0};
//     size_t chunk_size = 0;
//     size_t window_pos = 0;
//     uint64_t fingerprint = 0;
//     int local_chunk_count = 0;
//     int actual_chunk_count = 0;  // ✅ 실제 생성된 청크 수 추적
//     bool window_initialized = false;

//     size_t skip_amount = (thread_id > 0) * WINDOW_SIZE;
//     size_t current_pos = thread_start + skip_amount;
//     current_pos = min(current_pos, thread_end);
    
//     // 메인 처리 루프 (29개까지)
//     while (current_pos < thread_end && local_chunk_count < MAX_CHUNKS_PER_THREAD - 1) {
//         uint8_t b = _file_data[current_pos++];

//         if (chunk_size >= MAX_CHUNK_SIZE - 1) {
//             create_or_merge_chunk(chunk_buf, chunk_size, _chunk_result, 
//                                  thread_id, local_chunk_count, _offset, current_pos - 1, _file_data);
//             local_chunk_count++;
//             actual_chunk_count++;
            
//             reset_chunk_state(&chunk_size, &window_pos, &fingerprint, slide_window, &window_initialized);
            
//             if (local_chunk_count >= MAX_CHUNKS_PER_THREAD - 1) {
//                 break;
//             }
//         }

//         chunk_buf[chunk_size++] = b;
//         slide_window[window_pos % WINDOW_SIZE] = b;
        
//         if (chunk_size <= WINDOW_SIZE) {
//             window_pos++;
//             if (chunk_size == WINDOW_SIZE) {
//                 fingerprint = rabin_rolling_hash_device(slide_window, WINDOW_SIZE);
//                 window_initialized = true;
//             }
//         } else {
//             if (window_initialized) {
//                 uint8_t out_byte = slide_window[(window_pos - WINDOW_SIZE) % WINDOW_SIZE]; 
//                 fingerprint = rabin_slide_hash_device(fingerprint, out_byte, b);
//             }
//             window_pos++;
//         }

//         if (window_initialized && chunk_size >= MIN_CHUNK_SIZE) {
//             bool force_split = (chunk_size >= MAX_CHUNK_SIZE);
//             bool natural_boundary = ((fingerprint & CHUNK_MASK) == 0);

//             if (force_split || natural_boundary) {
//                 create_or_merge_chunk(chunk_buf, chunk_size, _chunk_result, 
//                                      thread_id, local_chunk_count, _offset, current_pos, _file_data);
//                 local_chunk_count++;
//                 actual_chunk_count++;
                
//                 reset_chunk_state(&chunk_size, &window_pos, &fingerprint, slide_window, &window_initialized);
                
//                 if (local_chunk_count >= MAX_CHUNKS_PER_THREAD - 1) {
//                     break;
//                 }
//             }
//         }
//     }

//     // ✅ 남은 데이터 처리 (병합 로직 적용)
//     bool merge_occurred = false;
//     while (current_pos < thread_end) {
//         uint8_t b = _file_data[current_pos++];
        
//         // 마지막 청크에서 오버플로우 발생 시
//         if (chunk_size >= MAX_CHUNK_SIZE - 1 && local_chunk_count == MAX_CHUNKS_PER_THREAD - 1) {
//             printf("[INFO] Thread %d: Final chunk overflow, merging with previous chunk\n", thread_id);
            
//             create_or_merge_chunk(chunk_buf, chunk_size, _chunk_result, 
//                                  thread_id, local_chunk_count, _offset, current_pos - 1, _file_data, true);
//             merge_occurred = true;
//             chunk_size = 0;
//         }
//         else if (chunk_size >= MAX_CHUNK_SIZE - 1) {
//             create_or_merge_chunk(chunk_buf, chunk_size, _chunk_result, 
//                                  thread_id, local_chunk_count, _offset, current_pos - 1, _file_data);
//             local_chunk_count++;
//             actual_chunk_count++;
//             chunk_size = 0;
//         }
        
//         chunk_buf[chunk_size++] = b;
//     }
    
//     // 최종 청크 처리
//     if (chunk_size > 0) {
//         if (local_chunk_count >= MAX_CHUNKS_PER_THREAD) {
//             create_or_merge_chunk(chunk_buf, chunk_size, _chunk_result, 
//                                  thread_id, MAX_CHUNKS_PER_THREAD - 1, _offset, current_pos, _file_data, true);
//             merge_occurred = true;
//         } else {
//             create_or_merge_chunk(chunk_buf, chunk_size, _chunk_result, 
//                                  thread_id, local_chunk_count, _offset, current_pos, _file_data);
//             actual_chunk_count++;
//         }
//     }
    
//     // ✅ 정확한 청크 수 업데이트 (병합 고려)
//     if (!merge_occurred) {
//         actual_chunk_count = min(local_chunk_count + (chunk_size > 0 ? 1 : 0), MAX_CHUNKS_PER_THREAD);
//     }
    
//     if (actual_chunk_count > 0) {
//         atomicAdd(&_chunk_count_per_block[blockIdx.x], actual_chunk_count);
//     }
// }

void chunk_and_process(const char *filepath, const char *metadata_path) {
    
    rabin_init_tables();

    struct stat st;
    if (stat(filepath, &st) != 0) {
        perror("stat failed");
        return;
    }
    const size_t FILE_SIZE = st.st_size;
    const size_t SEGMENT_SIZE = FILE_SIZE / NUM_STREAMS;
    // std::cout << "Total file size : " << FILE_SIZE << "bytes" << std::endl;
    
    // 🎯 최적화 11: 메모리 맵핑 최적화 (중복 복사 제거)
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

    uint8_t* d_file_data;
    uint8_t* d_chunk_buffer;
    ChunkResult* d_chunk_results;
    int* d_chunk_counts;

    // 전체 스트림에 대한 총 메모리 할당
    const size_t TOTAL_CHUNKS_NEEDED = NUM_STREAMS * CHUNKS_PER_STREAM;
    const size_t TOTAL_BLOCKS_NEEDED = NUM_STREAMS * NUM_BLOCKS;
    const size_t TOTAL_THREADS_NEEDED = NUM_STREAMS * TOTAL_THREADS_PER_STREAM;

    std::cout << "=== 메모리 할당 정보 ===" << std::endl;
    std::cout << "총 청크 메모리: " << TOTAL_CHUNKS_NEEDED << " chunks" << std::endl;
    std::cout << "총 블록 수: " << TOTAL_BLOCKS_NEEDED << std::endl;
    std::cout << "총 스레드 수: " << TOTAL_THREADS_NEEDED << std::endl;

    cudaMalloc(&d_file_data, FILE_SIZE);
    cudaMalloc(&d_chunk_results, sizeof(ChunkResult) * TOTAL_CHUNKS_NEEDED);
    cudaMalloc(&d_chunk_counts, sizeof(int) * TOTAL_BLOCKS_NEEDED);
    cudaMalloc(&d_chunk_buffer, sizeof(uint8_t) * MAX_CHUNK_SIZE * TOTAL_THREADS_NEEDED);

    // ✅ 수정 2: 올바른 호스트 메모리 할당
    ChunkResult* h_chunk_results = (ChunkResult*)malloc(sizeof(ChunkResult) * TOTAL_CHUNKS_NEEDED);
    int* h_chunk_counts = (int*)malloc(sizeof(int) * TOTAL_BLOCKS_NEEDED);

    cudaStream_t streams[NUM_STREAMS];
    for (int i = 0; i < NUM_STREAMS; ++i) {
        cudaStreamCreate(&streams[i]);

        size_t offset = SEGMENT_SIZE * i;
        size_t size = (i == NUM_STREAMS - 1) ? (FILE_SIZE - offset) : SEGMENT_SIZE;
        
        cudaMemcpyAsync(d_file_data + offset, mapped_file + offset , size, cudaMemcpyHostToDevice, streams[i]);
        
        // + 커널 추가(스트림별 중첩해 파이프라인 형성)
        dim3 blockDim(THREADS_PER_BLOCK);
        dim3 gridDim(NUM_BLOCKS);

        // ✅ 수정 3: 올바른 오프셋 계산
        size_t chunk_result_offset = i * CHUNKS_PER_STREAM;
        size_t chunk_count_offset = i * NUM_BLOCKS;
        size_t chunk_buffer_offset = i * MAX_CHUNK_SIZE * TOTAL_THREADS_PER_STREAM;
    
        std::cout << "스트림 [" << i << "] 실행, " << "오프셋 : " << offset 
                    << " 담당 크기 : " << size << std::endl;
        rabin_kernel<<<gridDim, blockDim, 0, streams[i]>>>(
            d_file_data + offset, 
            size, 
            offset, 
            d_chunk_results + chunk_result_offset, 
            d_chunk_counts + chunk_count_offset,
            d_chunk_buffer + chunk_buffer_offset
        );
    }    

    // 모든 스트림 동기화 (추가됨)
    cudaDeviceSynchronize();

    cudaMemcpy(h_chunk_results, d_chunk_results, 
               sizeof(ChunkResult) * TOTAL_CHUNKS_NEEDED,
               cudaMemcpyDeviceToHost);
    cudaMemcpy(h_chunk_counts, d_chunk_counts, 
               sizeof(int) * TOTAL_BLOCKS_NEEDED, 
               cudaMemcpyDeviceToHost);

    int total_chunks = 0;
    for (int i = 0; i < TOTAL_BLOCKS_NEEDED; i++) {
        total_chunks += h_chunk_counts[i];  
    }

    std::cout << "[INFO] Total chunks found: " << h_chunk_counts << std::endl;
    std::cout << "[INFO] Average chunks per stream: " << total_chunks / NUM_STREAMS << std::endl;
    std::cout << "[INFO] GPU threads utilized: " <<TOTAL_THREADS_NEEDED << std::endl; 

    int processed_chunks = 0;
    for (int stream_id = 0; stream_id < NUM_STREAMS; ++stream_id) {
        size_t stream_offset = SEGMENT_SIZE * stream_id;
        size_t stream_size = (stream_id == NUM_STREAMS - 1) ? (FILE_SIZE - stream_offset) : SEGMENT_SIZE;
        
        size_t stream_chunk_start = stream_id * CHUNKS_PER_STREAM;

        // 각 스트림의 유효한 청크들 처리
        for (int chunk_idx = 0; chunk_idx < MAX_CHUNKS_PER_STREAM; chunk_idx++) {
            // ✅ 올바른 1D 배열 인덱싱
            size_t global_chunk_idx = stream_chunk_start + chunk_idx;
            ChunkResult* chunk = &h_chunk_results[global_chunk_idx];
            
            if (chunk->valid && chunk->size > 0) {
                // 청크 데이터 범위 검증
                size_t file_offset = chunk->offset - stream_offset;
                
                if (chunk->offset >= stream_offset && 
                    chunk->offset < stream_offset + stream_size &&
                    chunk->offset + chunk->size <= stream_offset + stream_size
                ) {
                    const char* ip = "127.0.0.1";  // 예시 IP
                    int port = 8080 + (processed_chunks % 4);  // 예시 포트
                    
                    write_chunk_map(chunk->chunk_id, ip, port, metadata_path);
                    
                    if (processed_chunks < 10 || processed_chunks % 100 == 0) {
                        std::cout << "[DEBUG] Chunk " << processed_chunks + 1 
                                  << ": offset=" << chunk->offset 
                                  << ", size=" << chunk->size 
                                  << ", stream=" << stream_id
                                  << ", id=" << std::string(chunk->chunk_id).substr(0, 16) << "..."
                                  << std::endl;
                    } 
                    processed_chunks++;
                }
                else {
                    // 범위 벗어난 청크 경고
                    std::cout << "[WARNING] Invalid chunk range in stream " << stream_id 
                            << ": offset=" << chunk->offset 
                            << ", size=" << chunk->size 
                            << ", expected_range=[" << stream_offset 
                            << ", " << stream_offset + stream_size << ")"
                            << std::endl;
                }
            }
        }
    }
    
    // 메타데이터 파일 마무리
    finish_chunk_map();
    
    std::cout << "[INFO] Successfully processed " << h_chunk_counts << " chunks" << std::endl;
    
    if (processed_chunks > 0) {
        size_t avg_chunk_size = FILE_SIZE / processed_chunks;
        std::cout << "[INFO] Average chunk size: " << avg_chunk_size << " bytes (" 
                  << avg_chunk_size / 1024 << " KB)" << std::endl;
        std::cout << "[INFO] Chunk size efficiency: " 
                  << (double)avg_chunk_size / AVG_CHUNK_SIZE * 100 << "% of target" << std::endl;
        
        // 병렬 효율성 분석
        double chunks_per_thread = (double)processed_chunks / TOTAL_THREADS_NEEDED;
        std::cout << "[INFO] Parallel efficiency: " << chunks_per_thread 
                  << " chunks per thread (target: " << MAX_CHUNKS_PER_THREAD << ")" << std::endl;
    }

    // 정리
    for (int i = 0; i < NUM_STREAMS; i++) {
        cudaStreamDestroy(streams[i]);
    }

    cudaFree(d_file_data);
    cudaFree(d_chunk_results);
    cudaFree(d_chunk_counts);
    cudaFree(d_chunk_buffer);
    free(h_chunk_results);
    free(h_chunk_counts);
    munmap(mapped_file, FILE_SIZE);
    close(fd);
}
