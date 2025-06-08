#ifndef TIMER_H
#define TIMER_H

#include <time.h>

typedef struct {
    struct timespec start;
    struct timespec end;
} Timer;

#ifdef __cplusplus
extern "C" {
#endif

// 타이머 시작/종료
void timer_start(Timer *t);
void timer_end(Timer *t);

// 경과 시간 계산 및 출력
double timer_elapsed(const Timer *t);
void timer_print(const Timer *t, const char *label);

#ifdef __cplusplus
}

#endif

#endif