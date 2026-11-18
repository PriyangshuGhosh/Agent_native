//! agentd-broker: the only part of agentd's stack that may change the system (agentd/debian/agentd-broker.service).
//! agentd proposes typed operations on one socket; a person answers approvals on another, which agentd cannot open.
//! The policy is compiled in, so nothing the model says can rewrite it. Contract: tests/test-debian-vm.sh.
#[path = "../txn.rs"]
mod txn;
use serde_json::{Value, json};
use std::path::Path;
use txn::{Journal, end_txn, recover, rollback, snapshot, staged_put};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const AUDIT: &str = "/var/log/agentd-broker/audit.jsonl";
/// StateDirectory=agentd-broker. The write-ahead journal of the open transaction lives here, so a crash or a power
/// cut mid-change is undone at the next start (--recover runs that before anything else at boot).
const TXN: &str = "/var/lib/agentd-broker/txn";
/// The one file config.set_ntp owns: ReadWritePaths in the unit makes its directory, and only it, writable.
const NTP_CONF: &str = "/etc/systemd/timesyncd.conf.d/50-agentd-ntp.conf";
const TIMESYNCD: &str = "systemd-timesyncd.service";
const SYSTEMCTL: &str = "/usr/bin/systemctl";
const TIMEDATECTL: &str = "/usr/bin/timedatectl";
/// Compiled in like UNITS: the model picks from this list or the request is rejected.
static NTP_SERVERS: [&str; 4] = ["time.cloudflare.com", "time.google.com", "pool.ntp.org", "in.pool.ntp.org"];
const AUDIT_MAX_BYTES: u64 = 5_000_000;
const MAX_REQUEST: usize = 4096;
const READ_TIMEOUT: Duration = Duration::from_secs(5);
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(60);
const RESTART_TIMEOUT: Duration = Duration::from_secs(30);
const SHOW_TIMEOUT: Duration = Duration::from_secs(5);
const RESTART_WINDOW: Duration = Duration::from_secs(600);
const RESTARTS_PER_WINDOW: usize = 3;

struct Unit {
    name: &'static str,
    /// What the person is asked, written here so that the model cannot word it. None = runs automatically.
    approval: Option<&'static str>,
}

/// The whole policy. Anything absent is rejected, including the agent, its broker, the screen and the debug link.
static UNITS: [Unit; 3] = [
    Unit { name: "cron.service", approval: None },
    Unit { name: "systemd-timesyncd.service", approval: None },
    Unit {
        name: "NetworkManager.service",
        approval: Some("Restart NetworkManager. Wi-Fi and other network connections will drop for a few seconds."),
    },
];

#[derive(Clone, Copy, PartialEq, Debug)]
enum Op {
    Status,
    Restart,
    /// Point systemd-timesyncd at one of NTP_SERVERS: the only operation that changes a file.
    SetNtp,
    /// Install one Debian package through the oneshot unit agentd-pkg@<name>.service (apt-get, as root, with
    /// network), after the person says yes on the console. The person's choice (2026-11-14): software arrives
    /// without a new image; they review what was installed afterwards.
    Install,
}

/// Stands in for the unit of an install (the rate limit and the audit name it).
static PKG_UNIT: Unit = Unit { name: "agentd-pkg@.service", approval: None };
const INSTALL_TIMEOUT: Duration = Duration::from_secs(900);

struct Req {
    op: Op,
    unit: &'static Unit,
    /// The allowlisted server for SetNtp: a &'static str, so no byte of the request is ever written or run.
    value: Option<&'static str>,
    /// The package for Install: the one request byte sequence that reaches a command line, checked by `package_name`.
    pkg: Option<String>,
    task_id: String,
    step: u64,
}

/// A Debian package name as apt accepts it, restricted to what a systemd instance name can carry unescaped.
/// shortcut: names with '+' (g++) are refused; add systemd-escape when one is wanted.
fn package_name(s: &str) -> bool {
    (2..=64).contains(&s.len()) && s.as_bytes()[0].is_ascii_lowercase() && !s.contains("..")
        && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-')
}

