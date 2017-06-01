/*
 * Copyright 2010-2016, Tarantool AUTHORS, please see AUTHORS file.
 *
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include "bloom.h"
#include <unistd.h>
#include <sys/mman.h>
#include <limits.h>
#include <math.h>
#include <assert.h>
#include <string.h>

int
bloom_create(struct bloom *bloom, uint32_t number_of_values,
	     double false_positive_rate, struct quota *quota)
{
	/* Optimal hash_count and bit count calculation */
	bloom->hash_count = (uint32_t)
		(log(false_positive_rate) / log(0.5) + 0.99);
	/* Number of bits */
	uint64_t m = (uint64_t)
		(number_of_values * bloom->hash_count / log(2) + 0.5);
	/* mmap page size */
	uint64_t page_size = sysconf(_SC_PAGE_SIZE);
	/* Number of bits in one page */
	uint64_t b = page_size * CHAR_BIT;
	/* number of pages, round up */
	uint64_t p = (uint32_t)((m + b - 1) / b);
	/* bit array size in bytes */
	size_t mmap_size = p * page_size;
	bloom->table_size = p * page_size / sizeof(struct bloom_block);
	if (quota_use(quota, mmap_size) < 0) {
		bloom->table = NULL;
		return -1;
	}
	bloom->table = (struct bloom_block *)
		mmap(NULL, mmap_size, PROT_READ | PROT_WRITE,
		     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (bloom->table == MAP_FAILED) {
		bloom->table = NULL;
		quota_release(quota, mmap_size);
		return -1;
	}
	return 0;
}

void
bloom_destroy(struct bloom *bloom, struct quota *quota)
{
	size_t mmap_size = bloom->table_size * sizeof(struct bloom_block);
	munmap(bloom->table, mmap_size);
	quota_release(quota, mmap_size);
}

size_t
bloom_store_size(const struct bloom *bloom)
{
	return bloom->table_size * sizeof(struct bloom_block);
}

char *
bloom_store(const struct bloom *bloom, char *table)
{
	size_t store_size = bloom_store_size(bloom);
	memcpy(table, bloom->table, store_size);
	return table + store_size;
}

int
bloom_load_table(struct bloom *bloom, const char *table, struct quota *quota)
{
	size_t mmap_size = bloom->table_size * sizeof(struct bloom_block);
	if (quota_use(quota, mmap_size) < 0) {
		bloom->table = NULL;
		return -1;
	}
	bloom->table = (struct bloom_block *)
		mmap(NULL, mmap_size, PROT_READ | PROT_WRITE,
		     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (bloom->table == MAP_FAILED) {
		bloom->table = NULL;
		quota_release(quota, mmap_size);
		return -1;
	}
	memcpy(bloom->table, table, mmap_size);
	return 0;
}

void
bloom_spectrum_choose(struct bloom_spectrum *spectrum, struct bloom *bloom)
{
	assert(spectrum->chosen_one < 0);
	spectrum->chosen_one = 0;
	uint32_t number_of_values = spectrum->count_expected;
	for (int i = 1; i < BLOOM_SPECTRUM_SIZE; i++) {
		number_of_values = number_of_values * 4 / 5;
		if (number_of_values < 1)
			number_of_values = 1;
		if (spectrum->count_collected > number_of_values)
			break;
		spectrum->chosen_one = i;
	}
	/* Move the chosen one to result bloom structure */
	*bloom = spectrum->vector[spectrum->chosen_one];
	memset(&spectrum->vector[spectrum->chosen_one], 0,
	       sizeof(spectrum->vector[spectrum->chosen_one]));
}

int
bloom_spectrum_create(struct bloom_spectrum *spectrum,
		      uint32_t max_number_of_values, double false_positive_rate,
		      struct quota *quota)
{
	spectrum->count_expected = max_number_of_values;
	spectrum->count_collected = 0;
	spectrum->chosen_one = -1;
	for (uint32_t i = 0; i < BLOOM_SPECTRUM_SIZE; i++) {
		int rc = bloom_create(&spectrum->vector[i],
				      max_number_of_values,
				      false_positive_rate, quota);
		if (rc) {
			for (uint32_t j = 0; j < i; j++)
				bloom_destroy(&spectrum->vector[i], quota);
			return rc;
		}

		max_number_of_values = max_number_of_values * 4 / 5;
		if (max_number_of_values < 1)
			max_number_of_values = 1;
	}
	return 0;
}

void
bloom_spectrum_destroy(struct bloom_spectrum *spectrum, struct quota *quota)
{
	for (int i = 0; i < BLOOM_SPECTRUM_SIZE; i++) {
		if (i != spectrum->chosen_one)
			bloom_destroy(&spectrum->vector[i], quota);
	}
}

/* }}} API definition */


