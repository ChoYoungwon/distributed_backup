#ifndef NETWORK_H
#define NETWORK_H

int open_restore_connection(const char *ip, int port);
void close_restore_connection(int sockfd);
int send_chunk_request(int sockfd, const char *chunk_id, FILE *fp);

#endif