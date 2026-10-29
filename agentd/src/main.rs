//! agentd: the CUA-AgentOS agent runtime, run by agent-init as its final workload.
//! Cycle 04: waits for the session, proves each capability tier once (contract: tests/gate-04.sh).
//! Cycle 05: if a recorded plan is bundled, runs it through the cognitive loop (contract: tests/gate-05.sh).
//! Cycle 06: if capability packages are bundled, installs each into the overlay transactionally, runs and
//! verifies it, and rolls back any that fails (contract: tests/gate-06.sh).
//! Cycle 08: also measures Tier 3 screencopy FPS (contract: tests/gate-08.sh).
//! Every child runs in its own process group under the 30 s step cap; SIGUSR1 is the emergency stop.
//! Reports JSON lines on ttyS0 and exits; agent-init powers off when it does.
//! Debian: `agentd serve` is a systemd service (agentd/debian/agentd.service) planning each request live with
//! Gemini; `agentd ask <request>` sends one request and prints its telemetry (contract: tests/test-debian-vm.sh).
use serde_json::{Map, Value, json};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering::SeqCst};
use std::sync::mpsc;
use std::thread::sleep;
use std::time::{Duration, Instant};
use zbus::blocking::{Connection, connection::Builder};
use zbus::zvariant::{DynamicType, OwnedObjectPath, OwnedValue};

type Res<T> = Result<T, Box<dyn std::error::Error>>;
/// An AT-SPI accessible: (bus name, object path).
type Node = (String, OwnedObjectPath);

const RUNTIME: &str = "/run/user/0";
const ACC: &str = "org.a11y.atspi.Accessible";
/// Every D-Bus call is bounded, so a hung app cannot stall a step forever.
const DBUS_TIMEOUT: Duration = Duration::from_secs(5);

fn now_ms() -> i64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut ts) };
    ts.tv_sec * 1000 + ts.tv_nsec / 1_000_000
}

