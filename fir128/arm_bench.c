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
#ifdef __ARM_NEON
#include <arm_neon.h>
#endif

enum { TRIALS = 15 };
static int16_t input[FIR_SAMPLES], single[FIR_SAMPLES], dual[FIR_SAMPLES];
static sem_t ready, finished;
static int stop;

#ifdef __ARM_NEON
static int use_neon;
static int16_t padded[FIR_SAMPLES + FIR_TAPS - 1], neon_output[FIR_SAMPLES];
static const int16_t neon_coefficients[FIR_TAPS] = {
#include "coeff.inc"
};

static void neon_range(size_t begin, size_t end)
{
    for (size_t index = begin; index < end; index += 4) {
        const int16_t *samples = padded + index + FIR_TAPS - 1;
        int32x4_t first = vdupq_n_s32(0), second = first;
        for (size_t tap = 0; tap < FIR_TAPS / 2; ++tap) {
            first = vmlal_n_s16(first, vld1_s16(samples - tap), neon_coefficients[tap]);
            second = vmlal_n_s16(second, vld1_s16(samples - tap - FIR_TAPS / 2),
                                neon_coefficients[tap + FIR_TAPS / 2]);
        }
        // A sum beyond int32 already saturates at Q15 output precision.
        int32_t sums[4];
        vst1q_s32(sums, vqaddq_s32(first, second));
        for (unsigned lane = 0; lane < 4; ++lane)
            neon_output[index + lane] = fir_quantize(sums[lane]);
    }
}

static int neon_safe(void)
{
    for (unsigned half = 0; half < 2; ++half) {
        int64_t bound = 0;
        for (unsigned tap = 0; tap < FIR_TAPS / 2; ++tap)
            bound += (int64_t)abs(neon_coefficients[half * (FIR_TAPS / 2) + tap]) * 32768;
        if (bound > INT32_MAX)
            return 0;
    }
    return 1;
}
#endif

static void run_half(size_t begin, size_t end)
{
#ifdef __ARM_NEON
    if (use_neon) {
        neon_range(begin, end);
        return;
    }
#endif
    fir_range(input, dual, begin, end);
}

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
        run_half(FIR_SAMPLES / 2, FIR_SAMPLES);
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
#ifdef __ARM_NEON
        use_neon = parallel == 2;
        if (use_neon)
            memcpy(padded + FIR_TAPS - 1, input, sizeof(input));
#endif
        signal_to(&ready);
        run_half(0, FIR_SAMPLES / 2);
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
#ifdef __ARM_NEON
    if (!neon_safe()) {
        fputs("NEON accumulation bounds exceeded for these coefficients\n", stderr);
        return 1;
    }
    enum { MODES = 3 };
    run(2);
#else
    enum { MODES = 2 };
#endif
    double timings[MODES][TRIALS];
    for (unsigned trial = 0; trial < TRIALS; ++trial) {
        for (unsigned offset = 0; offset < MODES; ++offset) {
            unsigned mode = (trial + offset) % MODES;
            timings[mode][trial] = run(mode);
        }
        if (memcmp(single, dual, sizeof(single))) {
            fputs("ARM output mismatch\n", stderr);
            return 1;
        }
#ifdef __ARM_NEON
        if (memcmp(single, neon_output, sizeof(single))) {
            fputs("NEON output mismatch\n", stderr);
            return 1;
        }
#endif
        printf("Trial %2u  single %8.3f ms  dual %8.3f ms",
               trial + 1, timings[0][trial], timings[1][trial]);
#ifdef __ARM_NEON
        printf("  dual NEON %8.3f ms", timings[2][trial]);
#endif
        putchar('\n');
    }
    stop = 1;
    signal_to(&ready);
    check(pthread_join(thread, NULL), "pthread_join");
    sem_destroy(&ready);
    sem_destroy(&finished);
    for (unsigned mode = 0; mode < MODES; ++mode)
        qsort(timings[mode], TRIALS, sizeof(double), compare_time);
    double single_median = timings[0][TRIALS / 2];
    double dual_median = timings[1][TRIALS / 2];
    printf("MATCH all %d samples in all %d trials\n", FIR_SAMPLES, TRIALS);
    printf("Single-core median %.3f ms\n", single_median);
    printf("Dual-core median   %.3f ms\n", dual_median);
    printf("ARM speedup        %.3fx\n", single_median / dual_median);
#ifdef __ARM_NEON
    double neon_median = timings[2][TRIALS / 2];
    printf("Dual NEON median   %.3f ms\n", neon_median);
    printf("NEON over dual C   %.3fx\n", dual_median / neon_median);
#endif
    return 0;
}
