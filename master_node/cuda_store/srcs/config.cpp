#include <stdlib.h>
#include "config.h"

const char *node_ips[MAX_NODES];
int node_ports[MAX_NODES];
int node_count = 0;
int node_index = 0;
int sockfds[MAX_NODES];

void init_node_list(int argc, char *argv[]) {
    node_count = (argc - 3) / 2;
    for (int i = 0; i < node_count; i++) {
        node_ips[i] = argv[3 + i * 2];
        node_ports[i] = atoi(argv[4 + i * 2]);
    }
}