fn emit(tty: &mut dyn Write, event: &str, fields: &[(&str, Value)]) {
    let mut s = format!(r#"{{"ts_ms":{},"event":"{event}""#, now_ms());
    for (k, v) in fields {
        s += &format!(",\"{k}\":{v}");
    }
    let _ = writeln!(tty, "{s}}}");
}

fn wait_for<T>(what: &str, secs: u64, mut f: impl FnMut() -> Option<T>) -> Res<T> {
    let end = Instant::now() + Duration::from_secs(secs);
    loop {
        if let Some(v) = f() {
            return Ok(v);
        }
        if Instant::now() > end {
            return Err(format!("timed out waiting for {what}").into());
        }
        sleep(Duration::from_millis(20));
    }
}

/// Set by SIGUSR1: no further UI action, FFI call or child process; the running child's group is killed.
static STOPPED: AtomicBool = AtomicBool::new(false);
/// Process group of the running child (0 = none), for the step cap and the emergency stop.
static CHILD_PGID: AtomicI32 = AtomicI32::new(0);
const STOP_MSG: &str = "emergency stop (SIGUSR1)";

extern "C" fn on_sigusr1(_: libc::c_int) {
    STOPPED.store(true, SeqCst);
    let g = CHILD_PGID.load(SeqCst);
    if g > 0 {
        unsafe { libc::kill(-g, libc::SIGKILL) };
    }
}

fn stopped() -> Res<()> {
    if STOPPED.load(SeqCst) { Err(STOP_MSG.into()) } else { Ok(()) }
}

/// Each tier returns (expected, actual, latency in ms of the timed part).
type Proof = (Value, Value, f64);

/// Tier 1: dlopen a bundled .so from tmpfs and call into it in-process.
fn tier1() -> Res<Proof> {
    stopped()?;
    fs::create_dir_all("/run/agentd")?;
    fs::copy("/usr/lib/agentd/libtier1.so", FFI_LIB)?;
    let t = Instant::now();
    let out = unsafe {
        let lib = libloading::Library::new(FFI_LIB)?;
        let fib: libloading::Symbol<unsafe extern "C" fn(u32) -> u64> = lib.get(b"tier1_fib")?;
        fib(50)
    };
    Ok((json!(12586269025u64), json!(out), ms(t)))
}

/// Tier 2: a headless child transforms data over stdin/stdout pipes.
fn tier2() -> Res<Proof> {
    let want = "AGENTD TIER2 PIPE\n";
    let t = Instant::now();
    let out = run_capped(&["/usr/bin/tr", "a-z", "A-Z"], "agentd tier2 pipe\n")?;
    Ok((json!(want), json!(out), ms(t)))
}

fn call<B: serde::Serialize + DynamicType>(c: &Connection, n: &Node, iface: &str, m: &str, b: &B) -> zbus::Result<zbus::Message> {
    c.call_method(Some(n.0.as_str()), n.1.as_str(), Some(iface), m, b)
}

fn name(c: &Connection, n: &Node) -> Option<String> {
    let v: OwnedValue = call(c, n, "org.freedesktop.DBus.Properties", "Get", &(ACC, "Name")).ok()?.body().deserialize().ok()?;
    String::try_from(v).ok()
}

fn children(c: &Connection, n: &Node) -> Vec<Node> {
    call(c, n, ACC, "GetChildren", &()).and_then(|m| m.body().deserialize()).unwrap_or_default()
}

/// Depth-first search for mousepad's editable text widget.
fn find_text(c: &Connection, n: &Node) -> Option<Node> {
    let role: String = call(c, n, ACC, "GetRoleName", &()).ok()?.body().deserialize().ok()?;
    if role == "text" {
        let ifaces: Vec<String> = call(c, n, ACC, "GetInterfaces", &()).ok()?.body().deserialize().ok()?;
        if ifaces.iter().any(|i| i == "org.a11y.atspi.EditableText") {
            return Some(n.clone());
        }
    }
    children(c, n).iter().find_map(|k| find_text(c, k))
}

/// Connects to the AT-SPI bus and finds `app`'s editable text widget.
fn atspi(app: &str) -> Res<(Connection, Node)> {
    let session = Builder::session()?.method_timeout(DBUS_TIMEOUT).build()?;
    let addr: String = wait_for("AT-SPI bus", 10, || {
        call(&session, &("org.a11y.Bus".into(), "/org/a11y/bus".try_into().ok()?), "org.a11y.Bus", "GetAddress", &())
            .ok()?.body().deserialize().ok()
    })?;
    let a11y = Builder::address(addr.as_str())?.method_timeout(DBUS_TIMEOUT).build()?;
    let root: Node = ("org.a11y.atspi.Registry".into(), "/org/a11y/atspi/accessible/root".try_into()?);
    let node = wait_for(&format!("{app} on AT-SPI"), 30, || {
        children(&a11y, &root).into_iter().find(|k| name(&a11y, k).is_some_and(|s| s.to_lowercase().contains(app)))
    })?;
    let text = wait_for(&format!("{app} text widget"), 30, || find_text(&a11y, &node))?;
    Ok((a11y, text))
}

/// Tier 3: set mousepad's text over AT-SPI (no pixels, no input events) and read it back.
fn tier3() -> Res<Proof> {
    let (a11y, text) = atspi("mousepad")?;
    let want = "agentd-tier3";
    let t = Instant::now();
    let got = set_text(&a11y, &text, want)?;
    Ok((json!(want), json!(got), ms(t)))
}

/// Tier 3 pixel fallback: grabs frames of the headless output over wlr-screencopy (grim); returns (frames, fps).
fn screencopy() -> Res<(u32, f64)> {
    let frames = 15;
    let t = Instant::now();
    for _ in 0..frames {
        run_capped_env(&["/usr/bin/grim", "-t", "ppm", "-o", "HEADLESS-1", "/tmp/frame.ppm"], "", WAYLAND_ENV).map_err(|e| format!("grim: {e}"))?;
        let mut magic = [0u8; 2];
        File::open("/tmp/frame.ppm")?.read_exact(&mut magic)?;
        if &magic != b"P6" {
            return Err("grim wrote a non-PPM frame".into());
        }
    }
    Ok((frames, (f64::from(frames) / t.elapsed().as_secs_f64() * 10.0).round() / 10.0))
}

/// SetTextContents, then the widget's text as read back.
fn set_text(a11y: &Connection, text: &Node, want: &str) -> Res<String> {
    stopped()?;
    let read = || -> Res<String> { Ok(call(a11y, text, "org.a11y.atspi.Text", "GetText", &(0i32, -1i32))?.body().deserialize()?) };
    call(a11y, text, "org.a11y.atspi.EditableText", "SetTextContents", &(want,))?;
    let mut got = read()?;
    // The widget may apply the edit a little later; the extra wait is counted in the latency.
    let settle = Instant::now() + Duration::from_secs(5);
    while got != want && Instant::now() < settle {
        sleep(Duration::from_millis(5));
        got = read()?;
    }
    Ok(got)
}

const PLAN: &str = "/usr/share/agentd/gemini_plan.json";
const REPAIR_BUDGET: u32 = 3;
/// AtspiStateType order: a state's bit index in GetState's bitfield.
const STATES: [&str; 31] = ["invalid", "active", "armed", "busy", "checked", "collapsed", "defunct", "editable",
    "enabled", "expandable", "expanded", "focusable", "focused", "has-tooltip", "horizontal", "iconified", "modal",
    "multi-line", "multiselectable", "opaque", "pressed", "resizable", "selectable", "selected", "sensitive",
    "showing", "single-line", "stale", "transient", "vertical", "visible"];
/// Tier 1 symbols with the known signature `u32 f(const u8 *, usize)`; a planner-chosen symbol is never called blind.
const FFI_ALLOW: [&str; 1] = ["tier1_fnv1a"];
/// The only Tier 1 library: tier1() stages it on agentd's tmpfs.
const FFI_LIB: &str = "/run/agentd/libtier1.so";
/// Tier 2 executables a plan may run: exact paths in the read-only base.
const EXEC_ALLOW: [&str; 1] = ["/usr/bin/tr"];

/// One planner directive (example: tests/fixtures/gemini_plan.json).
struct Directive {
    task_id: String,
    step: u64,
    tier: u64,
    action: String,
    target: String,
    params: Value,
    expected_role: Option<String>,
    pre: Value,
    post: Value,
}

/// Parses one Gemini generateContent response into (task_id, directives); anything off-schema is an error.
fn parse_response(r: &Value) -> Res<(String, Vec<Directive>)> {
    let text = r["candidates"][0]["content"]["parts"][0]["text"].as_str().ok_or("response has no text part")?;
    let body: Value = serde_json::from_str(text)?;
    let task = body["task_id"].as_str().ok_or("plan has no task_id")?.to_string();
    let s = |d: &Value, k: &str| d[k].as_str().map(String::from).ok_or(format!("directive has no string {k}"));
    let mut steps = HashSet::new();
    let ds = body["directives"].as_array().ok_or("plan has no directives")?.iter().map(|d| -> Res<Directive> {
        let v = &d["validation"];
        let d = Directive {
            task_id: s(d, "task_id")?,
            step: d["step"].as_u64().ok_or("directive has no step")?,
            tier: d["tier"].as_u64().ok_or("directive has no tier")?,
            action: s(d, "action")?,
            target: s(d, "target")?,
            params: d["params"].clone(),
            expected_role: match &v["expected_role"] {
                Value::Null => None,
                r => Some(r.as_str().ok_or("expected_role is not a string")?.to_string()),
            },
            pre: v["precondition_state"].clone(),
            post: v["expected_postcondition"].clone(),
        };
        check_directive(&d).map_err(|e| format!("step {}: directive off schema: {e}", d.step))?;
        if d.task_id != task || !steps.insert(d.step) {
            return Err(format!("step {}: wrong task_id or duplicate step", d.step).into());
        }
        Ok(d)
    }).collect::<Res<Vec<_>>>()?;
    if ds.is_empty() {
        // An empty plan would "succeed" with nothing done.
        return Err(format!("planner declined: {}", body["unsupported"].as_str().unwrap_or("no directives")).into());
    }
    Ok((task, ds))
}

/// Schema and policy for one directive: tier/action pairing, allow-listed targets, every required param, a
/// postcondition, known preconditions, and "$N" references only to earlier steps.
fn check_directive(d: &Directive) -> Result<(), String> {
    let p = d.params.as_object().ok_or("params is not an object")?;
    let strs = |keys: &[&str]| keys.iter().all(|k| p.get(*k).is_some_and(Value::is_string));
    let ok = match (d.tier, d.action.as_str()) {
        (3, "set_text") => !d.target.is_empty() && d.target.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            && strs(&["text"]),
        (2, "pipe") => EXEC_ALLOW.contains(&d.target.as_str()) && strs(&["stdin"])
            && p.get("args").and_then(Value::as_array).is_some_and(|a| a.len() <= 16 && a.iter().all(Value::is_string)),
        (1, "ffi_call") => d.target == FFI_LIB && FFI_ALLOW.contains(&p.get("symbol").and_then(Value::as_str).unwrap_or_default())
            && strs(&["input"]),
        _ => false,
    };
    if !ok {
        return Err(format!("tier {} {:?} on {:?} is not an allowed action with its params", d.tier, d.action, d.target));
    }
    if d.step == 0 || d.post.get("output").is_none() {
        return Err("step must be >= 1 with an expected_postcondition.output".into());
    }
    if let Some(n) = p.values().filter_map(step_ref).find(|n| *n >= d.step) {
        return Err(format!("refers to step {n}, which does not come before it"));
    }
    for (k, v) in d.pre.as_object().into_iter().flatten() {
        let ok = match k.as_str() {
            "states" => v.as_array().is_some_and(|a| a.iter().all(|s| s.as_str().is_some_and(|s| STATES.contains(&s)))),
            "path_exists" => v.is_string(),
            _ => false,
        };
        if !ok {
            return Err(format!("bad precondition {k}: {v}"));
        }
    }
    if !d.pre.is_object() && !d.pre.is_null() {
        return Err("precondition_state is not an object".into());
    }
    Ok(())
}

/// N if `v` is "$N", a reference to step N's verified output.
fn step_ref(v: &Value) -> Option<u64> {
    v.as_str()?.strip_prefix('$')?.parse().ok()
}

/// A string param; "$N" stands for step N's verified output.
fn param(d: &Directive, k: &str, outs: &HashMap<u64, Value>) -> Res<String> {
    let v = &d.params[k];
    let v = match step_ref(v) {
        Some(n) => outs.get(&n).ok_or(format!("{k} refers to unverified step {n}"))?,
        None => v,
    };
    Ok(v.as_str().ok_or(format!("param {k} is not a string"))?.to_string())
}

/// Tier 1: calls an allow-listed `u32 sym(const u8 *, usize)` from the staged Tier 1 library, in-process.
fn ffi(lib: &str, sym: &str, input: &str) -> Res<u32> {
    stopped()?;
    if lib != FFI_LIB || !FFI_ALLOW.contains(&sym) {
        return Err(format!("{lib}:{sym} is not an allowed Tier 1 call").into());
    }
    unsafe {
        let lib = libloading::Library::new(lib)?;
        let f: libloading::Symbol<unsafe extern "C" fn(*const u8, usize) -> u32> = lib.get(sym.as_bytes())?;
        Ok(f(input.as_ptr(), input.len()))
    }
}

/// Pre-action validation, tier dispatch, post-action verification. Returns (output, latency ms of the
/// action); Err starts with the failing stage.
fn run_step(d: &Directive, ui: &mut Option<(String, Connection, Node)>, outs: &HashMap<u64, Value>) -> Result<(Value, f64), String> {
    if let Some(p) = d.pre["path_exists"].as_str() && !Path::new(p).exists() {
        return Err(format!("precondition: {p} does not exist"));
    }
    if d.tier == 3 {
        if ui.as_ref().is_none_or(|u| u.0 != d.target) {
            let (c, n) = atspi(&d.target).map_err(|e| format!("precondition: {e}"))?;
            *ui = Some((d.target.clone(), c, n));
        }
        let (_, c, n) = ui.as_ref().unwrap();
        let role: String = call(c, n, ACC, "GetRoleName", &()).and_then(|m| m.body().deserialize()).map_err(|e| format!("precondition: {e}"))?;
        if let Some(want) = &d.expected_role && *want != role {
            return Err(format!("precondition: {} widget role is {role:?}, expected {want:?}", d.target));
        }
        let bits: Vec<u32> = call(c, n, ACC, "GetState", &()).and_then(|m| m.body().deserialize()).map_err(|e| format!("precondition: {e}"))?;
        for st in d.pre["states"].as_array().into_iter().flatten() {
            let st = st.as_str().unwrap_or("?");
            let b = STATES.iter().position(|s| *s == st).ok_or(format!("precondition: unknown state {st:?}"))?;
            if bits.get(b / 32).is_none_or(|w| w & (1 << (b % 32)) == 0) {
                return Err(format!("precondition: {} widget is not {st}", d.target));
            }
        }
    }
    let t = Instant::now();
    let out = (|| -> Res<Value> {
        Ok(match d.tier {
            3 => { let (_, c, n) = ui.as_ref().unwrap(); json!(set_text(c, n, &param(d, "text", outs)?)?) }
            2 => {
                if !EXEC_ALLOW.contains(&d.target.as_str()) {
                    return Err(format!("{} is not an allowed Tier 2 executable", d.target).into());
                }
                let mut argv = vec![d.target.as_str()];
                argv.extend(d.params["args"].as_array().ok_or("params.args missing")?.iter().filter_map(Value::as_str));
                json!(run_capped(&argv, &param(d, "stdin", outs)?)?)
            }
            _ => json!(ffi(&d.target, &param(d, "symbol", outs)?, &param(d, "input", outs)?)?),
        })
    })().map_err(|e| format!("execute: {e}"))?;
    let lat = ms(t);
    if d.post["output"] != out {
        return Err(format!("postcondition: output {out}, expected {}", d.post["output"]));
    }
    Ok((out, lat))
}

/// Replays the recorded Gemini responses: [0] is the plan, each replan consumes the next one.
fn replay(tty: &mut dyn Write) -> Res<bool> {
    let fx: Value = serde_json::from_slice(&fs::read(PLAN)?)?;
    let mut responses = fx["responses"].as_array().ok_or("fixture has no responses")?.iter().cloned();
    workflow(tty, &fx["intent"], &fx["model"], "recorded", |_| responses.next().map(Ok))
}

/// Cognitive loop: `next(None)` gives the plan, `next(Some(reason))` a replan whose directives replace the failed
/// step (None = no more responses). Returns task success.
fn workflow(tty: &mut dyn Write, intent: &Value, model: &Value, source: &str,
            mut next: impl FnMut(Option<&str>) -> Option<Res<Value>>) -> Res<bool> {
    let (task, plan) = parse_response(&next(None).ok_or("planner gave no plan")??)?;
    let mut plan = VecDeque::from(plan);
    let tid = || ("task_id", json!(task));
    emit(tty, "TASK_START", &[tid(), ("intent", intent.clone()), ("model", model.clone()),
                               ("steps", json!(plan.len())), ("source", json!(source))]);
    let (mut outs, mut ui, mut repairs, mut err) = (HashMap::new(), None, 0, None);
    while let Some(d) = plan.pop_front() {
        match run_step(&d, &mut ui, &outs) {
            Ok((out, lat)) => {
                emit(tty, "STEP_VERIFIED", &[tid(), ("step", json!(d.step)), ("tier", json!(d.tier)), ("action", json!(d.action)),
                                             ("status", json!("ok")), ("output", out.clone()), ("latency_ms", json!(lat))]);
                outs.insert(d.step, out);
            }
            // An emergency stop is never repaired around.
            Err(reason) if STOPPED.load(SeqCst) => {
                err = Some(format!("{STOP_MSG}; step {}: {reason}", d.step));
                break;
            }
            Err(reason) => {
                repairs += 1;
                if repairs > REPAIR_BUDGET {
                    err = Some(format!("repair budget exhausted; last: {reason}"));
                    break;
                }
                emit(tty, "REPLAN_TRIGGERED", &[tid(), ("step", json!(d.step)), ("tier", json!(d.tier)), ("reason", json!(reason)),
                                                ("attempt", json!(repairs)), ("budget", json!(REPAIR_BUDGET))]);
                match next(Some(&reason)).map(|r| r.and_then(|v| parse_response(&v))) {
                    Some(Ok((t, ds))) if t == task => ds.into_iter().rev().for_each(|x| plan.push_front(x)),
                    r => {
                        err = Some(format!("no usable replan: {}", r.map_or("none recorded".into(), |r| r.err().map_or("task_id mismatch".into(), |e| e.to_string()))));
                        break;
                    }
                }
            }
        }
    }
    let ok = err.is_none();
    let mut f = vec![tid(), ("status", json!(if ok { "success" } else { "fail" })), ("steps", json!(outs.len())), ("repairs", json!(repairs))];
    if let Some(e) = err {
        f.push(("error", json!(e)));
    }
    emit(tty, "TASK_COMPLETE", &f);
    if ok {
        emit(tty, "WORKFLOW_COMPLETE", &[tid(), ("steps", json!(outs.len())), ("repairs", json!(repairs))]);
    }
    Ok(ok)
}

const PACKAGES: &str = "/usr/share/agentd/packages";
const REGISTRY: &str = "/data/registry.json";
/// Write-ahead journal of the open transaction (see staged_put); present only while one is in flight.
const TXN: &str = "/data/.agentd-txn";
/// Overlay layers as the initramfs leaves them (see scripts/build-harness.sh).
const UPPER: &str = "/mnt/rw/upper";
const BASE: &str = "/mnt/base";
const LIFECYCLE_TASK: &str = "t06-lifecycle";
const STEP_TIMEOUT: Duration = Duration::from_secs(if cfg!(test) { 1 } else { 30 });
/// A child's stdout beyond this is dropped (the child then blocks and meets the step cap).
const MAX_STDOUT: u64 = 1 << 20;

/// Every path a transaction touched, with its (bytes, mode) before it (None = it did not exist).
type Journal = Vec<(PathBuf, Option<(Vec<u8>, u32)>)>;

fn tmp_of(path: &Path) -> PathBuf {
    let mut t = path.as_os_str().to_owned();
    t.push(".agentd-tmp");
    t.into()
}

/// Atomically and durably replaces `path`: fresh temp file, fsync, rename in the same directory, fsync the directory.
fn put(path: &Path, data: &[u8], mode: u32) -> Res<()> {
    let tmp = tmp_of(path);
    let dir = path.parent().ok_or("path has no parent")?;
    let r = (|| -> Res<()> {
        fs::create_dir_all(dir)?;
        let _ = fs::remove_file(&tmp);
        // create_new (O_EXCL) never follows a planted symlink.
        let mut f = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        f.write_all(data)?;
        f.set_permissions(fs::Permissions::from_mode(mode))?;
        f.sync_all()?;
        fs::rename(&tmp, path)?;
        Ok(File::open(dir)?.sync_all()?)
    })();
    if r.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    r
}

fn snapshot(path: &Path) -> Option<(Vec<u8>, u32)> {
    Some((fs::read(path).ok()?, fs::metadata(path).ok()?.permissions().mode() & 0o7777))
}

/// Write-ahead: saves `path`'s prior state under `txn` (backup file + journal) before writing it, so a transaction
/// cut short by a crash is rolled back by recover() at the next start.
fn staged_put(j: &mut Journal, txn: &Path, path: &Path, data: &[u8], mode: u32) -> Res<()> {
    let prior = snapshot(path);
    if let Some((b, m)) = &prior {
        put(&txn.join(j.len().to_string()), b, *m)?;
    }
    j.push((path.into(), prior));
    let entries: Vec<(&PathBuf, bool)> = j.iter().map(|(p, prior)| (p, prior.is_some())).collect();
    put(&txn.join("journal.json"), &serde_json::to_vec(&entries)?, 0o600)?;
    put(path, data, mode)
}

/// Undoes a transaction, newest change first.
fn rollback(j: &Journal) -> Res<()> {
    for (p, prior) in j.iter().rev() {
        match prior {
            Some((b, m)) => put(p, b, *m)?,
            None => fs::remove_file(p).or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) })?,
        }
    }
    Ok(())
}

