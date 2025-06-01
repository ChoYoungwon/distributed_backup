#ifndef CHUNKER_H
#define CHUNKER_H

void rabin_init_tables();
void chunk_and_process(const char *filepath, const char *metadata_path);
void parrel_chunk_and_process(const char *filepath, const char *metadata_path);

#endif