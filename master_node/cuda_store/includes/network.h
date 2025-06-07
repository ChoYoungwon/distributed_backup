#ifndef NETWORK_H
#define NETWORK_H

#include <stdint.h>

void close_all_connections();
int open_all_connections();
int open_connection(const char *ip, int port);
void close_connection(int sockfd);
int send_chunk_over_connection(int sockfd, const char *chunk_id, const uint8_t *data, size_t size);

#endif