/// Closes a transaction (after commit or rollback): its journal goes, durably.
fn end_txn(txn: &Path) -> Res<()> {
    match fs::remove_dir_all(txn) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
        _ => {}
    }
    Ok(File::open(txn.parent().ok_or("txn has no parent")?)?.sync_all()?)
}

/// Rolls back a transaction a crash left open in `txn`. Returns (package, journal) if there was one.
fn recover(txn: &Path) -> Res<Option<(String, Journal)>> {
    let entries: Vec<(PathBuf, bool)> = match fs::read(txn.join("journal.json")) {
        Ok(b) => serde_json::from_slice(&b)?,
        // No journal yet: nothing outside txn was touched.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return end_txn(txn).map(|_| None),
        Err(e) => return Err(e.into()),
    };
    let j: Journal = entries.into_iter().enumerate().map(|(i, (p, had))| -> Res<_> {
        let _ = fs::remove_file(tmp_of(&p));
        Ok((p, if had { Some(snapshot(&txn.join(i.to_string())).ok_or("journal backup missing")?) } else { None }))
    }).collect::<Res<_>>()?;
    rollback(&j)?;
    let pkg = fs::read_to_string(txn.join("package")).unwrap_or_default();
    end_txn(txn)?;
    Ok(Some((pkg, j)))
}

