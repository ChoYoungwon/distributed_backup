#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <omp.h>
#include <openssl/sha.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include "chunker.h"
#include "config.h"
#include "network.h"
#include "timer.h"

static FILE *map_fp = NULL;
static int chunk_count = 0;

typedef struct {
    char chunk_id[65];
    char node_ip[32];
    int node_port;
    long offset;
} ChunkInfo;

static ChunkInfo chunk_infos[MAX_CHUNKS];
static int chunk_info_count = 0;

void parrel_write_chunk_map(const char *chunk_id, const char *ip, int port, long offset) {
    #pragma omp critical
    {
        if (chunk_info_count < MAX_CHUNKS) {
            strncpy(chunk_infos[chunk_info_count].chunk_id, chunk_id, 65);
            strncpy(chunk_infos[chunk_info_count].node_ip, ip, 32);
            chunk_infos[chunk_info_count].node_port = port;
            chunk_infos[chunk_info_count].offset = offset;
            chunk_info_count++;
        }
    }
}

void parrel_finish_chunk_map(const char *metadata_path) {
    FILE *fp = fopen(metadata_path, "w");
    if (!fp) {
        perror("fopen");
        return;
    }
    fprintf(fp, "[\n");
    for (int i = 0; i < chunk_info_count; i++) {
        fprintf(fp, "  {\"chunk_id\": \"%s\", \"offset\": %ld, \"node\": \"%s:%d\"}%s\n",
                chunk_infos[i].chunk_id,
                chunk_infos[i].offset,
                chunk_infos[i].node_ip,
                chunk_infos[i].node_port,
                (i < chunk_info_count - 1) ? "," : "");
    }
    fprintf(fp, "]\n");
    fclose(fp);
}

void parrel_chunk_and_process(const char *filepath, const char *metadata_path) {
    int fd = open(filepath, O_RDONLY);
    if (fd < 0) {
        perror("open failed");
        return;
    }

    struct stat st;
    if (fstat(fd, &st) < 0) {
        perror("fstat failed");
        close(fd);
        return;
    }

    long file_size = st.st_size;
    uint8_t *file_data = mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (file_data == MAP_FAILED) {
        perror("mmap failed");
        close(fd);
        return;
    }

    // GPU 기반 Rabin 청크 분할 호출
    int *chunk_offsets = NULL, *chunk_lengths = NULL;
    int chunk_count = 0;
    rabin_kernel_call(file_data, file_size, &chunk_offsets, &chunk_lengths, &chunk_count);

    if (open_all_connections(MAX_THREADS)) {
        munmap(file_data, file_size);
        close(fd);
        free(chunk_offsets);
        free(chunk_lengths);
        return;
    }

    #pragma omp parallel for schedule(dynamic) num_threads(MAX_THREADS)
    for (int i = 0; i < chunk_count; i++) {
        int offset = chunk_offsets[i];
        int length = chunk_lengths[i];
        if (offset + length > file_size) continue;

        uint8_t *chunk_buf = malloc(length);
        memcpy(chunk_buf, file_data + offset, length);

        unsigned char sha[SHA256_DIGEST_LENGTH];
        SHA256(chunk_buf, length, sha);

        char chunk_id[65];
        for (int j = 0; j < SHA256_DIGEST_LENGTH; j++)
            sprintf(chunk_id + j * 2, "%02x", sha[j]);
        chunk_id[64] = '\0';

        int target_index;
        #pragma omp critical
        {
            target_index = node_index;
            node_index = (node_index + 1) % node_count;
        }

        int tid = omp_get_thread_num();
        int sockfd = sockfds[target_index][tid];
        send_chunk_over_connection(sockfd, chunk_id, chunk_buf, length);
        parrel_write_chunk_map(chunk_id, node_ips[target_index], node_ports[target_index], offset);

        free(chunk_buf);
    }

    parrel_finish_chunk_map(metadata_path);
    close_all_connections();
    munmap(file_data, file_size);
    close(fd);
    free(chunk_offsets);
    free(chunk_lengths);
}