impl Req {
    /// A restart of a unit that says so, and every install: SetNtp is reversible, verified, and limited to the list.
    fn approval(&self) -> Option<String> {
        match self.op {
            Op::Restart => self.unit.approval.map(String::from),
            Op::Install => Some(format!("Install the Debian package \"{}\" (apt-get, as root, from the Debian archive). It stays on this system until it is removed.", self.pkg.as_deref().unwrap_or("?"))),
            _ => None,
        }
    }
    fn detail(&self) -> Value {
        json!({"op": format!("{:?}", self.op), "unit": self.unit.name, "value": self.value, "package": self.pkg,
               "task_id": self.task_id, "step": self.step})
    }
}

/// Exactly these fields of exactly these types, naming an operation, a unit from the table and (for set_ntp) a
/// server from the list.
fn parse(line: &str) -> Result<Req, String> {
    let v: Value = serde_json::from_str(line).map_err(|_| "not valid JSON")?;
    let o = v.as_object().ok_or("not a JSON object")?;
    let op = match o.get("op").and_then(Value::as_str) {
        Some("service.status") => Op::Status,
        Some("service.restart") => Op::Restart,
        Some("config.set_ntp") => Op::SetNtp,
        Some("pkg.install") => Op::Install,
        _ => return Err("unknown operation".into()),
    };
    let fields: &[&str] = match op {
        Op::SetNtp => &["op", "unit", "task_id", "step", "value"],
        _ => &["op", "unit", "task_id", "step"],
    };
    if o.len() != fields.len() || !fields.iter().all(|k| o.contains_key(*k)) {
        return Err(format!("fields must be exactly {}", fields.join(", ")));
    }
    let name = o["unit"].as_str().ok_or("unit is not a string")?;
    // For an install, "unit" (agentd's first argument) carries the package name.
    let (unit, pkg) = match op {
        Op::Install if package_name(name) => (&PKG_UNIT, Some(name.to_string())),
        Op::Install => return Err("that is not a Debian package name".into()),
        _ => (UNITS.iter().find(|u| u.name == name).ok_or("unit is not on the allowlist")?, None),
    };
    let value = match op {
        Op::SetNtp if unit.name != TIMESYNCD => return Err(format!("config.set_ntp applies to {TIMESYNCD}")),
        Op::SetNtp => Some(*NTP_SERVERS.iter().find(|s| Some(**s) == o["value"].as_str())
            .ok_or("that time server is not on the allowlist")?),
        _ => None,
    };
    let task_id = o["task_id"].as_str().ok_or("task_id is not a string")?;
    if task_id.is_empty() || task_id.len() > 64 || !task_id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b)) {
        return Err("bad task_id".into());
    }
    let step = o["step"].as_u64().ok_or("step is not a number")?;
    Ok(Req { op, unit, value, pkg, task_id: task_id.to_string(), step })
}

/// Forgets restarts older than the window; true if another would exceed the limit.
fn over_limit(done: &mut Vec<Instant>, now: Instant) -> bool {
    done.retain(|t| now.duration_since(*t) < RESTART_WINDOW);
    done.len() >= RESTARTS_PER_WINDOW
}

fn boottime_ms() -> i64 {
    let mut t = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut t) };
    t.tv_sec as i64 * 1000 + t.tv_nsec as i64 / 1_000_000
}