/// The registry as a JSON object; missing = empty. A corrupt registry is an error, never silently replaced.
fn read_registry(path: &Path) -> Res<Map<String, Value>> {
    let b = match fs::read(path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Map::new()),
        r => r?,
    };
    match serde_json::from_slice(&b)? {
        Value::Object(o) => Ok(o),
        _ => Err(format!("{} is not a JSON object", path.display()).into()),
    }
}

/// Registry entries whose files are all present (what survived from earlier boots on a persistent /data).
fn installed(reg: &Map<String, Value>) -> Vec<&String> {
    reg.iter().filter(|(_, e)| e["files"].as_array().is_some_and(|fs| fs.iter().all(|f| f.as_str().is_some_and(|f| Path::new(f).exists()))))
        .map(|(k, _)| k).collect()
}

/// `p` as seen in another overlay layer.
fn in_layer(layer: &str, p: &Path) -> PathBuf {
    Path::new(layer).join(p.strip_prefix("/").unwrap_or(p))
}

/// Install targets: plain absolute paths under the capability dirs, never into the base system's own paths.
fn dst_allowed(p: &Path) -> bool {
    p.parent().is_some_and(|d| d.starts_with("/usr/local/bin") || d.starts_with("/opt"))
        && p.components().all(|c| matches!(c, Component::RootDir | Component::Normal(_)))
        && !in_layer(BASE, p).exists()
}

/// A manifest file entry's source in the extracted package: a regular file inside `stage` (no `..`, no symlink out).
fn package_src(stage: &Path, src: &str) -> Res<PathBuf> {
    let s = Path::new(src);
    if !s.components().all(|c| matches!(c, Component::Normal(_))) {
        return Err(format!("{src} escapes the package").into());
    }
    let s = fs::canonicalize(stage.join(s))?;
    if !s.starts_with(fs::canonicalize(stage)?) || !fs::metadata(&s)?.is_file() {
        return Err(format!("{src} is not a regular file inside the package").into());
    }
    Ok(s)
}

/// verify.argv as strings; it may only run a file this package installed.
fn verify_argv<'a>(m: &'a Value, files: &[PathBuf]) -> Res<Vec<&'a str>> {
    let argv = m["verify"]["argv"].as_array().ok_or("manifest has no verify.argv")?.iter()
        .map(|a| a.as_str().ok_or("verify.argv has a non-string")).collect::<Result<Vec<_>, _>>()?;
    if !argv.first().is_some_and(|a| files.iter().any(|f| f == Path::new(a))) {
        return Err("verify.argv[0] is not one of the package's installed files".into());
    }
    Ok(argv)
}

/// The session's Wayland socket, for agentd's own screencopy client only; planned and capability children never get it.
const WAYLAND_ENV: &[(&str, &str)] = &[("XDG_RUNTIME_DIR", RUNTIME), ("WAYLAND_DISPLAY", "wayland-0")];

fn run_capped(argv: &[&str], input: &str) -> Res<String> {
    run_capped_env(argv, input, &[])
}

/// Runs argv in its own process group, with PATH plus `env` only and `input` on stdin, under the per-step cap.
/// The whole group is SIGKILLed on timeout, on emergency stop, and once the leader exits (no stray grandchild
/// keeps running or holds stdout open). Returns stdout of a successful run.
fn run_capped_env(argv: &[&str], input: &str, env: &[(&str, &str)]) -> Res<String> {
    stopped()?;
    let mut child = Command::new(argv.first().ok_or("empty argv")?).args(&argv[1..])
        .env_clear().env("PATH", "/usr/bin:/bin").envs(env.iter().copied()).process_group(0)
        .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn()?;
    let pg = child.id() as i32;
    CHILD_PGID.store(pg, SeqCst);
    // stdin and stdout are pumped on threads so a child that writes while it reads cannot deadlock against us.
    let (mut i, o) = (child.stdin.take().ok_or("no stdin")?, child.stdout.take().ok_or("no stdout")?);
    let input = input.as_bytes().to_vec();
    std::thread::spawn(move || i.write_all(&input)); // i dropped after: EOF
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut s = String::new();
        let _ = tx.send(o.take(MAX_STDOUT).read_to_string(&mut s).map(|_| s));
    });
    let end = Instant::now() + STEP_TIMEOUT;
    let exited = loop {
        // WNOWAIT: the leader stays a zombie, so its group id cannot be reused before the kill below.
        let mut si: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let r = unsafe { libc::waitid(libc::P_PID, pg as libc::id_t, &mut si, libc::WEXITED | libc::WNOHANG | libc::WNOWAIT) };
        if r == 0 && unsafe { si.si_pid() } == pg {
            break true;
        }
        if r != 0 || Instant::now() > end || STOPPED.load(SeqCst) {
            break false;
        }
        sleep(Duration::from_millis(1));
    };
    unsafe { libc::kill(-pg, libc::SIGKILL) };
    CHILD_PGID.store(0, SeqCst);
    let st = child.wait()?;
    stopped()?;
    if !exited {
        return Err(format!("{} timed out after {}s (process group killed)", argv[0], STEP_TIMEOUT.as_secs()).into());
    }
    if !st.success() {
        return Err(format!("{} exited {st}", argv[0]).into());
    }
    // Every writer is dead, so EOF is immediate unless a process escaped the group (setsid).
    Ok(rx.recv_timeout(Duration::from_secs(1)).map_err(|_| "stdout still held open by an escaped process")??)
}

