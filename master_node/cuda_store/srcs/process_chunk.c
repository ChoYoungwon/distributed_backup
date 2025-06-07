#include <openssl/sha.h>
#include <stdio.h>
#include <string.h>
#include "config.h"
#include "network.h"
#include "chunker.h"

void process_chunk(uint8_t *chunk_buf, const uint8_t *data, size_t chunk_size, const char *metadata_path) {
    memcpy(chunk_buf, data, chunk_size);

    unsigned char sha[SHA256_DIGEST_LENGTH];
    SHA256(chunk_buf, chunk_size, sha);

    char chunk_id[65];
    for (int i = 0; i < SHA256_DIGEST_LENGTH; i++)
        sprintf(chunk_id + i * 2, "%02x", sha[i]);
    chunk_id[64] = '\0';

    int target = node_index;
    node_index = (node_index + 1) % node_count;
    send_chunk_over_connection(sockfds[target], chunk_id, chunk_buf, chunk_size);
    write_chunk_map(chunk_id, node_ips[target], node_ports[target], metadata_path);
}