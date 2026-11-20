#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "reference.h"

enum { TRIALS = 15 };
static int16_t input[FIR_SAMPLES], single[FIR_SAMPLES], dual[FIR_SAMPLES];
static sem_t ready, finished;
static int stop;

static void check(int error, const char *operation)
{
    if (error) {
        fprintf(stderr, "%s: %s\n", operation, strerror(error));
        exit(EXIT_FAILURE);
    }
}

static void wait_for(sem_t *semaphore)
{
    while (sem_wait(semaphore) != 0) {
        if (errno != EINTR)
            check(errno, "sem_wait");
    }
}

static void signal_to(sem_t *semaphore)
{
    if (sem_post(semaphore))
        check(errno, "sem_post");
}

static void *worker(void *unused)
{
    (void)unused;
    for (;;) {
        wait_for(&ready);
        if (stop)
            return NULL;
        fir_range(input, dual, FIR_SAMPLES / 2, FIR_SAMPLES);
        signal_to(&finished);
    }
}

static double now_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts))
        check(errno, "clock_gettime");
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static double run(int parallel)
{
    double start = now_ms();
    if (parallel) {
        signal_to(&ready);
        fir_range(input, dual, 0, FIR_SAMPLES / 2);
        wait_for(&finished);
    } else {
        fir_reference(input, single, FIR_SAMPLES);
    }
    return now_ms() - start;
}

static void pin(pthread_t thread, int cpu)
{
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    check(pthread_setaffinity_np(thread, sizeof(set), &set), "pthread_setaffinity_np");
}

static int compare_time(const void *first, const void *second)
{
    double a = *(const double *)first, b = *(const double *)second;
    return (a > b) - (a < b);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "Usage: %s input.s16le\n", argv[0]);
        return 1;
    }
    FILE *file = fopen(argv[1], "rb");
    if (!file)
        check(errno, "fopen");
    if (fread(input, 1, sizeof(input), file) != sizeof(input) ||
        fgetc(file) != EOF || ferror(file)) {
        fputs("Expected a 32768-byte little-endian PCM clip\n", stderr);
        return 1;
    }
    fclose(file);

    cpu_set_t allowed;
    if (sched_getaffinity(0, sizeof(allowed), &allowed))
        check(errno, "sched_getaffinity");
    int cpus[2], found = 0;
    for (int cpu = 0; cpu < CPU_SETSIZE && found < 2; ++cpu)
        if (CPU_ISSET(cpu, &allowed))
            cpus[found++] = cpu;
    if (found != 2) {
        fputs("Two available CPUs are required\n", stderr);
        return 1;
    }
    if (sem_init(&ready, 0, 0) || sem_init(&finished, 0, 0))
        check(errno, "sem_init");
    pthread_t thread;
    check(pthread_create(&thread, NULL, worker, NULL), "pthread_create");
    pin(pthread_self(), cpus[0]);
    pin(thread, cpus[1]);

    printf("Main CPU %d, worker CPU %d\n", cpus[0], cpus[1]);
    run(0);
    run(1);
    double one[TRIALS], two[TRIALS];
    for (int trial = 0; trial < TRIALS; ++trial) {
        if (trial % 2) {
            two[trial] = run(1);
            one[trial] = run(0);
        } else {
            one[trial] = run(0);
            two[trial] = run(1);
        }
        if (memcmp(single, dual, sizeof(single))) {
            fputs("ARM output mismatch\n", stderr);
            return 1;
        }
        printf("Trial %2d  single %8.3f ms  dual %8.3f ms\n",
               trial + 1, one[trial], two[trial]);
    }
    stop = 1;
    signal_to(&ready);
    check(pthread_join(thread, NULL), "pthread_join");
    sem_destroy(&ready);
    sem_destroy(&finished);
    qsort(one, TRIALS, sizeof(*one), compare_time);
    qsort(two, TRIALS, sizeof(*two), compare_time);
    printf("MATCH all %d samples in all %d trials\n", FIR_SAMPLES, TRIALS);
    printf("Single-core median %.3f ms\n", one[TRIALS / 2]);
    printf("Dual-core median   %.3f ms\n", two[TRIALS / 2]);
    printf("ARM speedup        %.3fx\n", one[TRIALS / 2] / two[TRIALS / 2]);
    return 0;
}