/// Appended and flushed to disk, then copied to the journal. Before an action, a failure here stops the action.
fn audit(phase: &str, peer: u32, detail: Value) -> std::io::Result<()> {
    let unix_s = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let line = format!(r#"{{"ts_ms":{},"unix_s":{unix_s},"event":"BROKER_AUDIT","phase":"{phase}","peer_uid":{peer},"detail":{detail}}}"#, boottime_ms());
    println!("{line}");
    // Rejected requests cost no restart budget, so a looping client must not be able to fill the disk.
    if fs::metadata(AUDIT).is_ok_and(|m| m.len() > AUDIT_MAX_BYTES) {
        fs::rename(AUDIT, format!("{AUDIT}.1"))?;
    }
    let mut f = OpenOptions::new().append(true).create(true).mode(0o640).open(AUDIT)?;
    f.write_all(format!("{line}\n").as_bytes())?;
    f.sync_data()
}

fn peer_uid(c: &UnixStream) -> u32 {
    let mut cred = libc::ucred { pid: 0, uid: u32::MAX, gid: 0 };
    let mut len = size_of::<libc::ucred>() as libc::socklen_t;
    unsafe { libc::getsockopt(c.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, (&raw mut cred).cast(), &mut len) };
    cred.uid
}

/// The client hung up, which is how agentd's emergency stop cancels what has not started.
fn gone(c: &UnixStream) -> bool {
    let mut p = libc::pollfd { fd: c.as_raw_fd(), events: libc::POLLRDHUP, revents: 0 };
    unsafe { libc::poll(&mut p, 1, 0) > 0 && p.revents & (libc::POLLRDHUP | libc::POLLHUP | libc::POLLERR) != 0 }
}

fn reply(mut c: &UnixStream, v: &Value) {
    let _ = writeln!(c, "{v}");
}

/// Fixed binaries, empty environment, bounded time. Every argument comes from this file, never from a request.
fn run(argv: &[&str], limit: Duration) -> Result<String, String> {
    // The command name alone: these messages are read by a person on the screen.
    let what = format!("{} {}", argv[0].rsplit('/').next().unwrap_or_default(), argv[1]);
    let mut child = Command::new(argv[0]).args(&argv[1..]).env_clear().stdin(Stdio::null()).stdout(Stdio::piped())
        .stderr(Stdio::null()).spawn().map_err(|e| format!("cannot run {what}: {e}"))?;
    let end = Instant::now() + limit;
    loop {
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(s) if s.success() => {
                let mut out = String::new();
                child.stdout.take().ok_or("no output")?.read_to_string(&mut out).map_err(|e| e.to_string())?;
                return Ok(out);
            }
            Some(s) => return Err(format!("{what} failed: {s}")),
            None if Instant::now() >= end => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("{what} timed out"));
            }
            None => sleep(Duration::from_millis(20)),
        }
    }
}

fn show(unit: &str) -> Result<HashMap<String, String>, String> {
    let out = run(&[SYSTEMCTL, "show", "--property=LoadState,ActiveState,SubState,ActiveEnterTimestampMonotonic", "--", unit], SHOW_TIMEOUT)?;
    Ok(out.lines().filter_map(|l| l.split_once('=')).map(|(k, v)| (k.to_string(), v.to_string())).collect())
}

fn field<'a>(m: &'a HashMap<String, String>, k: &str) -> &'a str {
    m.get(k).map_or("", String::as_str)
}

fn stamp(m: &HashMap<String, String>) -> u64 {
    field(m, "ActiveEnterTimestampMonotonic").parse().unwrap_or(0)
}

/// What systemd-timesyncd itself says it loaded, which is how a config change is confirmed: the file we wrote is
/// not evidence that the daemon read it.
fn loaded_ntp() -> Result<String, String> {
    let out = run(&[TIMEDATECTL, "show-timesync", "--property=SystemNTPServers", "--value"], SHOW_TIMEOUT)?;
    Ok(out.trim().to_string())
}

/// Rolls back a transaction a crash or power cut left open. Returns Err only if the state is still uncertain.
fn recover_open_txn(peer: u32) -> Result<(), String> {
    match recover(Path::new(TXN)) {
        Ok(None) => Ok(()),
        Ok(Some((_, j))) => {
            let paths: Vec<String> = j.iter().map(|(p, _)| p.display().to_string()).collect();
            let restored = j.iter().all(|(p, prior)| snapshot(p) == *prior);
            let _ = audit("recovered", peer, json!({"paths": paths, "restored": restored}));
            // The restored file may differ from what a running daemon loaded; if it is not running, this does nothing.
            let _ = run(&[SYSTEMCTL, "try-restart", "--no-ask-password", "--", TIMESYNCD], RESTART_TIMEOUT);
            if restored { Ok(()) } else { Err("a previous change could not be undone".into()) }
        }
        Err(e) => {
            let _ = audit("recovery_failed", peer, json!({"reason": e.to_string()}));
            Err(format!("an interrupted change could not be undone: {e}"))
        }
    }
}

