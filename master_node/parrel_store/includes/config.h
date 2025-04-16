#ifndef CONFIG_H
#define CONFIG_H

#define MAX_NODES 3
#define MAX_THREADS 
#define MIN_CHUNK_SIZE  (16 * 1024)
#define AVG_CHUNK_SIZE  (64 * 1024)
#define MAX_CHUNK_SIZE  (256 * 1024)
#define CHUNK_MASK      (AVG_CHUNK_SIZE - 1)
#define WINDOW_SIZE     48
#define CHUNK_REGION (512 * 1024)
#define POLY            0x3DA3358B4DC173ULL
#define MAX_CHUNKS 100000

extern const char *node_ips[MAX_NODES];
extern int node_ports[MAX_NODES];
extern int node_count;
extern int node_index;
extern int sockfds[MAX_NODES][MAX_THREADS];

void init_node_list(int argc, char *argv[]);

#endif