#include <jansson.h>
#include "network.h"
#include "timer.h"
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdlib.h>

typedef struct {
    char ip[64];
    int port;
    int sockfd;
} NodeConnection;

NodeConnection conns[64];
int conn_count = 0;

int find_or_open_connection(const char *ip, int port) {
    for (int i = 0; i < conn_count; i++) {
        if (strcmp(conns[i].ip, ip) == 0 && conns[i].port == port)
            return conns[i].sockfd;
    }

    int sockfd = open_restore_connection(ip, port);
    if (sockfd >= 0) {
        strcpy(conns[conn_count].ip, ip);
        conns[conn_count].port = port;
        conns[conn_count].sockfd = sockfd;
        conn_count++;
    }
    return sockfd;
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <chunk_map.json> <output_file>\n", argv[0]);
        return 1;
    }

    const char *map_path = argv[1];
    const char *output_path = argv[2];
    Timer t1;

    timer_start(&t1);
    json_error_t error;
    json_t *root = json_load_file(map_path, 0, &error);
    if (!root || !json_is_array(root)) {
        fprintf(stderr, "Failed to parse JSON: %s\n", error.text);
        return 1;
    }

    int out_fd = open(output_path, O_CREAT | O_WRONLY, 0666);
    if (out_fd < 0) {
        perror("open output");
        return 1;
    }

    size_t index;
    json_t *entry;
    json_array_foreach(root, index, entry) {
        const char *chunk_id = json_string_value(json_object_get(entry, "chunk_id"));
        const char *node = json_string_value(json_object_get(entry, "node"));
        json_t *offset_json = json_object_get(entry, "offset");
        if (!chunk_id || !node || !json_is_integer(offset_json)) continue;

        long offset = json_integer_value(offset_json);

        char ip[64];
        int port;
        sscanf(node, "%63[^:]:%d", ip, &port);

        int sockfd = find_or_open_connection(ip, port);
        if (sockfd < 0) {
            fprintf(stderr, "[-] Failed to connect to %s:%d\n", ip, port);
            continue;
        }

        uint8_t *chunk_data = NULL;
        size_t chunk_size = 0;
        if (recv_chunk(sockfd, chunk_id, &chunk_data, &chunk_size) != 0) {
            fprintf(stderr, "[-] Failed to fetch chunk: %s\n", chunk_id);
            continue;
        }

        if (pwrite(out_fd, chunk_data, chunk_size, offset) != chunk_size) {
            perror("pwrite");
        }
        free(chunk_data);
    }

    for (int i = 0; i < conn_count; i++) {
        close_restore_connection(conns[i].sockfd);
    }

    timer_end(&t1);
    timer_print(&t1, "Parallel Code");
    close(out_fd);
    json_decref(root);
    printf("[\u2713] Restore complete: %s\n", output_path);
    return 0;
}