/// Writes the one drop-in this broker owns as a journalled transaction, restarts systemd-timesyncd and checks what
/// the daemon loaded. Anything short of that is rolled back to the previous bytes and mode, and reported as such.
fn set_ntp(server: &str, peer: u32) -> Result<String, String> {
    recover_open_txn(peer)?;
    let txn = Path::new(TXN);
    let body = format!("# Written by agentd-broker (config.set_ntp). Delete this file for the default servers.\n[Time]\nNTP={server}\n");
    let mut j: Journal = Vec::new();
    let done = (|| -> Result<String, String> {
        staged_put(&mut j, txn, Path::new(NTP_CONF), body.as_bytes(), 0o644).map_err(|e| format!("cannot write {NTP_CONF}: {e}"))?;
        run(&[SYSTEMCTL, "restart", "--no-ask-password", "--", TIMESYNCD], RESTART_TIMEOUT)?;
        let loaded = loaded_ntp()?;
        if !loaded.split_whitespace().any(|s| s == server) {
            return Err(format!("systemd-timesyncd loaded {loaded:?} instead"));
        }
        end_txn(txn).map_err(|e| format!("cannot close the transaction: {e}"))?; // commit
        Ok(format!("systemd-timesyncd now lists {server} as a time server (it confirms it, {loaded:?})."))
    })();
    let why = match done {
        Ok(out) => return Ok(out),
        Err(why) => why,
    };
    let undone = rollback(&j).and_then(|_| end_txn(txn));
    let _ = run(&[SYSTEMCTL, "try-restart", "--no-ask-password", "--", TIMESYNCD], RESTART_TIMEOUT);
    let clean = undone.is_ok() && j.iter().all(|(p, prior)| snapshot(p) == *prior);
    let _ = audit("rolled_back", peer, json!({"unit": TIMESYNCD, "value": server, "reason": why, "clean": clean}));
    Err(if clean {
        format!("could not set the time server to {server}: {why}. The previous setting is back.")
    } else {
        format!("could not set the time server to {server}: {why}, and undoing it also failed ({})", undone.err().map_or("the file does not match what it was".into(), |e| e.to_string()))
    })
}

/// Precondition: the unit is loaded. Postcondition of a restart: it is active again, with a newer start time.
/// `systemctl start` of the oneshot returns when apt is done; dpkg's own record is the check, not apt's exit code.
fn install_pkg(pkg: &str) -> Result<String, String> {
    run(&[SYSTEMCTL, "start", "--no-ask-password", "--", &format!("agentd-pkg@{pkg}.service")], INSTALL_TIMEOUT)
        .map_err(|e| format!("apt-get could not install {pkg}: {e}"))?;
    let st = run(&["/usr/bin/dpkg-query", "-W", "-f=${Status} ${Version}", "--", pkg], SHOW_TIMEOUT).unwrap_or_default();
    match st.strip_prefix("install ok installed ") {
        Some(v) => Ok(format!("Installed {pkg} {}.", v.trim())),
        None => Err(format!("{pkg} is not installed afterwards (dpkg: {})", st.trim())),
    }
}

fn execute(r: &Req, peer: u32) -> Result<String, String> {
    if r.op == Op::Install {
        return install_pkg(r.pkg.as_deref().ok_or("no package")?);
    }
    let name = r.unit.name;
    let before = show(name)?;
    if field(&before, "LoadState") != "loaded" {
        return Err(format!("{name} is not loaded on this system"));
    }
    match r.op {
        Op::Status => return Ok(format!("{name} is {} ({})", field(&before, "ActiveState"), field(&before, "SubState"))),
        Op::SetNtp => return set_ntp(r.value.ok_or("no server")?, peer),
        Op::Restart | Op::Install => {}
    }
    run(&[SYSTEMCTL, "restart", "--no-ask-password", "--", name], RESTART_TIMEOUT)?;
    let after = show(name)?;
    if field(&after, "ActiveState") != "active" || stamp(&after) <= stamp(&before) {
        return Err(format!("{name} did not come back: it is {}", field(&after, "ActiveState")));
    }
    Ok(format!("Restarted {name}; it is {} ({}).", field(&after, "ActiveState"), field(&after, "SubState")))
}

struct Pending {
    id: u64,
    text: String,
    /// (allowed, uid of the person's console)
    answer: Option<(bool, u32)>,
}

