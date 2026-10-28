//! agentd: the CUA-AgentOS agent runtime, run by agent-init as its final workload.
//! Cycle 04: waits for the session, proves each capability tier once (contract: tests/gate-04.sh).
//! Cycle 05: if a recorded plan is bundled, runs it through the cognitive loop (contract: tests/gate-05.sh).
//! Reports JSON lines on ttyS0 and exits; agent-init powers off when it does.
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::ffi::OsStr;
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
    let want = "AGENTD TIER2 PIPE\n";
    let (out, lat) = pipe("/usr/bin/tr", &["a-z", "A-Z"], "agentd tier2 pipe\n")?;
    Ok((json!(want), json!(out), lat))
}

/// Runs `cmd args` with `input` on stdin; returns (stdout, latency ms).
fn pipe<S: AsRef<OsStr>>(cmd: &str, args: &[S], input: &str) -> Res<(String, f64)> {
    let t = Instant::now();
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    child.stdin.take().ok_or("no stdin")?.write_all(input.as_bytes())?; // dropped here: EOF to tr
    let mut out = String::new();
    child.stdout.take().ok_or("no stdout")?.read_to_string(&mut out)?;
    let st = child.wait()?;
    let lat = ms(t);
    if !st.success() {
        return Err(format!("{cmd} exited {st}").into());
    }
    Ok((out, lat))
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
    let session = Connection::session()?;
    let addr: String = wait_for("AT-SPI bus", 10, || {
        call(&session, &("org.a11y.Bus".into(), "/org/a11y/bus".try_into().ok()?), "org.a11y.Bus", "GetAddress", &())
            .ok()?.body().deserialize().ok()
    })?;
    let a11y = Builder::address(addr.as_str())?.build()?;
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

/// SetTextContents, then the widget's text as read back.
fn set_text(a11y: &Connection, text: &Node, want: &str) -> Res<String> {
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
    let ds = body["directives"].as_array().ok_or("plan has no directives")?.iter().map(|d| -> Res<Directive> {
        let v = &d["validation"];
        let d = Directive {
            task_id: s(d, "task_id")?,
            step: d["step"].as_u64().ok_or("directive has no step")?,
            tier: d["tier"].as_u64().ok_or("directive has no tier")?,
            action: s(d, "action")?,
            target: s(d, "target")?,
            params: d["params"].clone(),
            expected_role: v["expected_role"].as_str().map(String::from),
            pre: v["precondition_state"].clone(),
            post: v["expected_postcondition"].clone(),
        };
        let tier_ok = matches!((d.tier, d.action.as_str()), (3, "set_text") | (2, "pipe") | (1, "ffi_call"));
        if d.task_id != task || !tier_ok || !d.params.is_object() || !d.post.is_object() {
            return Err(format!("step {}: directive off schema", d.step).into());
        }
        Ok(d)
    }).collect::<Res<Vec<_>>>()?;
    Ok((task, ds))
}

/// A string param; "$N" stands for step N's verified output.
fn param(d: &Directive, k: &str, outs: &HashMap<u64, Value>) -> Res<String> {
    let v = &d.params[k];
    let v = match v.as_str().and_then(|s| s.strip_prefix('$')).and_then(|n| n.parse().ok()) {
        Some(n) => outs.get(&n).ok_or(format!("{k} refers to unverified step {n}"))?,
        None => v,
    };
    Ok(v.as_str().ok_or(format!("param {k} is not a string"))?.to_string())
}

/// Tier 1: calls an allow-listed `u32 sym(const u8 *, usize)` from a library on agentd's tmpfs, in-process.
fn ffi(lib: &str, sym: &str, input: &str) -> Res<u32> {
    if !lib.starts_with("/run/agentd/") || !FFI_ALLOW.contains(&sym) {
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
                let args: Vec<&str> = d.params["args"].as_array().ok_or("params.args missing")?.iter().filter_map(Value::as_str).collect();
                json!(pipe(&d.target, &args, &param(d, "stdin", outs)?)?.0)
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

/// Cognitive loop over recorded Gemini responses: [0] is the plan, each replan consumes the next one,
/// whose directives replace the failed step. Returns task success.
fn workflow(tty: &mut File) -> Res<bool> {
    let fx: Value = serde_json::from_slice(&fs::read(PLAN)?)?;
    let mut responses = fx["responses"].as_array().ok_or("fixture has no responses")?.iter();
    let (task, plan) = parse_response(responses.next().ok_or("fixture has no plan")?)?;
    let mut plan = VecDeque::from(plan);
    let tid = || ("task_id", json!(task));
    emit(tty, "TASK_START", &[tid(), ("intent", fx["intent"].clone()), ("model", fx["model"].clone()),
                               ("steps", json!(plan.len())), ("source", json!("recorded"))]);
    let (mut outs, mut ui, mut repairs, mut err) = (HashMap::new(), None, 0, None);
    while let Some(d) = plan.pop_front() {
        match run_step(&d, &mut ui, &outs) {
            Ok((out, lat)) => {
                emit(tty, "STEP_VERIFIED", &[tid(), ("step", json!(d.step)), ("tier", json!(d.tier)), ("action", json!(d.action)),
                                             ("status", json!("ok")), ("output", out.clone()), ("latency_ms", json!(lat))]);
                outs.insert(d.step, out);
            }
            Err(reason) => {
                repairs += 1;
                if repairs > REPAIR_BUDGET {
                    err = Some(format!("repair budget exhausted; last: {reason}"));
                    break;
                }
                emit(tty, "REPLAN_TRIGGERED", &[tid(), ("step", json!(d.step)), ("tier", json!(d.tier)), ("reason", json!(reason)),
                                                ("attempt", json!(repairs)), ("budget", json!(REPAIR_BUDGET))]);
                match responses.next().map(parse_response) {
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
    if Path::new(PLAN).exists() {
        ok_all &= workflow(&mut tty).unwrap_or_else(|e| {
            emit(&mut tty, "TASK_COMPLETE", &[("status", json!("fail")), ("error", json!(e.to_string()))]);
            false
        });
    }
    std::process::exit(if ok_all { 0 } else { 1 });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_parses_and_schema_is_enforced() {
        let fx: Value = serde_json::from_str(include_str!("../../tests/fixtures/gemini_plan.json")).unwrap();
        let (task, plan) = parse_response(&fx["responses"][0]).unwrap();
        assert_eq!(plan.iter().map(|d| (d.step, d.tier)).collect::<Vec<_>>(), [(1, 3), (2, 2), (3, 1)]);
        let (t, fix) = parse_response(&fx["responses"][1]).unwrap();
        assert!(t == task && fix[0].step == 1 && fix[0].expected_role.as_deref() == Some("text"));
        let bad = json!({"candidates": [{"content": {"parts": [{"text": json!({"task_id": "x", "directives": [
            {"task_id": "x", "step": 1, "tier": 1, "action": "set_text", "target": "t", "params": {}, "validation": {"expected_postcondition": {}}}
        ]}).to_string()}]}}]});
        assert!(parse_response(&bad).is_err(), "tier/action mismatch must be rejected");
        let outs = HashMap::from([(1, json!("hi"))]);
        assert_eq!(param(&fix[0], "text", &outs).unwrap(), "hello agentos");
        assert_eq!(param(&plan[1], "stdin", &outs).unwrap(), "hi");
        assert!(param(&plan[2], "input", &outs).is_err(), "unverified step reference must fail");
    }
}