/// Install -> run -> verify for one package; on any failure, roll the transaction back and check it left no trace.
/// Returns whether the outcome is the expected one (verified, or cleanly rolled back if the fault was injected).
fn lifecycle_package(tty: &mut File, name: &str) -> Res<bool> {
    if name.is_empty() || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err(format!("bad package name {name:?}").into());
    }
    let pkg = || ("package", json!(name));
    let stage = Path::new("/tmp/agentd-stage").join(name);
    let _ = fs::remove_dir_all(&stage);
    fs::create_dir_all(&stage)?;
    let tar = format!("{PACKAGES}/{name}.tar");
    run_capped(&["/bin/tar", "-xf", &tar, "-C", stage.to_str().ok_or("stage path")?], "")?;
    let m: Value = serde_json::from_slice(&fs::read(stage.join("manifest.json"))?)?;
    let fault = m["injected_fault"].as_str();
    if let Some(f) = fault {
        emit(tty, "LIFECYCLE_FAIL_INJECTED", &[pkg(), ("fault", json!(f))]);
    }

    let (mut j, mut files, txn) = (Journal::new(), vec![], Path::new(TXN));
    let t = Instant::now();
    let r = (|| -> Res<String> {
        put(&txn.join("package"), name.as_bytes(), 0o600)?;
        for f in m["files"].as_array().ok_or("manifest has no files")? {
            let src = package_src(&stage, f["src"].as_str().ok_or("file has no src")?)?;
            let dst = Path::new(f["dst"].as_str().ok_or("file has no dst")?);
            if !dst_allowed(dst) {
                return Err(format!("{} is outside the capability dirs or shadows the base", dst.display()).into());
            }
            staged_put(&mut j, txn, dst, &fs::read(src)?, 0o755)?;
            files.push(dst.to_path_buf());
        }
        let mut reg = read_registry(Path::new(REGISTRY))?;
        reg.insert(name.into(), json!({"version": m["version"], "files": files, "status": "installed"}));
        staged_put(&mut j, txn, Path::new(REGISTRY), &serde_json::to_vec_pretty(&reg)?, 0o644)?;
        emit(tty, "LIFECYCLE_INSTALL", &[("task_id", json!(LIFECYCLE_TASK)), pkg(), ("version", m["version"].clone()),
                                         ("files", json!(files)), ("journal", json!(j.len()))]);
        emit(tty, "CAPABILITY_INSTALLED", &[pkg(), ("version", m["version"].clone())]);
        let out = run_capped(&verify_argv(&m, &files)?, "").map_err(|e| format!("execute: {e}"))?;
        if out != m["verify"]["stdout"].as_str().unwrap_or_default() {
            return Err(format!("verify: stdout {out:?}, expected {}", m["verify"]["stdout"]).into());
        }
        end_txn(txn)?; // commit
        Ok(out)
    })();
    let _ = fs::remove_dir_all(&stage);
    match r {
        Ok(out) => {
            let in_upper = files.iter().all(|f| in_layer(UPPER, f).exists());
            let in_base = files.iter().any(|f| in_layer(BASE, f).exists());
            emit(tty, "LIFECYCLE_VERIFIED", &[pkg(), ("status", json!("ok")), ("stdout", json!(out)), ("in_upper", json!(in_upper)),
                                              ("in_base", json!(in_base)), ("latency_ms", json!(ms(t)))]);
            Ok(fault.is_none() && in_upper && !in_base)
        }
        Err(reason) => {
            let reason = reason.to_string();
            emit(tty, "LIFECYCLE_VERIFIED", &[pkg(), ("status", json!("fail")), ("error", json!(reason))]);
            emit(tty, "ROLLBACK_TRIGGERED", &[pkg(), ("reason", json!(reason)), ("journal", json!(j.len()))]);
            emit(tty, "CAPABILITY_ROLLBACK", &[pkg(), ("reason", json!(reason))]);
            let undone = rollback(&j).and_then(|_| end_txn(txn));
            let clean = rollback_verified(tty, name, &j, undone);
            Ok(fault.is_some() && clean)
        }
    }
}

/// After a rollback, `reg` lists `name` exactly when it did before the transaction (a failed upgrade keeps the old entry).
fn registry_restored(j: &Journal, reg: &Path, name: &str) -> bool {
    let Some((_, prior)) = j.iter().find(|(p, _)| p == reg) else {
        return read_registry(reg).is_ok(); // the transaction never got to the registry
    };
    let before = prior.as_ref().is_some_and(|(b, _)| serde_json::from_slice::<Value>(b).is_ok_and(|r| r.get(name).is_some()));
    read_registry(reg).is_ok_and(|r| r.contains_key(name) == before)
}

/// Emits ROLLBACK_VERIFIED. Clean = every touched path is back to its prior bytes and mode, new files left nothing
/// (not even a whiteout) in the upper layer, the base never held them, and the registry lists the package only if
/// it did before.
fn rollback_verified(tty: &mut File, name: &str, j: &Journal, undone: Res<()>) -> bool {
    let restored = j.iter().all(|(p, prior)| snapshot(p) == *prior);
    let upper_clean = j.iter().all(|(p, prior)| prior.is_some() || !in_layer(UPPER, p).exists());
    let base_clean = j.iter().all(|(p, prior)| prior.is_some() || !in_layer(BASE, p).exists());
    let reg_clean = registry_restored(j, Path::new(REGISTRY), name);
    let clean = undone.is_ok() && restored && upper_clean && base_clean && reg_clean;
    let mut f = vec![("package", json!(name)), ("clean", json!(clean)), ("restored", json!(restored)),
                     ("upper_clean", json!(upper_clean)), ("base_clean", json!(base_clean)), ("journal", json!(j.len()))];
    if let Err(e) = undone {
        f.push(("error", json!(e.to_string())));
    }
    emit(tty, "ROLLBACK_VERIFIED", &f);
    clean
}

/// Runs every queued package through the lifecycle as one task, after rolling back any transaction a crash left open.
fn lifecycle(tty: &mut File) -> Res<bool> {
    let tid = || ("task_id", json!(LIFECYCLE_TASK));
    let mut ok = true;
    if let Some((pkg, j)) = recover(Path::new(TXN))? {
        let reason = json!("interrupted transaction found at start");
        emit(tty, "ROLLBACK_TRIGGERED", &[("package", json!(pkg)), ("reason", reason.clone()), ("journal", json!(j.len()))]);
        emit(tty, "CAPABILITY_ROLLBACK", &[("package", json!(pkg)), ("reason", reason)]);
        ok &= rollback_verified(tty, &pkg, &j, Ok(()));
    }
    let queue = fs::read_to_string(format!("{PACKAGES}/queue"))?;
    let names: Vec<&str> = queue.lines().map(str::trim).filter(|l| !l.is_empty()).collect();
    let reg = read_registry(Path::new(REGISTRY))?;
    emit(tty, "TASK_START", &[tid(), ("intent", json!("Install, run and verify each queued capability; roll back any that fails")),
                               ("packages", json!(names)), ("installed", json!(installed(&reg))), ("source", json!("local"))]);
    for n in &names {
        if STOPPED.load(SeqCst) {
            ok = false;
            break;
        }
        ok &= lifecycle_package(tty, n).unwrap_or_else(|e| {
            emit(tty, "LIFECYCLE_VERIFIED", &[("package", json!(n)), ("status", json!("fail")), ("error", json!(e.to_string()))]);
            false
        });
    }
    let reg = read_registry(Path::new(REGISTRY))?;
    let mut f = vec![tid(), ("status", json!(if ok { "success" } else { "fail" })), ("registry", json!(reg.keys().collect::<Vec<_>>()))];
    if STOPPED.load(SeqCst) {
        f.push(("error", json!(STOP_MSG)));
    }
    emit(tty, "TASK_COMPLETE", &f);
    Ok(ok)
}

