#ifndef CONFIG_H
#define CONFIG_H

#define MAX_NODES 8

extern const char *node_ips[MAX_NODES];
extern int node_ports[MAX_NODES];
extern int node_count;
extern int node_index;
extern int sockfds[MAX_NODES];

void init_node_list(int argc, char *argv[]);

#endif