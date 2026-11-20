/*
 * LD_PRELOAD shim that makes wine's view of wall-clock time and randomness
 * constant, so a prefix built inside the Nix sandbox is bit-for-bit
 * reproducible (registry key timestamps, MachineGuid, ContainerIds, ...).
 *
 *   NIX_WINE_FIXED_TIME  seconds since the Unix epoch returned for
 *                        CLOCK_REALTIME (default 0)
 *   NIX_WINE_RNG_SEED    seed for getrandom()/getentropy() (default constant)
 *
 * Wall-clock time is perfectly constant (no ticking counter, so there is
 * nothing for threads to race on); wine needs the patched wineboot from
 * patches/ that tolerates a clock which does not advance. Monotonic/boot
 * clocks are passed through untouched * so timeouts and waits still progress. Random bytes come from a splitmix64 stream seeded with the
 * seed and a hash of the process's command line, so different wine processes
 * do not hand out identical GUIDs. Build-time use only: never preload this
 * into anything that needs real time or real entropy.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static time_t fixed_time(void)
{
    static time_t v = -1;
    if (v < 0) {
        const char *e = getenv("NIX_WINE_FIXED_TIME");
        v = e ? (time_t)atoll(e) : 0;
    }
    return v;
}

int clock_gettime(clockid_t id, struct timespec *ts)
{
    static int (*real)(clockid_t, struct timespec *);
    if (id == CLOCK_REALTIME || id == CLOCK_REALTIME_COARSE) {
        ts->tv_sec = fixed_time();
        ts->tv_nsec = 0;
        return 0;
    }
    if (!real) real = dlsym(RTLD_NEXT, "clock_gettime");
    return real(id, ts);
}

int gettimeofday(struct timeval *restrict tv, void *restrict tz)
{
    (void)tz;
    if (tv) { tv->tv_sec = fixed_time(); tv->tv_usec = 0; }
    return 0;
}

time_t time(time_t *t)
{
    time_t v = fixed_time();
    if (t) *t = v;
    return v;
}

static pthread_mutex_t rng_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t rng_state;
static int rng_ready;

static void rng_init(void)
{
    const char *e = getenv("NIX_WINE_RNG_SEED");
    uint64_t h = 1469598103934665603ULL ^ (e ? strtoull(e, NULL, 0) : 0x6e69782d77696e65ULL);
    int fd = open("/proc/self/cmdline", O_RDONLY);
    if (fd >= 0) {
        char buf[4096];
        ssize_t n = read(fd, buf, sizeof buf);
        for (ssize_t i = 0; i < n; i++) { h ^= (unsigned char)buf[i]; h *= 1099511628211ULL; }
        close(fd);
    }
    rng_state = h;
    rng_ready = 1;
}

static uint64_t rng_next(void)
{
    uint64_t z = (rng_state += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

static void rng_fill(void *buf, size_t len)
{
    unsigned char *p = buf;
    pthread_mutex_lock(&rng_lock);
    if (!rng_ready) rng_init();
    while (len) {
        uint64_t r = rng_next();
        size_t n = len < sizeof r ? len : sizeof r;
        memcpy(p, &r, n);
        p += n; len -= n;
    }
    pthread_mutex_unlock(&rng_lock);
}

ssize_t getrandom(void *buf, size_t len, unsigned int flags)
{
    (void)flags;
    rng_fill(buf, len);
    return (ssize_t)len;
}

int getentropy(void *buf, size_t len)
{
    rng_fill(buf, len);
    return 0;
}
