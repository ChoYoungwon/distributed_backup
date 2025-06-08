#ifndef CHUNKER_H
#define CHUNKER_H

#ifdef __cplusplus
extern "C" {
#endif

void rabin_init_tables();
void chunk_and_process(const char *filepath, const char *metadata_path);
void parrel_chunk_and_process(const char *filepath, const char *metadata_path);

#ifdef __cplusplus
}


#endif

#endif