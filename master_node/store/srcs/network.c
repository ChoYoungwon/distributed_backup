#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include "network.h"
#include "config.h"

int open_all_connections() {
    for (int i = 0; i < node_count; i++) {
        sockfds[i] = open_connection(node_ips[i], node_ports[i]);
        if (sockfds[i] < 0) {
            fprintf(stderr, "[-] Failed to connect to node %s:%d\n", node_ips[i], node_ports[i]);
            return -1;
        } else {
            printf("[+] Connected to node %s:%d (fd: %d)\n", node_ips[i], node_ports[i], sockfds[i]);
        }
    }
    return 0;
}

void close_all_connections() {
    for (int i = 0; i < node_count; i++) {
        if (sockfds[i] >= 0) {
            close_connection(sockfds[i]);
            sockfds[i] = -1;
        }
    }
}

int open_connection(const char *ip, int port) {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("socket failed");
        return -1;
    }

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, ip, &addr.sin_addr);

    if (connect(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect failed");
        close(sockfd);
        return -1;
    }

    return sockfd;
}

void close_connection(int sockfd) {
    close(sockfd);
}

int send_chunk_over_connection(int sockfd, const char *chunk_id, const uint8_t *data, size_t size) {
    if (send(sockfd, "PUT\0", 4, 0) != 4) 
        return -1;
    if (send(sockfd, chunk_id, 64, 0) != 64)
        return -1;

    uint32_t chunk_size = htonl((uint32_t)size);
    if (send(sockfd, &chunk_size, sizeof(chunk_size), 0) != sizeof(chunk_size))
        return -1;
    size_t sent = 0;
    while (sent < size) {
        ssize_t n = send(sockfd, data + sent, size - sent, 0);
        if (n <= 0) return -1;
            sent += n;
    }

    return (sent == size) ? 0 : -1;
}
