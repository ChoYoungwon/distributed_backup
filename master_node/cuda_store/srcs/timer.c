#include "timer.h"
#include <stdio.h>

void timer_start(Timer *t) {
    clock_gettime(CLOCK_MONOTONIC, &t->start);
}

void timer_end(Timer *t) {
    clock_gettime(CLOCK_MONOTONIC, &t->end);
}

double timer_elapsed(const Timer *t) {
    double start_sec = t->start.tv_sec + t->start.tv_nsec / 1e9;
    double end_sec   = t->end.tv_sec   + t->end.tv_nsec   / 1e9;
    return end_sec - start_sec;
}

void timer_print(const Timer *t, const char *label) {
    printf("[TIMER] %s: %.6f seconds\n", label, timer_elapsed(t));
}