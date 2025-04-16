#ifndef NETWORK_H
#define NETWORK_H

#include <stdint.h>

#define MAX_THREADS 4
#define BUF_SIZE 4096

typedef struct {
    char ip[64];
    int port;
    int sockfd[MAX_THREADS];
} NodeConnection;

extern NodeConnection conns[64];
extern int conn_count;

int find_or_open_connections(const char *ip, int port);
int open_restore_connection(const char *ip, int port);
void close_restore_connection(int sockfd);
int recv_chunk(int sockfd, const char *chunk_id, uint8_t **chunk_data, size_t *chunk_size);

#endif