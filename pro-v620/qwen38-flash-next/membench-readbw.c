/* Read-only memory bandwidth: each thread sums its share of one large array with AVX2 loads
 * into four independent accumulators. Nothing is written during a pass, so there is no
 * read-for-ownership traffic and the bytes counted are the bytes moved. CPU-offloaded decode
 * is this pattern: it streams weights and writes almost nothing.
 *
 * Output follows STREAM's layout (best rate in MB/s, then average, minimum and maximum time)
 * and, like STREAM, drops the first pass. The array is a static, as STREAM's are, so both get
 * the same 4 KiB pages. Built and run by membench-kernels.sh. */
#include <immintrin.h>
#include <omp.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef READ_ARRAY_SIZE
#define READ_ARRAY_SIZE 2000000000L
#endif
#ifndef NTIMES
#define NTIMES 20
#endif
_Static_assert(READ_ARRAY_SIZE % 16 == 0, "READ_ARRAY_SIZE must be a multiple of 16");
_Static_assert(NTIMES >= 2, "NTIMES must be at least 2");

static double x[READ_ARRAY_SIZE] __attribute__((aligned(64)));

static double read_pass(void)
{
	double sum = 0;
#pragma omp parallel reduction(+:sum)
	{
		__m256d s0 = _mm256_setzero_pd(), s1 = s0, s2 = s0, s3 = s0;
		double v[4];
#pragma omp for schedule(static) nowait
		for (long j = 0; j < READ_ARRAY_SIZE; j += 16) {
			s0 = _mm256_add_pd(s0, _mm256_load_pd(&x[j]));
			s1 = _mm256_add_pd(s1, _mm256_load_pd(&x[j + 4]));
			s2 = _mm256_add_pd(s2, _mm256_load_pd(&x[j + 8]));
			s3 = _mm256_add_pd(s3, _mm256_load_pd(&x[j + 12]));
		}
		_mm256_storeu_pd(v, _mm256_add_pd(_mm256_add_pd(s0, s1), _mm256_add_pd(s2, s3)));
		sum += v[0] + v[1] + v[2] + v[3];
	}
	return sum;
}

int main(void)
{
	const double bytes = (double)READ_ARRAY_SIZE * sizeof(double);
	double tmin = 1e30, tmax = 0, tsum = 0;
	int ok = 1;

	/* First touch with the schedule the passes use, so under NPS2/NPS4 each page sits on the
	 * node of the thread that reads it. Under NPS1 there is one node. */
#pragma omp parallel for schedule(static)
	for (long j = 0; j < READ_ARRAY_SIZE; j += 16)
		for (int k = 0; k < 16; k++)
			x[j + k] = 1.0;

	printf("Threads: %d, array %ld doubles (%.1f GB), %d passes, first dropped\n",
	       omp_get_max_threads(), (long)READ_ARRAY_SIZE, bytes / 1e9, NTIMES);
	for (int k = 0; k < NTIMES; k++) {
		double t = omp_get_wtime();
		double sum = read_pass();
		t = omp_get_wtime() - t;
		/* Sums of 1.0 are exact below 2^53, so any other value is a lost or doubled load. */
		if (sum != (double)READ_ARRAY_SIZE)
			ok = 0;
		if (k == 0)
			continue;
		tsum += t;
		if (t < tmin) tmin = t;
		if (t > tmax) tmax = t;
	}
	printf("Function    Best Rate MB/s  Avg time     Min time     Max time\n");
	printf("Read:       %12.1f  %11.6f  %11.6f  %11.6f\n",
	       1e-6 * bytes / tmin, tsum / (NTIMES - 1), tmin, tmax);
	printf(ok ? "Solution Validates\n" : "Failed Validation: a pass summed to the wrong value\n");
	return ok ? 0 : 1;
}
