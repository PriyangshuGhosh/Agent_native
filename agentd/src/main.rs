//! agentd: the CUA-AgentOS agent runtime, run by agent-init as its final workload.
//! Cycle 04: waits for the session, proves each capability tier once, reports JSON lines on ttyS0
//! (contract: tests/gate-04.sh) and exits; agent-init powers off when it does.
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};
use zbus::blocking::{Connection, connection::Builder};
use zbus::zvariant::{DynamicType, OwnedObjectPath, OwnedValue};

type Res<T> = Result<T, Box<dyn std::error::Error>>;
/// An AT-SPI accessible: (bus name, object path).
type Node = (String, OwnedObjectPath);

const RUNTIME: &str = "/run/user/0";
const ACC: &str = "org.a11y.atspi.Accessible";

fn now_ms() -> i64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut ts) };
    ts.tv_sec * 1000 + ts.tv_nsec / 1_000_000
}

fn emit(tty: &mut File, event: &str, fields: &[(&str, Value)]) {
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

/// Each tier returns (expected, actual, latency in ms of the timed part).
type Proof = (Value, Value, f64);

/// Tier 1: dlopen a bundled .so from tmpfs and call into it in-process.
fn tier1() -> Res<Proof> {
    fs::create_dir_all("/run/agentd")?;
    fs::copy("/usr/lib/agentd/libtier1.so", "/run/agentd/libtier1.so")?;
    let t = Instant::now();
    let out = unsafe {
        let lib = libloading::Library::new("/run/agentd/libtier1.so")?;
        let fib: libloading::Symbol<unsafe extern "C" fn(u32) -> u64> = lib.get(b"tier1_fib")?;
        fib(50)
    };
    Ok((json!(12586269025u64), json!(out), ms(t)))
}

/// Tier 2: a headless child transforms data over stdin/stdout pipes.
fn tier2() -> Res<Proof> {
    let (input, want) = ("agentd tier2 pipe\n", "AGENTD TIER2 PIPE\n");
    let t = Instant::now();
    let mut child = Command::new("/usr/bin/tr")
        .args(["a-z", "A-Z"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    child.stdin.take().ok_or("no stdin")?.write_all(input.as_bytes())?; // dropped here: EOF to tr
    let mut out = String::new();
    child.stdout.take().ok_or("no stdout")?.read_to_string(&mut out)?;
    let st = child.wait()?;
    let lat = ms(t);
    if !st.success() {
        return Err(format!("tr exited {st}").into());
    }
    Ok((json!(want), json!(out), lat))
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

/// Tier 3: set mousepad's text over AT-SPI (no pixels, no input events) and read it back.
fn tier3() -> Res<Proof> {
    let session = Connection::session()?;
    let addr: String = wait_for("AT-SPI bus", 10, || {
        call(&session, &("org.a11y.Bus".into(), "/org/a11y/bus".try_into().ok()?), "org.a11y.Bus", "GetAddress", &())
            .ok()?.body().deserialize().ok()
    })?;
    let a11y = Builder::address(addr.as_str())?.build()?;
    let root: Node = ("org.a11y.atspi.Registry".into(), "/org/a11y/atspi/accessible/root".try_into()?);
    let app = wait_for("mousepad on AT-SPI", 30, || {
        children(&a11y, &root).into_iter().find(|k| name(&a11y, k).is_some_and(|s| s.to_lowercase().contains("mousepad")))
    })?;
    let text = wait_for("mousepad text widget", 30, || find_text(&a11y, &app))?;

    let want = "agentd-tier3";
    let read = || -> Res<String> { Ok(call(&a11y, &text, "org.a11y.atspi.Text", "GetText", &(0i32, -1i32))?.body().deserialize()?) };
    let t = Instant::now();
    call(&a11y, &text, "org.a11y.atspi.EditableText", "SetTextContents", &(want,))?;
    let mut got = read()?;
    // The widget may apply the edit a little later; the extra wait is counted in the latency.
    let settle = Instant::now() + Duration::from_secs(5);
    while got != want && Instant::now() < settle {
        sleep(Duration::from_millis(5));
        got = read()?;
    }
    Ok((json!(want), json!(got), ms(t)))
}

fn ms(t: Instant) -> f64 {
    (t.elapsed().as_secs_f64() * 1e6).round() / 1e3
}

fn main() {
    let mut tty = OpenOptions::new().write(true).open("/dev/ttyS0").expect("open /dev/ttyS0");
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
    std::process::exit(if ok_all { 0 } else { 1 });
}
