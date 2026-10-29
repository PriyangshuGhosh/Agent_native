/* agent-init: PID 1 of CUA-AgentOS. Deterministic: no network, no LLM, no inference.
 * Mounts the VFS, reaps every child, proves reaping works, reports PID1_READY and STORAGE_READY on ttyS0, then starts and
 * supervises the session services in order. The final workload (agentd; FINAL_CMD) exiting, SIGTERM/SIGINT (Ctrl-Alt-Del) or the
 * agent.test_poweroff cmdline flag -> SIGTERM everyone, sync, RB_POWER_OFF (agent.hold: stop there, no power-off). */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define RUNTIME "/run/user/0"
#ifndef FINAL_CMD /* build-rootfs-03.sh overrides it with the Cycle 01 probe */
#define FINAL_CMD "/usr/bin/agentd"
#endif

enum { SERVICE, ONESHOT, FINAL }; /* SERVICE is restarted on exit; ONESHOT runs to completion; FINAL's exit powers off */

static struct svc {
	const char *argv[6];
	const char *ready; /* exists once the service is usable; started services wait for it */
	int kind, restarts;
	pid_t pid;
} svcs[] = {
	{ { "/etc/agent-init/prep", NULL }, NULL, ONESHOT, 0, 0 },
	{ { "/usr/bin/dbus-daemon", "--session", "--nofork", "--nopidfile", "--address=unix:path=" RUNTIME "/bus", NULL },
	  RUNTIME "/bus", SERVICE, 0, 0 },
	{ { "/usr/libexec/at-spi-bus-launcher", "--launch-immediately", NULL }, NULL, SERVICE, 0, 0 },
	{ { "/usr/bin/cage", "--", "mousepad", NULL }, RUNTIME "/wayland-0", SERVICE, 0, 0 },
	{ { FINAL_CMD, NULL }, NULL, FINAL, 0, 0 },
};
#define NSVC (sizeof(svcs) / sizeof(svcs[0]))

static char *session_env[] = {
	"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/root", "LANG=C.UTF-8",
	"XDG_RUNTIME_DIR=" RUNTIME, "WAYLAND_DISPLAY=wayland-0", "DBUS_SESSION_BUS_ADDRESS=unix:path=" RUNTIME "/bus",
	/* App state is per-boot scratch (tmpfs): with a persistent upper, mousepad would otherwise restore last boot's session */
	"XDG_CONFIG_HOME=" RUNTIME "/config", "XDG_DATA_HOME=" RUNTIME "/data", "XDG_CACHE_HOME=" RUNTIME "/cache",
	"XDG_STATE_HOME=" RUNTIME "/state",
	/* cage: headless output plus libinput so uinput devices reach it; no seat manager, no GPU */
	"WLR_BACKENDS=headless,libinput", "LIBSEAT_BACKEND=noop", "WLR_RENDERER=pixman", "WLR_LIBINPUT_NO_DEVICES=1",
	"GDK_BACKEND=wayland",
};

static volatile sig_atomic_t got_chld, stop;
static int reaped, hold, tty = -1, logfd = -1, nullfd = -1;
static pid_t last_reaped;

static void on_sigchld(int sig)
{
	(void)sig;
	got_chld = 1;
}

static void spawn(struct svc *s)
{
	sigset_t none;

	s->pid = fork();
	if (s->pid == 0) {
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		setsid();
		dup2(nullfd, 0);
		dup2(logfd, 1);
		dup2(logfd, 2);
		execv(s->argv[0], (char *const *)s->argv);
		_exit(127);
	}
	if (s->pid < 0)
		s->pid = 0;
}

/* Reaps every exited child (orphans included). Returns 1 once the FINAL service has exited. */
static int reap(void)
{
	int st, done = 0;
	size_t i;
	pid_t p;

	got_chld = 0;
	while ((p = waitpid(-1, &st, WNOHANG)) > 0) {
		reaped++;
		last_reaped = p;
		for (i = 0; i < NSVC; i++) {
			if (svcs[i].pid != p)
				continue;
			svcs[i].pid = 0;
			if (svcs[i].kind == FINAL) {
				dprintf(tty, "# agent-init: %s exited %d\n", svcs[i].argv[0], WIFEXITED(st) ? WEXITSTATUS(st) : -1);
				done = 1;
			}
			else if (svcs[i].kind == SERVICE && !stop && svcs[i].restarts++ < 3) {
				dprintf(tty, "# agent-init: restarting %s\n", svcs[i].argv[0]); /* non-JSON: gates ignore it */
				spawn(&svcs[i]);
			}
		}
	}
	return done;
}

