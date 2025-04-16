#include <jansson.h>
#include "network.h"
#include "timer.h"
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <omp.h>

typedef struct {
    char chunk_id[65];
    char ip[64];
    int port;
    long offset;
} ChunkEntry;

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

    size_t total = json_array_size(root);
    ChunkEntry *entries = malloc(sizeof(ChunkEntry) * total);
    if (!entries) {
        perror("malloc");
        return 1;
    }

    for (size_t i = 0; i < total; i++) {
        json_t *entry = json_array_get(root, i);
        const char *chunk_id = json_string_value(json_object_get(entry, "chunk_id"));
        const char *node = json_string_value(json_object_get(entry, "node"));
        json_t *offset_json = json_object_get(entry, "offset");
        if (!chunk_id || !node || !json_is_integer(offset_json)) continue;

        long offset = json_integer_value(offset_json);
        char ip[64];
        int port;
        sscanf(node, "%63[^:]:%d", ip, &port);

        strncpy(entries[i].chunk_id, chunk_id, sizeof(entries[i].chunk_id));
        strncpy(entries[i].ip, ip, sizeof(entries[i].ip));
        entries[i].port = port;
        entries[i].offset = offset;

        find_or_open_connections(ip, port);
    }

    #pragma omp parallel for num_threads(MAX_THREADS) schedule(dynamic)
    for (size_t i = 0; i < total; i++) {
        int tid = omp_get_thread_num();
        int conn_idx = find_or_open_connections(entries[i].ip, entries[i].port);
        int sockfd = conns[conn_idx].sockfd[tid];

        uint8_t *chunk_data = NULL;
        size_t chunk_size = 0;
        if (recv_chunk(sockfd, entries[i].chunk_id, &chunk_data, &chunk_size) != 0) {
            #pragma omp critical
            fprintf(stderr, "[-] Failed to fetch chunk: %s\n", entries[i].chunk_id);
            continue;
        }

        if (pwrite(out_fd, chunk_data, chunk_size, entries[i].offset) != chunk_size) {
            #pragma omp critical
            perror("pwrite");
        }
        free(chunk_data);
    }

    for (int i = 0; i < conn_count; i++) {
        for (int t = 0; t < MAX_THREADS; t++) {
            close_restore_connection(conns[i].sockfd[t]);
        }
    }

    free(entries);
    close(out_fd);
    json_decref(root);
    timer_end(&t1);
    timer_print(&t1, "Parallel Restore");
    printf("[\u2713] Restore complete: %s\n", output_path);
    return 0;
}