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

static uint64_t rabin_table[256];
static uint64_t out_table[256];
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

static uint64_t rabin_rolling_hash(uint8_t *window, size_t len) {
    uint64_t fp = 0;
    for (size_t i = 0; i < len; i++) {
        fp = (fp << 8) ^ rabin_table[(fp >> 56) ^ window[i]];
    }
    return fp;
}

static uint64_t rabin_slide_hash(uint64_t fp, uint8_t out_byte, uint8_t in_byte) {
    fp ^= out_table[out_byte];
    fp = (fp << 8) ^ rabin_table[(fp >> 56) ^ in_byte];
    return fp;
}

void rabin_init_tables() {
    for (int b = 0; b < 256; b++) {
        uint64_t fp = b;
        for (int i = 0; i < 8; i++) {
            if (fp & 1)
                fp = (fp >> 1) ^ POLY;
            else
                fp = (fp >> 1);
        }
        rabin_table[b] = fp;
    }

    for (int b = 0; b < 256; b++) {
        uint64_t h = b;
        for (int i = 0; i < WINDOW_SIZE - 1; i++) {
            h = (h << 8) ^ rabin_table[0];
        }
        out_table[b] = h;
    }
}

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

    if (open_all_connections(MAX_THREADS)) {
        munmap(file_data, file_size);
        close(fd);
        return;
    }

    long overlap = MAX_CHUNK_SIZE;
    long stride = CHUNK_REGION;
    int thread_count = (file_size + stride - 1) / stride;

    fflush(stdout);
    
    #pragma omp parallel for schedule(dynamic) num_threads(MAX_THREADS)
    for (int t = 0; t < thread_count; t++) {
        long start = t * stride;
        long end = start + stride + overlap;
        if (end > file_size) end = file_size;

        uint8_t *chunk_buf = malloc(MAX_CHUNK_SIZE);
        uint8_t slide_window[WINDOW_SIZE] = {0};
        size_t chunk_size = 0, window_pos = 0;
        uint64_t fingerprint = 0;

        fflush(stdout);
        
        for (long i = start; i < end; i++) {
            uint8_t b = file_data[i];
            chunk_buf[chunk_size++] = b;

            if (chunk_size <= WINDOW_SIZE) {
                slide_window[window_pos++ % WINDOW_SIZE] = b;
                if (chunk_size == WINDOW_SIZE)
                    fingerprint = rabin_rolling_hash(slide_window, WINDOW_SIZE);
                continue;
            }

            fingerprint = rabin_slide_hash(fingerprint, slide_window[window_pos % WINDOW_SIZE], b);
            slide_window[window_pos++ % WINDOW_SIZE] = b;

            if ((fingerprint & CHUNK_MASK) == 0 || chunk_size >= MAX_CHUNK_SIZE) {
                unsigned char sha[SHA256_DIGEST_LENGTH];
                SHA256(chunk_buf, chunk_size, sha);

                char chunk_id[65];
                for (int j = 0; j < SHA256_DIGEST_LENGTH; j++)
                    sprintf(chunk_id + j * 2, "%02x", sha[j]);
                chunk_id[64] = '\0';

                long offset = i - chunk_size + 1;
                int target_index;
                #pragma omp critical
                {
                    target_index = node_index;
                    node_index = (node_index + 1) % node_count;
                }

                int tid = omp_get_thread_num();
                int sockfd = sockfds[target_index][tid];
        
                fflush(stdout);
                send_chunk_over_connection(sockfd, chunk_id, chunk_buf, chunk_size);
        
                fflush(stdout);
                parrel_write_chunk_map(chunk_id, node_ips[target_index], node_ports[target_index], offset);
                chunk_size = 0;
            }
        }

        if (chunk_size > 0) {
            unsigned char sha[SHA256_DIGEST_LENGTH];
            SHA256(chunk_buf, chunk_size, sha);

            char chunk_id[65];
            for (int j = 0; j < SHA256_DIGEST_LENGTH; j++)
                sprintf(chunk_id + j * 2, "%02x", sha[j]);
            chunk_id[64] = '\0';

            long offset = end - chunk_size;
            int target_index;
            #pragma omp critical
            {
                target_index = node_index;
                node_index = (node_index + 1) % node_count;
            }

            int tid = omp_get_thread_num();
            int sockfd = sockfds[target_index][tid];
            send_chunk_over_connection(sockfd, chunk_id, chunk_buf, chunk_size);
            parrel_write_chunk_map(chunk_id, node_ips[target_index], node_ports[target_index], offset);
        }

        free(chunk_buf);
    }

    parrel_finish_chunk_map(metadata_path);
    close_all_connections();
    munmap(file_data, file_size);
    close(fd);
}