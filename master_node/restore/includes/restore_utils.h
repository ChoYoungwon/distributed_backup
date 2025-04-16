#ifndef RESTORE_UTILS_H
#define RESTORE_UTILS_H

#include <stdio.h>

int request_chunk(const char *ip, int port, const char *chunk_id, FILE *out_fp);

#endif