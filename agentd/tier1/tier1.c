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
