/* Tier 1 test capability for agentd: pure compute, no libc, so it loads under any libc. */
unsigned long long tier1_fib(unsigned n)
{
	unsigned long long a = 0, b = 1, t;

	while (n--) {
		t = a + b;
		a = b;
		b = t;
	}
	return a;
}

/* Cycle 05 workflow validation step: FNV-1a 32-bit over a byte buffer. */
unsigned tier1_fnv1a(const unsigned char *p, unsigned long n)
{
	unsigned h = 2166136261u;

	while (n--)
		h = (h ^ *p++) * 16777619u;
	return h;
}
