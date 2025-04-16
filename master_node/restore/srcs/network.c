#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include "network.h"

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

int send_chunk_request(int sockfd, const char *chunk_id, FILE *out_fp) {
    // 1. 명령 전송
    if (send(sockfd, "SEND", 4, 0) != 4) return -1;
    if (send(sockfd, chunk_id, 64, 0) != 64) return -1;

    // 2. chunk 크기 수신
    uint32_t chunk_size_net;
    if (recv(sockfd, &chunk_size_net, sizeof(chunk_size_net), 0) != sizeof(chunk_size_net)) {
        perror("recv chunk size");
        return -1;
    }
    uint32_t chunk_size = ntohl(chunk_size_net);

    // 3. chunk_size 만큼 정확히 받기
    char buffer[BUF_SIZE];
    size_t received = 0;
    while (received < chunk_size) {
        size_t to_read = (chunk_size - received > BUF_SIZE) ? BUF_SIZE : chunk_size - received;
        ssize_t n = recv(sockfd, buffer, to_read, 0);
        if (n <= 0) {
            perror("recv chunk data");
            return -1;
        }
        fwrite(buffer, 1, n, out_fp);
        received += n;
    }

    return 0;
}