#[derive(Default)]
struct Shared {
    pending: Mutex<Option<Pending>>,
    changed: Condvar,
}

enum Verdict {
    Allowed(u32),
    Refused(u32),
    NoAnswer,
    HungUp,
}

/// One approval at a time: requests are handled serially. Clearing `pending` here is what makes a late answer miss.
fn wait_for_person(c: &UnixStream, s: &Shared, id: u64, text: String) -> Verdict {
    *s.pending.lock().unwrap() = Some(Pending { id, text, answer: None });
    reply(c, &json!({"status": "approval_required", "id": id}));
    let end = Instant::now() + APPROVAL_TIMEOUT;
    let mut g = s.pending.lock().unwrap();
    let verdict = loop {
        if let Some((allowed, uid)) = g.as_ref().and_then(|p| p.answer) {
            break if allowed { Verdict::Allowed(uid) } else { Verdict::Refused(uid) };
        }
        if gone(c) {
            break Verdict::HungUp;
        }
        if Instant::now() >= end {
            break Verdict::NoAnswer;
        }
        g = s.changed.wait_timeout(g, Duration::from_millis(100)).unwrap().0;
    };
    *g = None;
    verdict
}

/// One request per connection, end to end, so operations never overlap.
fn handle(c: UnixStream, s: &Shared, next_id: &mut u64, restarts: &mut HashMap<&'static str, Vec<Instant>>) {
    let peer = peer_uid(&c);
    let _ = c.set_read_timeout(Some(READ_TIMEOUT));
    let mut line = String::new();
    let read = BufReader::new((&c).take(MAX_REQUEST as u64 + 1)).read_line(&mut line);
    let raw: String = line.chars().take(256).collect();
    let refuse = |phase: &str, status: &str, why: &str, detail: Value| {
        let _ = audit(phase, peer, json!({"reason": why, "request": detail}));
        reply(&c, &json!({"status": status, "reason": why}));
    };
    if audit("requested", peer, json!({"raw": raw})).is_err() {
        return reply(&c, &json!({"status": "failed", "reason": "cannot write the audit record, so nothing was done"}));
    }
    let parsed = match read {
        Ok(_) if line.len() <= MAX_REQUEST && line.ends_with('\n') => parse(line.trim_end()),
        _ => Err("request is too long, unreadable or unterminated".to_string()),
    };
    let r = match parsed {
        Ok(r) => r,
        Err(why) => return refuse("rejected", "rejected", &why, json!(raw)),
    };
    let detail = r.detail();
    let now = Instant::now();
    if r.op != Op::Status && over_limit(restarts.entry(r.unit.name).or_default(), now) {
        return refuse("rejected", "rejected", "this service was restarted too many times recently", detail);
    }
    if let Some(text) = r.approval() {
        *next_id += 1;
        match wait_for_person(&c, s, *next_id, text) {
            Verdict::Allowed(uid) => { let _ = audit("approved", uid, detail.clone()); }
            Verdict::Refused(uid) => {
                let _ = audit("denied", uid, detail.clone());
                return reply(&c, &json!({"status": "denied", "reason": "the person refused"}));
            }
            Verdict::NoAnswer => return refuse("denied", "denied", "nobody answered in time", detail),
            Verdict::HungUp => return refuse("cancelled", "cancelled", "the request was withdrawn", detail),
        }
    }
    if gone(&c) {
        return refuse("cancelled", "cancelled", "the request was withdrawn", detail);
    }
    if audit("started", peer, detail.clone()).is_err() {
        return reply(&c, &json!({"status": "failed", "reason": "cannot write the audit record, so nothing was done"}));
    }
    if r.op != Op::Status {
        restarts.entry(r.unit.name).or_default().push(Instant::now());
    }
    match execute(&r, peer) {
        Ok(output) => {
            let _ = audit("verified", peer, json!({"request": detail, "output": output}));
            reply(&c, &json!({"status": "ok", "output": output}));
        }
        Err(why) => refuse("failed", "failed", &why, detail),
    }
}

