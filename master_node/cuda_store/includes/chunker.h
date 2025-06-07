#ifndef CHUNKER_H
#define CHUNKER_H

void chunk_and_process_cuda(const char *filepath, const char *metadata_path);
void process_chunk(uint8_t *chunk_buf, const uint8_t *data, size_t chunk_size, const char *metadata_path);
void load_rabin_tables(uint64_t *table);

#endif