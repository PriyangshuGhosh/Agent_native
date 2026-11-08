//! agentd-broker: the only part of agentd's stack that may change the system (agentd/debian/agentd-broker.service).
//! agentd proposes typed operations on one socket; a person answers approvals on another, which agentd cannot open.
//! The policy is compiled in, so nothing the model says can rewrite it. Contract: tests/test-debian-vm.sh.
use serde_json::{Value, json};
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
}

struct Req {
    op: Op,
    unit: &'static Unit,
    task_id: String,
    step: u64,
}

impl Req {
    fn approval(&self) -> Option<&'static str> {
        if self.op == Op::Restart { self.unit.approval } else { None }
    }
    fn detail(&self) -> Value {
        json!({"op": format!("{:?}", self.op), "unit": self.unit.name, "task_id": self.task_id, "step": self.step})
    }
}

/// Exactly four fields of exactly these types, naming an operation and a unit from the table.
fn parse(line: &str) -> Result<Req, String> {
    let v: Value = serde_json::from_str(line).map_err(|_| "not valid JSON")?;
    let o = v.as_object().ok_or("not a JSON object")?;
    if o.len() != 4 || !["op", "unit", "task_id", "step"].iter().all(|k| o.contains_key(*k)) {
        return Err("fields must be exactly op, unit, task_id and step".into());
    }
    let op = match o["op"].as_str() {
        Some("service.status") => Op::Status,
        Some("service.restart") => Op::Restart,
        _ => return Err("unknown operation".into()),
    };
    let name = o["unit"].as_str().ok_or("unit is not a string")?;
    let unit = UNITS.iter().find(|u| u.name == name).ok_or("unit is not on the allowlist")?;
    let task_id = o["task_id"].as_str().ok_or("task_id is not a string")?;
    if task_id.is_empty() || task_id.len() > 64 || !task_id.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b)) {
        return Err("bad task_id".into());
    }
    let step = o["step"].as_u64().ok_or("step is not a number")?;
    Ok(Req { op, unit, task_id: task_id.to_string(), step })
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

/// Fixed binary, empty environment, bounded time. Unit names come from UNITS, never from a request.
fn systemctl(args: &[&str], limit: Duration) -> Result<String, String> {
    let mut child = Command::new("/usr/bin/systemctl").args(args).env_clear().stdin(Stdio::null()).stdout(Stdio::piped())
        .stderr(Stdio::null()).spawn().map_err(|e| format!("cannot run systemctl: {e}"))?;
    let end = Instant::now() + limit;
    loop {
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(s) if s.success() => {
                let mut out = String::new();
                child.stdout.take().ok_or("no output")?.read_to_string(&mut out).map_err(|e| e.to_string())?;
                return Ok(out);
            }
            Some(s) => return Err(format!("systemctl {} failed: {s}", args[0])),
            None if Instant::now() >= end => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("systemctl {} timed out", args[0]));
            }
            None => sleep(Duration::from_millis(20)),
        }
    }
}

fn show(unit: &str) -> Result<HashMap<String, String>, String> {
    let out = systemctl(&["show", "--property=LoadState,ActiveState,SubState,ActiveEnterTimestampMonotonic", "--", unit], SHOW_TIMEOUT)?;
    Ok(out.lines().filter_map(|l| l.split_once('=')).map(|(k, v)| (k.to_string(), v.to_string())).collect())
}

fn field<'a>(m: &'a HashMap<String, String>, k: &str) -> &'a str {
    m.get(k).map_or("", String::as_str)
}

fn stamp(m: &HashMap<String, String>) -> u64 {
    field(m, "ActiveEnterTimestampMonotonic").parse().unwrap_or(0)
}

/// Precondition: the unit is loaded. Postcondition of a restart: it is active again, with a newer start time.
fn execute(r: &Req) -> Result<String, String> {
    let name = r.unit.name;
    let before = show(name)?;
    if field(&before, "LoadState") != "loaded" {
        return Err(format!("{name} is not loaded on this system"));
    }
    if r.op == Op::Status {
        return Ok(format!("{name} is {} ({})", field(&before, "ActiveState"), field(&before, "SubState")));
    }
    systemctl(&["restart", "--no-ask-password", "--", name], RESTART_TIMEOUT)?;
    let after = show(name)?;
    if field(&after, "ActiveState") != "active" || stamp(&after) <= stamp(&before) {
        return Err(format!("{name} did not come back: it is {}", field(&after, "ActiveState")));
    }
    Ok(format!("Restarted {name}; it is {} ({}).", field(&after, "ActiveState"), field(&after, "SubState")))
}

struct Pending {
    id: u64,
    text: &'static str,
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
fn wait_for_person(c: &UnixStream, s: &Shared, id: u64, text: &'static str) -> Verdict {
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
    if r.op == Op::Restart && over_limit(restarts.entry(r.unit.name).or_default(), now) {
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
    if r.op == Op::Restart {
        restarts.entry(r.unit.name).or_default().push(Instant::now());
    }
    match execute(&r) {
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
    let text = s.pending.lock().unwrap().as_ref().filter(|p| p.id == id && p.answer.is_none()).map(|p| p.text);
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
    let (agent, approve) = sockets().unwrap_or_else(|e| {
        eprintln!("agentd-broker: {e}");
        std::process::exit(1);
    });
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

    #[test]
    fn accepts_only_the_table() {
        for u in &UNITS {
            assert_eq!(parse(&req("service.status", u.name)).unwrap().op, Op::Status);
            assert_eq!(parse(&req("service.restart", u.name)).unwrap().op, Op::Restart);
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