fn ms(t: Instant) -> f64 {
    (t.elapsed().as_secs_f64() * 1e6).round() / 1e3
}

const SOCK: &str = "/run/agentd/agentd.sock";
const GEMINI_URL: &str = "https://generativelanguage.googleapis.com/v1beta/models";
/// gemini-2.5-flash is closed to new API keys. AGENTD_MODEL overrides: a comma-separated list, tried in order.
const MODEL_DEFAULT: &str = "gemini-3.8-flash,gemini-3.6-flash,gemini-3-flash-preview";
/// The planner contract. The model only proposes: parse_response/check_directive decide what runs.
const PLANNER_PROMPT: &str = r#"You plan tasks for agentd, the agent of an OS. Reply with JSON only:
{"task_id": "<short-kebab-id>", "directives": [<directive>, ...]}
The only action available on this system is:
{"task_id": "<same id>", "step": <1, 2, ...>, "tier": 2, "action": "pipe", "target": "/usr/bin/tr",
 "params": {"args": [<tr arguments, strings>], "stdin": "<text>" or "$N" for step N's output},
 "validation": {"expected_role": null, "precondition_state": {"path_exists": "/usr/bin/tr"},
                "expected_postcondition": {"output": "<exact expected stdout>"}}}
The postcondition is checked byte for byte against the real output, so predict it exactly.
If the request cannot be done with this action, reply {"task_id": "unsupported", "unsupported": "<why>", "directives": []}."#;
const MAX_REQUEST: u64 = 4096;

/// Safe inside a quoted curl config value: no quote, backslash, space or newline can break out of it.
fn config_safe(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

/// One generateContent call via curl, a capped child like any other (step cap, emergency stop). The key goes in
/// curl's config on stdin, never in argv or a file. At most two rounds over the models.
fn gemini(key: &str, models: &str, contents: &Value) -> Res<Value> {
    let req = json!({"systemInstruction": {"parts": [{"text": PLANNER_PROMPT}]}, "contents": contents,
                     "generationConfig": {"responseMimeType": "application/json"}});
    let body = Path::new("/run/agentd/request.json");
    put(body, &serde_json::to_vec(&req)?, 0o600)?;
    let mut last = String::new();
    for round in 0..2 {
        if round > 0 {
            sleep(Duration::from_secs(2));
        }
        for model in models.split(',') {
            let cfg = format!("url = \"{GEMINI_URL}/{model}:generateContent\"\nheader = \"x-goog-api-key: {key}\"\n\
                header = \"Content-Type: application/json\"\ndata-binary = \"@{}\"\nmax-time = 25\nsilent\nshow-error\n", body.display());
            match run_capped(&["/usr/bin/curl", "-K", "-"], &cfg).and_then(|o| Ok(serde_json::from_str::<Value>(&o)?)) {
                Ok(r) if r.get("error").is_none() => return Ok(r),
                Ok(r) => last = format!("{model}: HTTP {}: {}", r["error"]["code"], r["error"]["message"].as_str().unwrap_or_default()),
                Err(e) => last = format!("{model}: {e}"),
            }
        }
    }
    Err(format!("planner unavailable: {last}").into())
}

/// Telemetry to the journal and to the requesting client; a client that hangs up does not stop the task.
struct Tee<'a>(&'a mut File, &'a mut UnixStream);

impl Write for Tee<'_> {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        let _ = self.1.write_all(b);
        self.0.write_all(b)?;
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()
    }
}

/// Service mode: one request per connection on SOCK, one task at a time, planned live. A planner or task failure
/// fails that task only; the daemon keeps serving.
fn serve() -> Res<()> {
    let mut log = File::from(std::io::stdout().as_fd().try_clone_to_owned()?); // journald under systemd
    let model = std::env::var("AGENTD_MODEL").unwrap_or_else(|_| MODEL_DEFAULT.into());
    if !model.split(',').all(config_safe) {
        return Err(format!("bad AGENTD_MODEL {model:?}").into());
    }
    let key = std::env::var("GEMINI_API_KEY").ok().filter(|k| config_safe(k));
    let _ = fs::remove_file(SOCK);
    let listener = UnixListener::bind(SOCK)?;
    fs::set_permissions(SOCK, fs::Permissions::from_mode(0o600))?;
    emit(&mut log, "AGENTD_READY", &[("pid", json!(std::process::id())), ("socket", json!(SOCK)), ("model", json!(model)),
                                     ("planner", json!(if key.is_some() { "live" } else { "unavailable" }))]);
    for conn in listener.incoming() {
        let Ok(mut c) = conn else { continue };
        let _ = c.set_read_timeout(Some(Duration::from_secs(5)));
        let mut intent = String::new();
        let _ = BufReader::new((&c).take(MAX_REQUEST)).read_line(&mut intent);
        let intent = intent.trim().to_string();
        let mut out = Tee(&mut log, &mut c);
        let r = match &key {
            _ if intent.is_empty() => Err("empty request".into()),
            None => Err("planner unavailable: no valid GEMINI_API_KEY (set it in /etc/agentd/gemini.env)".into()),
            Some(k) => {
                let mut contents = vec![json!({"role": "user", "parts": [{"text": intent}]})];
                workflow(&mut out, &json!(intent), &json!(model), "live", |reason| {
                    if let Some(r) = reason {
                        contents.push(json!({"role": "user", "parts": [{"text": format!(
                            "That step failed: {r}. Reply with directives that replace only the failed step (same task_id and step).")}]}));
                    }
                    let r = gemini(k, &model, &json!(contents));
                    if let Ok(v) = &r {
                        contents.push(v["candidates"][0]["content"].clone());
                    }
                    Some(r)
                })
            }
        };
        if let Err(e) = r {
            emit(&mut out, "TASK_COMPLETE", &[("status", json!("fail")), ("error", json!(e.to_string()))]);
        }
    }
    Ok(())
}

/// Sends one request to the service and prints its telemetry. Returns whether the task succeeded.
fn ask(req: &str) -> Res<bool> {
    let mut c = wait_for("agentd socket", 5, || UnixStream::connect(SOCK).ok())?;
    writeln!(c, "{}", req.replace('\n', " "))?;
    let mut ok = false;
    for line in BufReader::new(c).lines() {
        let line = line?;
        println!("{line}");
        if let Ok(v) = serde_json::from_str::<Value>(&line) && v["event"] == "TASK_COMPLETE" {
            ok = v["status"] == "success";
        }
    }
    Ok(ok)
}

