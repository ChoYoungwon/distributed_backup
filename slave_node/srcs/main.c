#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <omp.h>

#include "handler.h"  // handle_client() 정의되어 있어야 함

#define PORT 9001
#define MAX_CLIENTS 64

int main() {
    int server_fd, client_fd;
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        exit(1);
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    addr.sin_family = AF_INET;
    addr.sin_port = htons(PORT);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        exit(1);
    }

    if (listen(server_fd, MAX_CLIENTS) < 0) {
        perror("listen");
        close(server_fd);
        exit(1);
    }

    printf("[*] Server listening on port %d\n", PORT);

    // OpenMP 병렬 영역
    #pragma omp parallel num_threads(4)  // 적당한 스레드 수로 설정
    {
        while (1) {
            int client_fd;
            struct sockaddr_in client_addr;
            socklen_t client_len = sizeof(client_addr);

            #pragma omp critical  // accept는 동시에 호출되면 안 됨
            {
                client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
            }

            if (client_fd < 0) continue;

            int flag = 1;
            setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, (char *)&flag, sizeof(int));

            handle_client(client_fd);
            close(client_fd);
        }
    }

    close(server_fd);
    return 0;
}