/// `{"id":N}` shows the broker's own text for a pending request; the next line decides, and only "yes" allows it.
fn answer(c: UnixStream, s: &Shared) {
    let uid = peer_uid(&c);
    let _ = c.set_read_timeout(Some(READ_TIMEOUT));
    let mut r = BufReader::new((&c).take(MAX_REQUEST as u64));
    let mut line = String::new();
    let _ = r.read_line(&mut line);
    let Some(id) = serde_json::from_str::<Value>(&line).ok().and_then(|v| v["id"].as_u64()) else {
        return reply(&c, &json!({"error": "bad request"}));
    };
    let text = s.pending.lock().unwrap().as_ref().filter(|p| p.id == id && p.answer.is_none()).map(|p| p.text.clone());
    let Some(text) = text else {
        return reply(&c, &json!({"error": "that request is not waiting for an answer"}));
    };
    reply(&c, &json!({"id": id, "text": text}));
    let _ = c.set_read_timeout(Some(APPROVAL_TIMEOUT));
    line.clear();
    let allowed = r.read_line(&mut line).is_ok() && line.trim() == "yes";
    if let Some(p) = s.pending.lock().unwrap().as_mut().filter(|p| p.id == id) {
        p.answer = Some((allowed, uid));
        s.changed.notify_all();
    }
}

/// The two sockets, told apart by the names their units give them: mixing them up would let agentd approve itself.
fn sockets() -> Result<(UnixListener, UnixListener), String> {
    let var = |k: &str| std::env::var(k).unwrap_or_default();
    if var("LISTEN_FDS") != "2" || var("LISTEN_PID") != std::process::id().to_string() {
        return Err("no sockets from systemd: start agentd-broker.socket and agentd-approve.socket".into());
    }
    let names = var("LISTEN_FDNAMES");
    let names: Vec<&str> = names.split(':').collect();
    let fd = |n: &str| names.iter().position(|x| *x == n).map(|i| 3 + i as i32).ok_or(format!("no socket named {n}"));
    let (agent, approve) = (fd("agent")?, fd("approve")?);
    Ok(unsafe { (UnixListener::from_raw_fd(agent), UnixListener::from_raw_fd(approve)) })
}

