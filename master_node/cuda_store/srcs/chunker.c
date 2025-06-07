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

#define MIN_CHUNK_SIZE  (16 * 1024)
#define AVG_CHUNK_SIZE  (64 * 1024)
#define MAX_CHUNK_SIZE  (256 * 1024)
#define CHUNK_MASK      (AVG_CHUNK_SIZE - 1)
#define WINDOW_SIZE     48
#define CHUNK_REGION (512 * 1024)
#define POLY            0x3DA3358B4DC173ULL

static uint64_t rabin_table[256];
static uint64_t out_table[256];
static FILE *map_fp = NULL;
static int chunk_count = 0;

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

void write_chunk_map(const char *chunk_id, const char *ip, int port, const char *metadata_path) {
    if (map_fp == NULL) {
        map_fp = fopen(metadata_path, "w");
        fprintf(map_fp, "[\n");
        chunk_count = 0;
    }

    if (chunk_count > 0) {
        fprintf(map_fp, ",\n");
    }

    fprintf(map_fp, "  {\"chunk_id\": \"%s\", \"node\": \"%s:%d\"}", chunk_id, ip, port);
    chunk_count++;
    fflush(map_fp);
}

void finish_chunk_map() {
    if (map_fp) {
        fprintf(map_fp, "\n]\n");
        fclose(map_fp);
        map_fp = NULL;
    }
}

void chunk_and_process(const char *filepath, const char *metadata_path) {
    FILE *fp = fopen(filepath, "rb");
    if (!fp) {
        perror("fopen failed");
        return;
    }

    if (open_all_connections())
        return;

    uint8_t *chunk_buf = malloc(MAX_CHUNK_SIZE);
    uint8_t slide_window[WINDOW_SIZE] = {0};
    size_t chunk_size = 0, window_pos = 0;
    uint64_t fingerprint = 0;

    int byte;
    while ((byte = fgetc(fp)) != EOF) {
        uint8_t b = (uint8_t)byte;
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
            for (int i = 0; i < SHA256_DIGEST_LENGTH; i++)
                sprintf(chunk_id + i * 2, "%02x", sha[i]);
            chunk_id[64] = '\0';

            const char *ip = node_ips[node_index];
            int port = node_ports[node_index];

            //printf("[+] Sending chunk %s (size: %zu bytes) to %s:%d\n", chunk_id, chunk_size, ip, port);
            int target_index = node_index;
            node_index = (node_index + 1) % node_count;

            int sockfd = sockfds[target_index];
            send_chunk_over_connection(sockfd, chunk_id, chunk_buf, chunk_size);
            write_chunk_map(chunk_id, node_ips[target_index], node_ports[target_index], metadata_path);
            chunk_size = 0;
        }
    }

    if (chunk_size > 0) {
        unsigned char sha[SHA256_DIGEST_LENGTH];
        SHA256(chunk_buf, chunk_size, sha);

        char chunk_id[65];
        for (int i = 0; i < SHA256_DIGEST_LENGTH; i++)
            sprintf(chunk_id + i * 2, "%02x", sha[i]);
        chunk_id[64] = '\0';

        const char *ip = node_ips[node_index];
        int port = node_ports[node_index];

        //printf("[+] Sending final chunk %s (size: %zu bytes) to %s:%d\n", chunk_id, chunk_size, ip, port);
        int target_index = node_index;
        node_index = (node_index + 1) % node_count;

        int sockfd = sockfds[target_index];
        send_chunk_over_connection(sockfd, chunk_id, chunk_buf, chunk_size);
        write_chunk_map(chunk_id, ip, port, metadata_path);
    }

    finish_chunk_map();
    close_all_connections();
    free(chunk_buf);
    fclose(fp);

    if (map_fp) {
        fprintf(map_fp, "]\n");
        fclose(map_fp);
    }
}
