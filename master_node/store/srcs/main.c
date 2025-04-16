#include <stdio.h>
#include "chunker.h"
#include "config.h"
#include "timer.h"

int main(int argc, char *argv[]) {
    if (argc < 4 || (argc - 3) % 2 != 0) {
        fprintf(stderr, "Usage: %s <file_path> <metadata_path> <node1_ip> <node1_port> [<node2_ip> <node2_port> ...]\n", argv[0]);
        return 1;
    }

    const char *file_path = argv[1];
    const char *metadata_path = argv[2];
    Timer t1;
    Timer t2;
    init_node_list(argc, argv);
    rabin_init_tables();

    timer_start(&t1);
    chunk_and_process(file_path, metadata_path);
    timer_end(&t1);

    timer_print(&t1, "Serial Code");

    return 0;
}
