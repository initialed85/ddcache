/* ddcache spike binary: runs every generated unit and prints a digest. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ddcheck.h"

static const double table[97] = {
    1.5, 2.25, 3.125, 4.0625, 5.03125, 6.015625, 7.0078125, 8.5,
    9.25, 10.125, 11.0625, 12.03125, 13.015625, 14.0078125, 15.5, 16.25,
    17.125, 18.0625, 19.03125, 20.015625, 21.0078125, 22.5, 23.25, 24.125,
    25.0625, 26.03125, 27.015625, 28.0078125, 29.5, 30.25, 31.125, 32.0625,
    33.03125, 34.015625, 35.0078125, 36.5, 37.25, 38.125, 39.0625, 40.03125,
    41.015625, 42.0078125, 43.5, 44.25, 45.125, 46.0625, 47.03125, 48.015625,
    49.0078125, 50.5, 51.25, 52.125, 53.0625, 54.03125, 55.015625, 56.0078125,
    57.5, 58.25, 59.125, 60.0625, 61.03125, 62.015625, 63.0078125, 64.5,
    65.25, 66.125, 67.0625, 68.03125, 69.015625, 70.0078125, 71.5, 72.25,
    73.125, 74.0625, 75.03125, 76.015625, 77.0078125, 78.5, 79.25, 80.125,
    81.0625, 82.03125, 83.015625, 84.0078125, 85.5, 86.25, 87.125, 88.0625,
    89.03125, 90.015625, 91.0078125, 92.5, 93.25, 94.125, 95.0625, 96.03125,
    97.015625,
};

int main(int argc, char **argv) {
    long iters = argc > 1 ? atol(argv[1]) : 20000;
    unsigned long long digest = 1469598103934665603ULL;

    for (int u = 0; u < DDCHECK_NUNITS; u++) {
        for (int f = 0; f < DDCHECK_NFUNCS; f++) {
            double v = mu_tables[u][f](table, (int)iters);
            unsigned long long bits;
            memcpy(&bits, &v, sizeof bits);
            digest = (digest ^ bits) * 1099511628211ULL;
        }
    }

    printf("ddcheck %016llx (%d units x %d funcs, %ld iters)\n",
           digest, DDCHECK_NUNITS, DDCHECK_NFUNCS, iters);
    return 0;
}
