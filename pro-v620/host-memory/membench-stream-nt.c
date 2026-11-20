/* STREAM's four kernels with non-temporal stores. membench-kernels.sh appends this file to
 * STREAM 5.10's stream.c in place of its "tuned" stubs and builds it with -DTUNED.
 *
 * An ordinary store first reads the destination line into cache (read-for-ownership), a
 * transfer STREAM does not count. A non-temporal store writes the line to DRAM without
 * reading it, so each kernel moves exactly the bytes STREAM counts. AVX2: four doubles per
 * store; vmovntpd needs 32-byte alignment, which main() is not in a position to check, so
 * every kernel checks it. */
/* stream.c defines abs() as a macro, which breaks stdlib.h's declaration of it, and
 * immintrin.h includes stdlib.h. Nothing in this file uses abs. */
#undef abs
#include <immintrin.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

_Static_assert(STREAM_ARRAY_SIZE % 4 == 0, "STREAM_ARRAY_SIZE must be a multiple of 4");
_Static_assert(OFFSET % 4 == 0, "OFFSET must keep the arrays 32-byte aligned");

static void require_aligned(void)
{
	if (((uintptr_t)a | (uintptr_t)b | (uintptr_t)c) & 31) {
		fprintf(stderr, "arrays are not 32-byte aligned; non-temporal stores would fault\n");
		exit(1);
	}
}

/* Each thread fences its own write-combining buffers before the parallel region's closing
 * barrier, so the timer stops only after the stores are globally visible. */
void tuned_STREAM_Copy()
{
	ssize_t j;
	require_aligned();
#pragma omp parallel
	{
#pragma omp for schedule(static)
		for (j = 0; j < STREAM_ARRAY_SIZE; j += 4)
			_mm256_stream_pd(&c[j], _mm256_load_pd(&a[j]));
		_mm_sfence();
	}
}

void tuned_STREAM_Scale(STREAM_TYPE scalar)
{
	ssize_t j;
	const __m256d s = _mm256_set1_pd(scalar);
#pragma omp parallel
	{
#pragma omp for schedule(static)
		for (j = 0; j < STREAM_ARRAY_SIZE; j += 4)
			_mm256_stream_pd(&b[j], _mm256_mul_pd(s, _mm256_load_pd(&c[j])));
		_mm_sfence();
	}
}

void tuned_STREAM_Add()
{
	ssize_t j;
#pragma omp parallel
	{
#pragma omp for schedule(static)
		for (j = 0; j < STREAM_ARRAY_SIZE; j += 4)
			_mm256_stream_pd(&c[j], _mm256_add_pd(_mm256_load_pd(&a[j]), _mm256_load_pd(&b[j])));
		_mm_sfence();
	}
}

void tuned_STREAM_Triad(STREAM_TYPE scalar)
{
	ssize_t j;
	const __m256d s = _mm256_set1_pd(scalar);
#pragma omp parallel
	{
#pragma omp for schedule(static)
		for (j = 0; j < STREAM_ARRAY_SIZE; j += 4)
			_mm256_stream_pd(&a[j], _mm256_add_pd(_mm256_load_pd(&b[j]),
			                                     _mm256_mul_pd(s, _mm256_load_pd(&c[j]))));
		_mm_sfence();
	}
}