fn main() {
    unsafe { libc::signal(libc::SIGUSR1, on_sigusr1 as *const () as libc::sighandler_t) };
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("serve") => {
            let e = serve().err().map_or("listener closed".into(), |e| e.to_string());
            eprintln!("agentd: {e}");
            std::process::exit(1);
        }
        Some("ask") => std::process::exit(match ask(&args[2..].join(" ")) {
            Ok(ok) => if ok { 0 } else { 1 },
            Err(e) => { eprintln!("agentd: {e}"); 2 }
        }),
        _ => {}
    }
    let dev = std::env::var("AGENT_TTY").unwrap_or_else(|_| "/dev/ttyS0".into()); // set by agent-init's kernel cmdline
    let mut tty = OpenOptions::new().append(true).open(&dev).expect("open telemetry tty");
    let session = [format!("{RUNTIME}/bus"), format!("{RUNTIME}/wayland-0")];
    if let Err(e) = wait_for("session sockets", 10, || session.iter().all(|p| Path::new(p).exists()).then_some(())) {
        let _ = writeln!(tty, "# agentd: {e}"); // non-JSON: gates ignore it
        std::process::exit(1);
    }
    emit(&mut tty, "AGENTD_READY", &[("pid", json!(std::process::id())), ("bus", json!(session[0])), ("wayland", json!(session[1]))]);

    let tiers: [(u8, &str, f64, fn() -> Res<Proof>); 3] = [
        (1, "ffi_compute", 1.0, tier1),
        (2, "headless_pipe", 50.0, tier2),
        (3, "atspi_ui", 20.0, tier3),
    ];
    let mut ok_all = true;
    for (tier, primitive, budget, run) in tiers {
        let mut f = vec![("tier", json!(tier)), ("primitive", json!(primitive))];
        let ok = match run() {
            Ok((expected, actual, lat)) => {
                let ok = expected == actual;
                f.extend([("status", json!(if ok { "ok" } else { "fail" })), ("expected", expected), ("actual", actual),
                          ("latency_ms", json!(lat)), ("budget_ms", json!(budget))]);
                emit(&mut tty, "CAPABILITY_VERIFIED", &f);
                if ok && lat <= budget {
                    emit(&mut tty, &format!("TIER{tier}_PASS"), &[("primitive", json!(primitive)), ("latency_ms", json!(lat)), ("budget_ms", json!(budget))]);
                }
                ok && lat <= budget
            }
            Err(e) => {
                f.extend([("status", json!("fail")), ("error", json!(e.to_string()))]);
                emit(&mut tty, "CAPABILITY_VERIFIED", &f);
                false
            }
        };
        ok_all &= ok;
    }
    ok_all &= match screencopy() {
        Ok((frames, fps)) => {
            emit(&mut tty, "INTERACTION_CYCLE_VERIFIED", &[("primitive", json!("screencopy")), ("status", json!(if fps >= 10.0 { "ok" } else { "fail" })),
                                                            ("frames", json!(frames)), ("fps", json!(fps)), ("budget_fps", json!(10.0))]);
            fps >= 10.0
        }
        Err(e) => {
            emit(&mut tty, "INTERACTION_CYCLE_VERIFIED", &[("primitive", json!("screencopy")), ("status", json!("fail")), ("error", json!(e.to_string()))]);
            false
        }
    };
    if Path::new(PLAN).exists() {
        ok_all &= replay(&mut tty).unwrap_or_else(|e| {
            emit(&mut tty, "TASK_COMPLETE", &[("status", json!("fail")), ("error", json!(e.to_string()))]);
            false
        });
    }
    if Path::new(PACKAGES).exists() {
        ok_all &= lifecycle(&mut tty).unwrap_or_else(|e| {
            emit(&mut tty, "TASK_COMPLETE", &[("task_id", json!(LIFECYCLE_TASK)), ("status", json!("fail")), ("error", json!(e.to_string()))]);
            false
        });
    }
    std::process::exit(if ok_all && !STOPPED.load(SeqCst) { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("agentd-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    /// A one-response plan from directive objects (task "x").
    fn plan(ds: Value) -> Value {
        json!({"candidates": [{"content": {"parts": [{"text": json!({"task_id": "x", "directives": ds}).to_string()}]}}]})
    }

    #[test]
    fn fixture_parses_and_schema_is_enforced() {
        let fx: Value = serde_json::from_str(include_str!("../../tests/fixtures/gemini_plan.json")).unwrap();
        let (task, plan0) = parse_response(&fx["responses"][0]).unwrap();
        assert_eq!(plan0.iter().map(|d| (d.step, d.tier)).collect::<Vec<_>>(), [(1, 3), (2, 2), (3, 1)]);
        let (t, fix) = parse_response(&fx["responses"][1]).unwrap();
        assert!(t == task && fix[0].step == 1 && fix[0].expected_role.as_deref() == Some("text"));
        let outs = HashMap::from([(1, json!("hi"))]);
        assert_eq!(param(&fix[0], "text", &outs).unwrap(), "hello agentos");
        assert_eq!(param(&plan0[1], "stdin", &outs).unwrap(), "hi");
        assert!(param(&plan0[2], "input", &outs).is_err(), "unverified step reference must fail");

        let ok = |step: u64| json!({"task_id": "x", "step": step, "tier": 2, "action": "pipe", "target": "/usr/bin/tr",
            "params": {"args": ["a-z", "A-Z"], "stdin": "hi"}, "validation": {"expected_postcondition": {"output": "HI"}}});
        assert!(parse_response(&plan(json!([ok(1), ok(2)]))).is_ok());
        let bad = |edit: &dyn Fn(&mut Value)| { let mut d = ok(2); edit(&mut d); plan(json!([ok(1), d])) };
        let cases: [(&str, &dyn Fn(&mut Value)); 15] = [
            ("tier/action mismatch", &|d| d["action"] = json!("set_text")),
            ("non-allow-listed executable", &|d| d["target"] = json!("/bin/sh")),
            ("allow-listed name via another path", &|d| d["target"] = json!("/usr/bin/../bin/tr")),
            ("non-string arg", &|d| d["params"]["args"] = json!(["a-z", 5])),
            ("missing stdin", &|d| d["params"].as_object_mut().unwrap().clear()),
            ("forward reference", &|d| d["params"]["stdin"] = json!("$3")),
            ("self reference", &|d| d["params"]["stdin"] = json!("$2")),
            ("duplicate step", &|d| d["step"] = json!(1)),
            ("step 0", &|d| d["step"] = json!(0)),
            ("no postcondition output", &|d| d["validation"]["expected_postcondition"] = json!({})),
            ("unknown state", &|d| d["validation"]["precondition_state"] = json!({"states": ["editable", "bogus"]})),
            ("unknown precondition", &|d| d["validation"]["precondition_state"] = json!({"shell": "true"})),
            ("non-string role", &|d| d["validation"]["expected_role"] = json!(3)),
            ("ffi lib path traversal", &|d| *d = json!({"task_id": "x", "step": 2, "tier": 1, "action": "ffi_call",
                "target": "/run/agentd/../../tmp/evil.so", "params": {"symbol": "tier1_fnv1a", "input": "a"},
                "validation": {"expected_postcondition": {"output": 1}}})),
            ("empty UI target", &|d| *d = json!({"task_id": "x", "step": 2, "tier": 3, "action": "set_text", "target": "",
                "params": {"text": "a"}, "validation": {"expected_postcondition": {"output": "a"}}})),
        ];
        for (why, edit) in cases {
            assert!(parse_response(&bad(edit)).is_err(), "{why} must be rejected");
        }
        let ffi_sym = json!([{"task_id": "x", "step": 1, "tier": 1, "action": "ffi_call", "target": FFI_LIB,
            "params": {"symbol": "tier1_fib", "input": "a"}, "validation": {"expected_postcondition": {"output": 1}}}]);
        assert!(parse_response(&plan(ffi_sym)).is_err(), "non-allow-listed symbol must be rejected");
        assert!(ffi("/run/agentd/../../tmp/evil.so", "tier1_fnv1a", "").is_err(), "runtime check must hold too");
        let declined = json!({"candidates": [{"content": {"parts": [{"text":
            r#"{"task_id": "unsupported", "unsupported": "no such action", "directives": []}"#}]}}]});
        assert!(parse_response(&declined).err().unwrap().to_string().contains("no such action"), "an empty plan is never a success");
    }

    #[test]
    fn curl_config_values_cannot_break_out() {
        assert!(config_safe("AQ.Ab8-x_y") && config_safe("gemini-3.8-flash"));
        for bad in ["", "a\"\nurl = \"http://evil", "a b", "a\\", "k\nheader"] {
            assert!(!config_safe(bad), "{bad:?}");
        }
    }

    #[test]
    fn rollback_restores_prior_state_and_dst_is_confined() {
        let d = tmpdir("rb");
        let (old, new, txn) = (d.join("reg.json"), d.join("bin/cap"), d.join("txn"));
        put(&old, b"before", 0o644).unwrap();
        let mut j = Journal::new();
        staged_put(&mut j, &txn, &new, b"payload", 0o755).unwrap();
        staged_put(&mut j, &txn, &old, b"after", 0o600).unwrap();
        rollback(&j).unwrap();
        assert!(!new.exists());
        assert_eq!(snapshot(&old), Some((b"before".to_vec(), 0o644)));
        fs::remove_dir_all(&d).unwrap();
        assert!(dst_allowed(Path::new("/usr/local/bin/x")) && dst_allowed(Path::new("/opt/x/y")));
        for bad in ["/usr/local/bin", "/usr/local/bin/../../bin/sh", "/usr/bin/x", "/opt", "usr/local/bin/x"] {
            assert!(!dst_allowed(Path::new(bad)), "{bad}");
        }
    }

    #[test]
    fn crash_mid_transaction_is_rolled_back_at_next_start() {
        let d = tmpdir("crash");
        let (old, new, txn) = (d.join("reg.json"), d.join("bin/cap"), d.join("txn"));
        put(&old, b"before", 0o640).unwrap();
        put(&txn.join("package"), b"cap", 0o600).unwrap();
        let mut j = Journal::new();
        staged_put(&mut j, &txn, &new, b"payload", 0o755).unwrap();
        staged_put(&mut j, &txn, &old, b"after", 0o644).unwrap();
        fs::write(tmp_of(&old), b"half-written").unwrap();
        drop(j); // the process dies here: only the on-disk journal is left
        let (pkg, rec) = recover(&txn).unwrap().expect("open transaction");
        assert_eq!((pkg.as_str(), rec.len()), ("cap", 2));
        assert!(!new.exists() && !tmp_of(&old).exists() && !txn.exists());
        assert_eq!(snapshot(&old), Some((b"before".to_vec(), 0o640)));
        assert!(recover(&txn).unwrap().is_none(), "nothing left to recover");

        // Rolled-back registry check: a failed upgrade keeps the old entry, a failed new install leaves none.
        let reg = d.join("registry.json");
        put(&reg, br#"{"old": {"files": []}}"#, 0o644).unwrap();
        for (name, keep) in [("old", true), ("new", false)] {
            let mut j = Journal::new();
            staged_put(&mut j, &txn, &reg, format!(r#"{{"old": {{"files": []}}, "{name}": {{"files": ["x"]}}}}"#).as_bytes(), 0o644).unwrap();
            assert_eq!(registry_restored(&j, &reg, name), keep, "{name}: before rollback");
            rollback(&j).unwrap();
            assert!(registry_restored(&j, &reg, name), "{name}");
            assert_eq!(read_registry(&reg).unwrap().contains_key(name), keep);
            end_txn(&txn).unwrap();
        }
        assert!(registry_restored(&Journal::new(), &reg, "old"), "untouched registry");
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn registry_and_package_files_are_validated() {
        let d = tmpdir("reg");
        let reg = d.join("registry.json");
        assert!(read_registry(&reg).unwrap().is_empty(), "missing = empty");
        fs::write(&reg, b"{not json").unwrap();
        assert!(read_registry(&reg).is_err(), "corrupt registry must not be silently replaced");
        fs::write(&reg, b"[]").unwrap();
        assert!(read_registry(&reg).is_err(), "non-object registry must not panic on insert");
        fs::write(&reg, br#"{"a": {"files": ["/nonexistent/x"]}, "b": {"files": []}}"#).unwrap();
        assert_eq!(installed(&read_registry(&reg).unwrap()), ["b"]);

        let stage = d.join("stage");
        fs::create_dir_all(stage.join("bin")).unwrap();
        fs::write(stage.join("bin/ok"), b"x").unwrap();
        std::os::unix::fs::symlink(&reg, stage.join("bin/link")).unwrap();
        std::os::unix::fs::symlink("/", stage.join("up")).unwrap();
        assert!(package_src(&stage, "bin/ok").is_ok());
        for bad in ["bin/link", "up/etc/passwd", "../registry.json", "/etc/passwd", "bin"] {
            assert!(package_src(&stage, bad).is_err(), "{bad}");
        }
        let files = [PathBuf::from("/usr/local/bin/cap")];
        assert!(verify_argv(&json!({"verify": {"argv": ["/usr/local/bin/cap", "--selftest"]}}), &files).is_ok());
        assert!(verify_argv(&json!({"verify": {"argv": ["/bin/rm", "-rf", "/data"]}}), &files).is_err());
        assert!(verify_argv(&json!({"verify": {"argv": ["/usr/local/bin/cap", 1]}}), &files).is_err());
        fs::remove_dir_all(&d).unwrap();
    }

    /// One test, because STOPPED is process-wide and it ends by setting it.
    #[test]
    fn child_processes_are_capped_and_stoppable() {
        let alive = |pid: i32| unsafe { libc::kill(pid, 0) } == 0
            && fs::read_to_string(format!("/proc/{pid}/stat")).is_ok_and(|s| !s.contains(") Z"));
        let big = "x".repeat(300_000); // larger than a pipe buffer both ways
        assert_eq!(run_capped(&["/bin/cat"], &big).unwrap(), big);
        let t = Instant::now();
        let out = run_capped(&["/bin/sh", "-c", "sleep 100 & echo $!"], "").unwrap();
        let grandchild: i32 = out.trim().parse().unwrap();
        assert!(t.elapsed() < Duration::from_millis(900), "a background grandchild must not hold the step open");
        sleep(Duration::from_millis(100));
        assert!(!alive(grandchild), "grandchild must be killed with the group");
        let t = Instant::now();
        assert!(run_capped(&["/bin/sleep", "100"], "").unwrap_err().to_string().contains("timed out"));
        assert!(t.elapsed() < STEP_TIMEOUT + Duration::from_millis(500));
        assert!(run_capped(&["/bin/sh", "-c", "exit 3"], "").is_err());
        assert_eq!(run_capped(&["/usr/bin/env"], "").unwrap(), "PATH=/usr/bin:/bin\n", "children get a minimal env");
        // Regression: grim needs the Wayland socket (screencopy failed once env was cleared); only it gets it.
        assert_eq!(run_capped_env(&["/usr/bin/env"], "", WAYLAND_ENV).unwrap(),
                   "PATH=/usr/bin:/bin\nWAYLAND_DISPLAY=wayland-0\nXDG_RUNTIME_DIR=/run/user/0\n");

        unsafe { libc::signal(libc::SIGUSR1, on_sigusr1 as *const () as libc::sighandler_t) };
        std::thread::spawn(|| { sleep(Duration::from_millis(200)); unsafe { libc::kill(libc::getpid(), libc::SIGUSR1) }; });
        let t = Instant::now();
        assert_eq!(run_capped(&["/bin/sleep", "100"], "").unwrap_err().to_string(), STOP_MSG);
        assert!(t.elapsed() < Duration::from_millis(600), "emergency stop must kill the running child at once");
        assert!(run_capped(&["/bin/true"], "").is_err() && ffi(FFI_LIB, "tier1_fnv1a", "").is_err(), "no actuation after stop");
    }
}
