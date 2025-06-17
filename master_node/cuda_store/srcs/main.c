#include <stdio.h>
#include <stdint.h>
#include "chunker.h"
#include "config.h"
#include "timer.h"

static inline uint64_t rdtsc() {
    unsigned int lo, hi;
    __asm__ __volatile__ (
        "cpuid\n\t"      // serialize
        "rdtsc\n\t"      // read time stamp counter
        : "=a"(lo), "=d"(hi)
        : "a"(0)
        : "%ebx", "%ecx"
    );
    return ((uint64_t)hi << 32) | lo;
}

int main(int argc, char *argv[]) {
    if (argc < 4 || (argc - 3) % 2 != 0) {
        fprintf(stderr, "Usage: %s <file_path> <metadata_path> <node1_ip> <node1_port> [<node2_ip> <node2_port> ...]\n", argv[0]);
        return 1;
    }

    const char *file_path = argv[1];
    const char *metadata_path = argv[2];
    uint64_t cycles_start = rdtsc();
    init_node_list(argc, argv);
    rabin_init_tables();
    chunk_and_process(file_path, metadata_path);

    uint64_t cycles_end = rdtsc();
    uint64_t cycles_elapsed = cycles_end - cycles_start;

    printf("[RDTSC] Parallel Code: %llu CPU cycles\n", (unsigned long long)cycles_elapsed);

    return 0;
}
