#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define BUF_SIZE 4096
#define CHUNK_DIR "chunks"

void send_file(int client_socket) {
    char chunk_id[65] = {0};
    recv(client_socket, chunk_id, 64, 0);

    char filepath[128];
    snprintf(filepath, sizeof(filepath), "%s/%s", CHUNK_DIR, chunk_id);

    FILE *fp = fopen(filepath, "rb");
    if (!fp) {
        perror("file open failed");
        return;
    }

    char buffer[BUF_SIZE];
    size_t bytes;
    while ((bytes = fread(buffer, 1, BUF_SIZE, fp)) > 0) {
        send(client_socket, buffer, bytes, 0);
    }

    fclose(fp);
    printf("[+] Sent chunk %s\n", chunk_id);
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

/*void receive_file(int client_socket) {
    char chunk_id[65] = {0};
    recv(client_socket, chunk_id, 64, 0);

    uint32_t chunk_size_net;
    recv(client_socket, &chunk_size_net, sizeof(chunk_size_net), 0);
    uint32_t chunk_size = ntohl(chunk_size_net);

    char filepath[128];
    snprintf(filepath, sizeof(filepath), "chunks/%s", chunk_id);
    mkdir("chunks", 0755);

    FILE *fp = fopen(filepath, "wb");
    if (!fp) {
        perror("file open failed");
        return;
    }

    char buffer[4096];
    size_t received = 0;
    while (received < chunk_size) {
        ssize_t n = recv(client_socket, buffer, sizeof(buffer), 0);
        if (n <= 0) break;
        fwrite(buffer, 1, n, fp);
        received += n;
    }

    fclose(fp);
    printf("[+] Stored chunk %s (%u bytes)\n", chunk_id, chunk_size);
}*/