fn main() {
    // Boot (agentd-broker-recover.service): undo an interrupted change before anything can read or ask for one.
    if std::env::args().nth(1).as_deref() == Some("--recover") {
        if let Err(e) = recover_open_txn(0) {
            eprintln!("agentd-broker: {e}");
            std::process::exit(1);
        }
        return;
    }
    let (agent, approve) = sockets().unwrap_or_else(|e| {
        eprintln!("agentd-broker: {e}");
        std::process::exit(1);
    });
    // Socket activation after a crash: the same recovery, before the first request is answered.
    let _ = recover_open_txn(0);
    let shared = Arc::new(Shared::default());
    let s = shared.clone();
    std::thread::spawn(move || approve.incoming().flatten().for_each(|c| answer(c, &s)));
    let (mut next_id, mut restarts) = (0, HashMap::new());
    // shortcut: the restart counts live in memory and reset if the broker restarts, persist them if that ever matters.
    agent.incoming().flatten().for_each(|c| handle(c, &shared, &mut next_id, &mut restarts));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(op: &str, unit: &str) -> String {
        json!({"op": op, "unit": unit, "task_id": "t-1", "step": 1}).to_string()
    }

    fn ntp(value: Value) -> String {
        json!({"op": "config.set_ntp", "unit": TIMESYNCD, "task_id": "t-1", "step": 1, "value": value}).to_string()
    }

    #[test]
    fn accepts_only_the_table() {
        for u in &UNITS {
            assert_eq!(parse(&req("service.status", u.name)).unwrap().op, Op::Status);
            assert_eq!(parse(&req("service.restart", u.name)).unwrap().op, Op::Restart);
        }
    }

    #[test]
    fn install_takes_a_package_name_and_always_asks() {
        let r = parse(&req("pkg.install", "sl")).unwrap();
        assert_eq!((r.op, r.pkg.as_deref()), (Op::Install, Some("sl")));
        assert!(r.approval().unwrap().contains("\"sl\""), "the person is asked, naming the package");
        for bad in ["", "s", "Sl", "sl;rm", "sl --reinstall", "../x", "g++", "-x", "sl\n", &"a".repeat(65), "cron.service" /* a unit is fine, but as a package it is not special */] {
            let ok = parse(&req("pkg.install", bad)).is_ok();
            assert_eq!(ok, bad == "cron.service", "{bad:?}");
        }
        assert!(parse(&req("pkg.install", "cron.service")).unwrap().pkg.is_some());
    }

    #[test]
    fn set_ntp_takes_only_a_server_from_the_list_on_timesyncd() {
        for server in &NTP_SERVERS {
            let r = parse(&ntp(json!(server))).unwrap();
            assert_eq!(r.op, Op::SetNtp);
            assert_eq!(r.value, Some(*server));
            assert!(r.approval().is_none(), "set_ntp is automatic");
        }
        let bad = [
            ntp(json!("ntp.example.com")), ntp(json!("")), ntp(json!("time.cloudflare.com ")), ntp(json!("TIME.GOOGLE.COM")),
            ntp(json!("pool.ntp.org\n[Time]\nNTP=evil")), ntp(json!(["pool.ntp.org"])), ntp(json!(null)), ntp(json!(1)),
            req("config.set_ntp", TIMESYNCD), // no value
            json!({"op": "config.set_ntp", "unit": "cron.service", "task_id": "t", "step": 1, "value": "pool.ntp.org"}).to_string(),
            json!({"op": "config.set_ntp", "unit": TIMESYNCD, "task_id": "t", "step": 1, "value": "pool.ntp.org", "x": 1}).to_string(),
        ];
        for b in &bad {
            assert!(parse(b).is_err(), "accepted {b}");
        }
    }

    #[test]
    fn rejects_everything_else() {
        let long = "a".repeat(65);
        let bad = [
            "".to_string(), "not json".to_string(), "[]".to_string(), "{}".to_string(),
            req("service.stop", "cron.service"), req("shell", "cron.service"), req("SERVICE.RESTART", "cron.service"),
            req("service.restart", "agentd.service"), req("service.restart", "agentd-broker.service"),
            req("service.restart", "agentos-kiosk.service"), req("service.restart", "agentos-debug.service"),
            req("service.restart", "dbus.service"), req("service.restart", "cron"),
            req("service.restart", "../cron.service"), req("service.restart", "/etc/systemd/system/cron.service"),
            req("service.restart", "cron.service;reboot"), req("service.restart", "cron.service --force"),
            req("service.restart", "cron.service\n"), req("service.restart", "CRON.SERVICE"), req("service.restart", ""),
            json!({"op": "service.restart", "unit": "cron.service", "task_id": "t", "step": 1, "approved": true}).to_string(),
            json!({"op": "service.restart", "unit": "cron.service", "task_id": "t"}).to_string(),
            json!({"op": "service.restart", "unit": ["cron.service"], "task_id": "t", "step": 1}).to_string(),
            json!({"op": "service.restart", "unit": "cron.service", "task_id": "t", "step": "1"}).to_string(),
            json!({"op": "service.restart", "unit": "cron.service", "task_id": "t", "step": -1}).to_string(),
            json!({"op": "service.restart", "unit": "cron.service", "task_id": "", "step": 1}).to_string(),
            json!({"op": "service.restart", "unit": "cron.service", "task_id": "a b", "step": 1}).to_string(),
            json!({"op": "service.restart", "unit": "cron.service", "task_id": long, "step": 1}).to_string(),
        ];
        for b in &bad {
            assert!(parse(b).is_err(), "accepted {b}");
        }
    }

    #[test]
    fn approval_is_required_only_to_restart_networkmanager() {
        let needs = |op, unit| parse(&req(op, unit)).unwrap().approval().is_some();
        assert!(needs("service.restart", "NetworkManager.service"));
        assert!(!needs("service.status", "NetworkManager.service"));
        assert!(!needs("service.restart", "cron.service"));
        assert!(!needs("service.restart", "systemd-timesyncd.service"));
    }

    #[test]
    fn restart_limit_applies_within_the_window_only() {
        let now = Instant::now();
        let mut done = vec![now; RESTARTS_PER_WINDOW - 1];
        assert!(!over_limit(&mut done, now));
        done.push(now);
        assert!(over_limit(&mut done, now));
        assert!(!over_limit(&mut done, now + RESTART_WINDOW));
        assert!(done.is_empty());
    }
}