/* Polls up to 10 s for a ONESHOT to finish or a ready path to appear; on timeout boot goes on and the probe reports.
 * SIGTERM/SIGINT stay blocked here, so a pending one is picked up by hand: shutdown must not wait out the boot. */
static void wait_ready(const struct svc *s)
{
	struct timespec tick = { 0, 10000000 };
	sigset_t pend;
	int i;

	for (i = 0; i < 1000 && !stop; i++) {
		reap();
		sigpending(&pend);
		if (sigismember(&pend, SIGTERM) || sigismember(&pend, SIGINT))
			stop = 1;
		if (s->kind == ONESHOT ? s->pid == 0 : !s->ready || access(s->ready, F_OK) == 0)
			return;
		nanosleep(&tick, NULL);
	}
}

static void start_services(void)
{
	size_t i;

	mkdir("/run/user", 0755);
	mkdir(RUNTIME, 0700);
	mkdir("/run/dbus", 0755);
	for (i = 0; i < sizeof(session_env) / sizeof(session_env[0]); i++)
		putenv(session_env[i]);
	nullfd = open("/dev/null", O_RDWR | O_CLOEXEC);
	logfd = open("/tmp/harness.log", O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
	for (i = 0; i < NSVC && !stop; i++) {
		spawn(&svcs[i]);
		if (svcs[i].kind == FINAL && !svcs[i].pid) {
			dprintf(tty, "# agent-init: cannot fork %s\n", svcs[i].argv[0]);
			stop = 1; /* nothing would ever exit and power us off */
		}
		wait_ready(&svcs[i]);
	}
}

/* SIGTERM everyone, give them 2 s, SIGKILL the rest, reap all, remount read-only, then power off. */
static void shutdown_all(void)
{
	struct timespec tick = { 0, 10000000 };
	int i;

	kill(-1, SIGTERM);
	for (i = 0; i < 200 && waitpid(-1, NULL, WNOHANG) >= 0; i++)
		nanosleep(&tick, NULL);
	kill(-1, SIGKILL);
	while (waitpid(-1, NULL, 0) > 0)
		;
	sync();
	/* A persistent ext4 upper must be left clean (no journal to replay); failures change nothing, data is synced. */
	mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY, NULL);
	mount(NULL, "/mnt/rw", NULL, MS_REMOUNT | MS_RDONLY, NULL);
	sync();
	if (hold) /* agent.hold: keep the last screen (HDMI console) instead of powering off */
		dprintf(tty, "# agent-init: run finished, holding (agent.hold); safe to unplug\n");
	else
		reboot(RB_POWER_OFF);
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

/* The initramfs leaves the SquashFS base at /mnt/base and the upper/work at /mnt/rw (tmpfs, or ext4 when the persistent
 * agentos-data disk is attached), under an overlay root. base_ro needs the kernel to list the base ro AND a write into it
 * to fail with EROFS. */
static int storage_json(char *buf, size_t len)
{
	char src[256], dir[256], type[32], opts[256], root[32] = "", base[32] = "", upper[32] = "";
	int base_ro = 0, fd;
	FILE *f = fopen("/proc/self/mounts", "r");

	if (f) {
		while (fscanf(f, "%255s %255s %31s %255s %*[^\n]", src, dir, type, opts) == 4) {
			if (!strcmp(dir, "/"))
				snprintf(root, sizeof(root), "%s", type);
			else if (!strcmp(dir, "/mnt/base")) {
				snprintf(base, sizeof(base), "%s", type);
				base_ro = !strncmp(opts, "ro", 2) && (opts[2] == ',' || !opts[2]);
			}
			else if (!strcmp(dir, "/mnt/rw"))
				snprintf(upper, sizeof(upper), "%s", type);
		}
		fclose(f);
	}
	fd = open("/mnt/base/.agent-init-probe", O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
	base_ro = base_ro && fd < 0 && errno == EROFS && !strcmp(base, "squashfs");
	if (fd >= 0)
		close(fd);
	return snprintf(buf, len,
			"{\"ts_ms\":%ld,\"event\":\"STORAGE_READY\",\"base_ro\":%s,\"overlay\":%s,\"persistent\":%s,"
			"\"root\":\"%s\",\"base\":\"%s\",\"upper\":\"%s\"}\n",
			now_ms(), base_ro ? "true" : "false",
			!strcmp(root, "overlay") && (!strcmp(upper, "tmpfs") || !strcmp(upper, "ext4")) ? "true" : "false",
			!strcmp(upper, "ext4") ? "true" : "false", root, base, upper);
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

/* Forks a child that exits at once; true if SIGCHLD-driven reaping collected it and no /proc entry remains.
 * Caller has SIGCHLD blocked; sigsuspend opens it atomically, so the wakeup cannot be lost. */
static int reap_test(pid_t *child, const sigset_t *open_mask)
{
	int before = reaped;
	char path[32];

	*child = fork();
	if (*child == 0)
		_exit(0);
	while (*child > 0 && reaped == before) {
		sigsuspend(open_mask);
		reap();
	}
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
	char comm[32], cmdline[2048], mounts[512], line[3072], *p;
	int zombies, user, ok, n;
	pid_t child;

	if (getpid() != 1)
		return 1;
	/* ISO boot: the kernel hands off to us in the initramfs (rdinit=); /stage1 mounts the real root and
	 * switch_roots back into /usr/bin/agent-init there, still as PID 1. The real root has no /stage1. */
	if (access("/stage1", X_OK) == 0)
		execl("/stage1", "/stage1", (char *)NULL);
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
	/* Signals are only taken inside sigsuspend, so the main loop never misses one between checks. */
	sigemptyset(&mask);
	sigaddset(&mask, SIGCHLD);
	sigaddset(&mask, SIGTERM);
	sigaddset(&mask, SIGINT);
	sigprocmask(SIG_BLOCK, &mask, NULL);
	sigemptyset(&empty);

	mount_vfs();
	/* AGENT_TTY=<dev|file> on the kernel cmdline reaches us (and agentd) as env; append so a log file shared with agentd
	 * keeps both writers' lines. The Pi 5 SD image logs to its FAT partition. */
	tty = open(getenv("AGENT_TTY") ? getenv("AGENT_TTY") : "/dev/ttyS0", O_WRONLY | O_APPEND | O_NOCTTY | O_CLOEXEC);
	/* Firmware leaves an unterminated line on ttyS0; start ours on a fresh one. */
	if (tty >= 0 && write(tty, "\n", 1) < 0) {
		/* no other channel to report on */
	}

	ok = reap_test(&child, &empty);
	scan_procs(&zombies, &user);
	read_trim("/proc/1/comm", comm, sizeof(comm));
	read_trim("/proc/cmdline", cmdline, sizeof(cmdline));
	for (p = cmdline; *p; p++) /* keep it a valid JSON string */
		if (*p == '"' || *p == '\\' || (unsigned char)*p < 0x20)
			*p = '?';
	mounts_json(mounts, sizeof(mounts));

	n = snprintf(line, sizeof(line),
		     "{\"ts_ms\":%ld,\"event\":\"PID1_READY\",\"pid\":%d,\"comm\":\"%s\",\"mounts\":%s,"
		     "\"reap_test\":{\"pid\":%d,\"reaped\":%s},\"zombies\":%d,\"user_procs\":%d,\"cmdline\":\"%s\"}\n",
		     now_ms(), (int)getpid(), comm, mounts, (int)child, ok ? "true" : "false", zombies, user, cmdline);
	if (tty >= 0 && n > 0 && write(tty, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1) < 0) {
		/* no other channel to report on */
	}
	n = storage_json(line, sizeof(line));
	if (tty >= 0 && n > 0 && write(tty, line, (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1) < 0) {
		/* no other channel to report on */
	}

	hold = strstr(cmdline, "agent.hold") != NULL;
	if (strstr(cmdline, "agent.test_poweroff"))
		stop = 1;
	else
		start_services();

	while (!stop && !reap())
		sigsuspend(&empty);

	shutdown_all();
	for (;;) /* PID 1 must never return */
		pause();
}
