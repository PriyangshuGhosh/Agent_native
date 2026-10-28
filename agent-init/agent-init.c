/* agent-init: PID 1 of CUA-AgentOS. Deterministic: no network, no LLM, no inference.
 * Mounts the VFS, reaps every child, proves reaping works, reports PID1_READY on ttyS0, then waits.
 * SIGTERM/SIGINT (Ctrl-Alt-Del) or the agent.test_poweroff cmdline flag -> sync + RB_POWER_OFF. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t reaped, last_reaped, stop;

static void on_sigchld(int sig)
{
	int saved = errno, st;
	pid_t p;

	(void)sig;
	while ((p = waitpid(-1, &st, WNOHANG)) > 0) {
		reaped++;
		last_reaped = p;
	}
	errno = saved;
}

static void on_stop(int sig)
{
	(void)sig;
	stop = 1;
}

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_BOOTTIME, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000;
}

static const struct {
	const char *src, *dir, *type;
	unsigned long flags;
} vfs[] = {
	{ "proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC },
	{ "sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC },
	{ "devtmpfs", "/dev", "devtmpfs", MS_NOSUID },
	{ "devpts", "/dev/pts", "devpts", MS_NOSUID | MS_NOEXEC },
	{ "tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV },
	{ "tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV },
};
#define NVFS (sizeof(vfs) / sizeof(vfs[0]))

static void mount_vfs(void)
{
	size_t i;

	for (i = 0; i < NVFS; i++) {
		mkdir(vfs[i].dir, 0755);
		/* Failure is not fatal here: PID1_READY reports what /proc/self/mounts really shows. */
		mount(vfs[i].src, vfs[i].dir, vfs[i].type, vfs[i].flags, NULL);
	}
}

/* Appends {"dir":"fstype",...} for our targets, as the kernel sees them. */
static int mounts_json(char *buf, size_t len)
{
	char found[NVFS][32] = { { 0 } }, src[256], dir[256], type[32];
	size_t i;
	int n = 0;
	FILE *f = fopen("/proc/self/mounts", "r");

	if (f) {
		while (fscanf(f, "%255s %255s %31s %*[^\n]", src, dir, type) == 3)
			for (i = 0; i < NVFS; i++)
				if (!strcmp(dir, vfs[i].dir))
					snprintf(found[i], sizeof(found[i]), "%s", type);
		fclose(f);
	}
	n += snprintf(buf + n, len - n, "{");
	for (i = 0; i < NVFS; i++)
		if (found[i][0])
			n += snprintf(buf + n, len - n, "%s\"%s\":\"%s\"", n > 1 ? "," : "", vfs[i].dir, found[i]);
	n += snprintf(buf + n, len - n, "}");
	return n;
}

/* Counts zombies and userspace processes (kernel threads have an empty cmdline). */
static void scan_procs(int *zombies, int *user)
{
	char path[300], stat[512], *p;
	struct dirent *d;
	DIR *dir = opendir("/proc");
	int fd;
	ssize_t n;

	*zombies = *user = 0;
	if (!dir)
		return;
	while ((d = readdir(dir))) {
		if (d->d_name[0] < '1' || d->d_name[0] > '9')
			continue;
		snprintf(path, sizeof(path), "/proc/%s/stat", d->d_name);
		if ((fd = open(path, O_RDONLY)) < 0)
			continue;
		n = read(fd, stat, sizeof(stat) - 1);
		close(fd);
		if (n <= 0)
			continue;
		stat[n] = 0;
		if ((p = strrchr(stat, ')')) && p[1] == ' ' && p[2] == 'Z')
			(*zombies)++;
		snprintf(path, sizeof(path), "/proc/%s/cmdline", d->d_name);
		if ((fd = open(path, O_RDONLY)) < 0)
			continue;
		if (read(fd, stat, 1) == 1)
			(*user)++;
		close(fd);
	}
	closedir(dir);
}

/* Forks a child that exits at once; true if the SIGCHLD handler reaped it and no /proc entry remains. */
static int reap_test(pid_t *child)
{
	sigset_t chld, old;
	sig_atomic_t before = reaped;
	char path[32];

	sigemptyset(&chld);
	sigaddset(&chld, SIGCHLD);
	sigprocmask(SIG_BLOCK, &chld, &old);
	*child = fork();
	if (*child == 0)
		_exit(0);
	while (*child > 0 && reaped == before)
		sigsuspend(&old);
	sigprocmask(SIG_SETMASK, &old, NULL);
	snprintf(path, sizeof(path), "/proc/%d", (int)*child);
	return *child > 0 && last_reaped == *child && access(path, F_OK) != 0;
}

static void read_trim(const char *path, char *buf, size_t len)
{
	int fd = open(path, O_RDONLY);
	ssize_t n = fd < 0 ? 0 : read(fd, buf, len - 1);

	if (fd >= 0)
		close(fd);
	buf[n > 0 ? n : 0] = 0;
	buf[strcspn(buf, "\n")] = 0;
}

int main(void)
{
	struct sigaction sa;
	sigset_t mask, empty;
	char comm[32], cmdline[1024], mounts[512], line[1024];
	int tty, zombies, user, ok, n;
	pid_t child;

	if (getpid() != 1)
		return 1;
	reboot(RB_DISABLE_CAD); /* Ctrl-Alt-Del becomes SIGINT to us */

	memset(&sa, 0, sizeof(sa));
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
	sa.sa_handler = on_sigchld;
	sigaction(SIGCHLD, &sa, NULL);
	sa.sa_flags = 0;
	sa.sa_handler = on_stop;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	mount_vfs();
	tty = open("/dev/ttyS0", O_WRONLY | O_NOCTTY | O_CLOEXEC);
	/* Firmware leaves an unterminated line on ttyS0; start ours on a fresh one. */
	if (tty >= 0 && write(tty, "\n", 1) < 0) {
		/* no other channel to report on */
	}

	ok = reap_test(&child);
	scan_procs(&zombies, &user);
	read_trim("/proc/1/comm", comm, sizeof(comm));
	read_trim("/proc/cmdline", cmdline, sizeof(cmdline));
	mounts_json(mounts, sizeof(mounts));

	n = snprintf(line, sizeof(line),
		     "{\"ts_ms\":%ld,\"event\":\"PID1_READY\",\"pid\":%d,\"comm\":\"%s\",\"mounts\":%s,"
		     "\"reap_test\":{\"pid\":%d,\"reaped\":%s},\"zombies\":%d,\"user_procs\":%d}\n",
		     now_ms(), (int)getpid(), comm, mounts, (int)child, ok ? "true" : "false", zombies, user);
	if (tty >= 0 && n > 0 && write(tty, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1) < 0) {
		/* no other channel to report on */
	}

	if (strstr(cmdline, "agent.test_poweroff"))
		stop = 1;

	sigemptyset(&mask);
	sigaddset(&mask, SIGTERM);
	sigaddset(&mask, SIGINT);
	sigprocmask(SIG_BLOCK, &mask, NULL);
	sigemptyset(&empty);
	while (!stop)
		sigsuspend(&empty); /* SIGCHLD reaping keeps running in here */

	sync();
	reboot(RB_POWER_OFF);
	for (;;) /* PID 1 must never return */
		pause();
}
