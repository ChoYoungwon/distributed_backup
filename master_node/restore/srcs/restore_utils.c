#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include "restore_utils.h"

#define BUF_SIZE 4096

int request_chunk(const char *ip, int port, const char *chunk_id, FILE *out_fp) {
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

    send(sockfd, "SEND", 4, 0);
    send(sockfd, chunk_id, 64, 0);

    char buffer[BUF_SIZE];
    ssize_t bytes;
    while ((bytes = recv(sockfd, buffer, BUF_SIZE, 0)) > 0) {
        fwrite(buffer, 1, bytes, out_fp);
    }

    close(sockfd);
    return 0;
}