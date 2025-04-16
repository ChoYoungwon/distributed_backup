#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>

#define BUF_SIZE 4096
#define CHUNK_DIR "chunks"

ssize_t read_exact(int sockfd, void *buffer, size_t length) {
    size_t total_read = 0;
    while (total_read < length) {
        ssize_t bytes = recv(sockfd, (char*)buffer + total_read, length - total_read, 0);
        if (bytes <= 0) return -1;  // error or closed
        total_read += bytes;
    }
    return total_read;
}

void send_file(int client_socket) {
    char chunk_id[65] = {0};
    if (read_exact(client_socket, chunk_id, 64) <= 0) {
        perror("failed to read chunk_id");
        return;
    }

    char filepath[128];
    snprintf(filepath, sizeof(filepath), "%s/%s", CHUNK_DIR, chunk_id);

    FILE *fp = fopen(filepath, "rb");
    if (!fp) {
        perror("file open failed");
        return;
    }

    fseek(fp, 0, SEEK_END);
    uint32_t chunk_size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    uint32_t chunk_size_net = htonl(chunk_size);
    if (send(client_socket, &chunk_size_net, sizeof(chunk_size_net), 0) != sizeof(chunk_size_net)) {
        perror("failed to send chunk size");
        fclose(fp);
        return;
    }

    char buffer[BUF_SIZE];
    size_t bytes;
    while ((bytes = fread(buffer, 1, BUF_SIZE, fp)) > 0) {
        if (send(client_socket, buffer, bytes, 0) != bytes) {
            perror("send failed");
            break;
        }
    }

    fclose(fp);
    printf("[+] Sent chunk %s (%u bytes)\n", chunk_id, chunk_size);
}

void receive_file(int client_socket) {
    char chunk_id[65] = {0};
    if (read_exact(client_socket, chunk_id, 64) <= 0) {
        perror("failed to read chunk_id");
        return;
    }

    uint32_t chunk_size_net;
    if (read_exact(client_socket, &chunk_size_net, sizeof(chunk_size_net)) <= 0) {
        perror("failed to read chunk size");
        return;
    }
    uint32_t chunk_size = ntohl(chunk_size_net);

    mkdir("chunks", 0755);  // ensure directory exists

    char filepath[128];
    snprintf(filepath, sizeof(filepath), "chunks/%s", chunk_id);

    FILE *fp = fopen(filepath, "wb");
    if (!fp) {
        perror("file open failed");
        return;
    }

    char buffer[4096];
    size_t received = 0;
    while (received < chunk_size) {
        size_t to_read = (chunk_size - received > sizeof(buffer)) ? sizeof(buffer) : chunk_size - received;
        ssize_t n = recv(client_socket, buffer, to_read, 0);
        if (n <= 0) break;
        fwrite(buffer, 1, n, fp);
        received += n;
    }

    fclose(fp);
    printf("[+] Stored chunk %s (%u bytes)\n", chunk_id, chunk_size);
}

void handle_client(int client_socket) {
    while (1) {
        char command[4] = {0};
        ssize_t n = read_exact(client_socket, command, 4);
        if (n <= 0) break;

        if (strncmp(command, "PUT", 4) == 0) {
            receive_file(client_socket);
        } else if (strncmp(command, "SEND", 4) == 0) {
            send_file(client_socket);
        } else {
            printf("Unknown command: %.*s\n", 4, command);
            break;
        }
    }

    close(client_socket);
}