#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdlib.h>
#include "network.h"

NodeConnection conns[64];
int conn_count = 0;

int find_or_open_connections(const char *ip, int port) {
    for (int i = 0; i < conn_count; i++) {
        if (strcmp(conns[i].ip, ip) == 0 && conns[i].port == port) {
            return i;
        }
    }

    int index = conn_count;
    strncpy(conns[index].ip, ip, sizeof(conns[index].ip));
    conns[index].port = port;

    for (int t = 0; t < MAX_THREADS; t++) {
        conns[index].sockfd[t] = open_restore_connection(ip, port);
        if (conns[index].sockfd[t] < 0) {
            fprintf(stderr, "[-] Failed to open connection to %s:%d for thread %d\n", ip, port, t);
        }
    }
    conn_count++;
    return index;
}

#define BUF_SIZE 4096

int open_restore_connection(const char *ip, int port) {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) return -1;

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);

    if (connect(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(sockfd);
        return -1;
    }
    int flag = 1;
    setsockopt(sockfd, IPPROTO_TCP, TCP_NODELAY, (char *)&flag, sizeof(int));

    return sockfd;
}

void close_restore_connection(int sockfd) {
    close(sockfd);
}

int recv_chunk(int sockfd, const char *chunk_id, uint8_t **chunk_data, size_t *chunk_size) {
    if (send(sockfd, "SEND", 4, 0) != 4) return -1;
    if (send(sockfd, chunk_id, 64, 0) != 64) return -1;

    uint32_t chunk_size_net;
    if (recv(sockfd, &chunk_size_net, sizeof(chunk_size_net), 0) != sizeof(chunk_size_net)) {
        perror("recv chunk size");
        return -1;
    }
    *chunk_size = ntohl(chunk_size_net);

    *chunk_data = malloc(*chunk_size);
    if (!*chunk_data) {
        perror("malloc");
        return -1;
    }

    size_t received = 0;
    while (received < *chunk_size) {
        size_t to_read = (*chunk_size - received > BUF_SIZE) ? BUF_SIZE : *chunk_size - received;
        ssize_t n = recv(sockfd, *chunk_data + received, to_read, 0);
        if (n <= 0) {
            perror("recv chunk data");
            free(*chunk_data);
            return -1;
        }
        received += n;
    }

    return 0;
}
