#ifndef CONFIG_H
#define CONFIG_H


// 성능에 영향 줄 거 같은 것들 모음집.
#define BUFFER_COUNT 2 //이거 파일 커지면 바꿔야 함.
#define NUM_STREAMS 4

#define MIN_CHUNK_SIZE          (4 * 1024)
#define AVG_CHUNK_SIZE          (16 * 1024)
#define MAX_CHUNK_SIZE          (64 * 1024)
#define CHUNK_MASK              (AVG_CHUNK_SIZE - 1)
#define WINDOW_SIZE             48
#define POLY                    0x3DA3358B4DC173ULL

#define THREADS_PER_BLOCK       256
#define NUM_BLOCKS              16
#define MAX_CHUNKS_PER_THREAD   8
#define SHARED_BUFFER_SIZE      (32 * 1024) // 공유 버퍼 크기
#define MAX_CHUNKS_PER_STREAM   (NUM_BLOCKS * THREADS_PER_BLOCK * MAX_CHUNKS_PER_THREAD)

// 메모리 할당 크기 계산
#define TOTAL_THREADS_PER_STREAM    (NUM_BLOCKS * THREADS_PER_BLOCK)
#define CHUNKS_PER_STREAM          (TOTAL_THREADS_PER_STREAM * MAX_CHUNKS_PER_THREAD)
#define TOTAL_CHUNKS               (NUM_STREAMS * CHUNKS_PER_STREAM)

#define MAX_NODES 3 // 아래랑 동일하게 해야 함 그리고 도커 설정에서도 노드 하나 늘려야 함. 실행 명령어에서도 바꾸고
#define MAX_THREADS 3 // 이거 동일하게 해야 함
#define CHUNK_REGION (512 * 1024)
#define MAX_CHUNKS 100000

extern const char *node_ips[MAX_NODES];
extern int node_ports[MAX_NODES];
extern int node_count;
extern int node_index;
extern int sockfds[MAX_NODES][MAX_THREADS];

#ifdef __cplusplus
extern "C" {
#endif

void init_node_list(int argc, char *argv[]);

#ifdef __cplusplus
}

#endif

#endif
