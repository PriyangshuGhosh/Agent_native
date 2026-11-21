//! Goal 6, model routing: the cheapest planner that can do the job answers. In order:
//! 1. `fixed`: known requests ("disk space", "restart cron") become a plan with no model at all;
//! 2. a local model (< 3B, on loopback) that only *classifies* the request into one line from a closed set
//!    (`parse_line`); agentd builds the plan itself, as for known requests. Measured on the AI HAT+ 2 (Hailo-10H,
//!    qwen2.5-instruct:1.5b, 2026-11-18): it cannot be trusted to write our JSON plans (0/2 valid) and picked a wrong
//!    *modifying* action ("set the ntp server" -> restart), so it may only chat, read, and ask a service's status.
//!    The server is OpenAI-compatible when AGENTD_LOCAL_URL ends in /v1 (llama-server), else Ollama's /api/chat
//!    (hailo-ollama: the model runs on the HAT and its own 8 GB, so the Pi's RAM stays with the desktop);
//! 3. Gemini for anything else: apps, `learn`, the shell, installs, settings, restarts, and every repair.
//! Every tier's answer is the same Gemini-shaped response and goes through the same parse_response /
//! check_directive / verification / broker and runner approvals, so permissions never depend on the tier.
use super::{Res, emit, gemini, run_group};
use serde_json::{Value, json};
use std::io::Write;
use std::path::Path;
use std::time::{Duration, Instant};

/// Answers on the HAT took 1.4-4.5 s with the token cap; 30 s means something is wrong, and Gemini takes over.
const LOCAL_WAIT: Duration = Duration::from_secs(30);
/// One line is all we read; without a cap a 1.5B model rambled for 21 s.
const LOCAL_TOKENS: u32 = 40;

/// Model: qwen2:1.5b handled the most on the HAT (14/22 local requests, 0 wrong after the checks, median 1.3 s;
/// docs/hailo-2026-11-18.md). Sent as the user message: on hailo-ollama the model followed instructions there far better than in a system message
/// (measured: 4/12 vs 1/12 lines in the format).
const LOCAL_PROMPT: &str = "You route requests for the agent of a Linux computer. Answer with exactly one line, nothing else:
CHAT: <a short, friendly answer>   - for greetings, small talk, or a general question you can answer without this computer
READ <what>                        - to show this computer's: time, kernel, disk, uptime, memory
SERVICE status <unit>              - is one of these services running: cron, timesyncd, networkmanager
ESCALATE                           - for anything else, or if you are not sure
Examples:
hello -> CHAT: Hello! How can I help?
how much space is left on my drive -> READ disk
what's the time -> READ time
is the wifi service up -> SERVICE status networkmanager
please restart cron -> ESCALATE
create a document about cats in libreoffice -> ESCALATE
install vlc -> ESCALATE";

pub struct Router {
    /// (endpoint base, model name) of the local server.
    pub local: Option<(String, String)>,
    pub key: Option<String>,
    pub models: String,
}

impl Router {
    /// AGENTD_LOCAL_URL (http://127.0.0.1:8080/v1 = OpenAI style; http://127.0.0.1:8000 = Ollama style) +
    /// AGENTD_LOCAL_MODEL; GEMINI_API_KEY + AGENTD_MODEL.
    pub fn from_env(models: String, key: Option<String>) -> Res<Router> {
        let local = match std::env::var("AGENTD_LOCAL_URL") {
            Ok(u) if !u.is_empty() => {
                let m = std::env::var("AGENTD_LOCAL_MODEL").unwrap_or_else(|_| "local".into());
                // The name goes only in the JSON body; ':' is Ollama's tag separator (qwen2:1.5b).
                if !local_url_ok(&u) || m.is_empty() || !m.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-:".contains(&b)) {
                    return Err(format!("bad AGENTD_LOCAL_URL/AGENTD_LOCAL_MODEL {u:?} {m:?}: loopback http only").into());
                }
                Some((u.trim_end_matches('/').to_string(), m))
            }
            _ => None,
        };
        Ok(Router { local, key, models })
    }

    pub fn tiers(&self) -> String {
        let mut t = vec!["deterministic".to_string()];
        t.extend(self.local.as_ref().map(|(_, m)| format!("local:{m}")));
        t.extend(self.key.as_ref().map(|_| "gemini".to_string()));
        t.join(",")
    }

    /// A plan or chat reply for `contents` (its last entry is the person's request). `repair` = a step already
    /// failed: the local tier cannot repair, so that goes to Gemini. Without a key, anything beyond the local
    /// tier fails with nothing run.
    pub fn plan(&self, extra: &str, contents: &Value, repair: bool, note: &mut impl Write) -> Res<Value> {
        let mut why = if repair { "a step failed".to_string() } else { "no local model".to_string() };
        let request = contents.as_array().and_then(|c| c.last()).and_then(|c| c["parts"][0]["text"].as_str()).unwrap_or_default();
        if let Some((url, model)) = &self.local && !repair {
            match changes(request).map_or_else(|| local(url, model, request, note), |v| Err(format!("asks for a change ({v:?})").into())) {
                Ok(r) => {
                    emit(note, "PLANNER_ROUTE", &[("tier", json!("local")), ("model", json!(model))]);
                    return Ok(r);
                }
                Err(e) => why = e.to_string(),
            }
        }
        match &self.key {
            Some(k) => {
                emit(note, "PLANNER_ROUTE", &[("tier", json!("gemini")), ("reason", json!(why))]);
                gemini(k, &self.models, extra, contents, note)
            }
            None if self.local.is_some() => Err(format!("planner unavailable: this needs a more capable model than the local one ({why}), and no GEMINI_API_KEY is set").into()),
            None => Err("planner unavailable: no valid GEMINI_API_KEY (set it in /etc/agentd/gemini.env) and no local model".into()),
        }
    }
}

/// Loopback only: what the person types never leaves the machine on this tier. No quote/space/backslash, so the
/// value cannot break out of curl's config.
fn local_url_ok(u: &str) -> bool {
    ["http://127.0.0.1:", "http://localhost:", "http://[::1]:"].iter().any(|p| u.strip_prefix(p).is_some_and(|rest|
        rest.as_bytes().first().is_some_and(u8::is_ascii_digit) && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-/:".contains(&b))))
}

/// Asks the local model to classify `request`; returns the plan (or chat reply) agentd built from its one line.
fn local(url: &str, model: &str, request: &str, note: &mut impl Write) -> Res<Value> {
    let messages = json!([{"role": "user", "content": format!("{LOCAL_PROMPT}\n\nRequest: {request}\nAnswer (one line):")}]);
    let body = Path::new(if cfg!(test) { "/tmp/agentd-test-local.json" } else { "/run/agentd/local.json" });
    let openai = url.ends_with("/v1");
    let (req, path) = if openai {
        (json!({"model": model, "messages": messages, "temperature": 0, "max_tokens": LOCAL_TOKENS}), "/chat/completions")
    } else {
        (json!({"model": model, "messages": messages, "stream": false, "options": {"temperature": 0, "num_predict": LOCAL_TOKENS}}), "/api/chat")
    };
    super::put(body, &serde_json::to_vec(&req)?, 0o600)?;
    let cfg = format!("url = \"{url}{path}\"\nheader = \"Content-Type: application/json\"\ndata-binary = \"@{}\"\n\
        max-time = {}\nsilent\nshow-error\n", body.display(), LOCAL_WAIT.as_secs());
    let who = format!("local:{model}");
    emit(note, "PLANNER_TRY", &[("model", json!(who)), ("round", json!(1)), ("status", json!("asking"))]);
    let t = Instant::now();
    let r = (|| -> Res<String> {
        let (code, out, _) = run_group(&["/usr/bin/curl", "-K", "-"], &cfg, &[], LOCAL_WAIT + Duration::from_secs(5), false)?;
        if code != 0 {
            return Err(format!("curl exited with status {code}").into());
        }
        Ok(reply_text(&out, openai).ok_or("the local model gave no answer")?)
    })();
    let ms = t.elapsed().as_millis() as u64;
    match &r {
        Ok(_) => emit(note, "PLANNER_TRY", &[("model", json!(who)), ("status", json!("ok")), ("ms", json!(ms))]),
        Err(e) => emit(note, "PLANNER_TRY", &[("model", json!(who)), ("status", json!("failed")), ("ms", json!(ms)), ("reason", json!(format!("{who}: {e}")))]),
    }
    let plan = parse_line(&r?, &who)?;
    if let Some(chose) = plan["candidates"][0]["content"]["parts"][0]["text"].as_str().and_then(|t| serde_json::from_str::<Value>(t).ok())
        && let Some(d) = chose["directives"].get(0) && !about(request, d["target"].as_str().unwrap_or_default(), d["params"]["args"][0].as_str())
    {
        return Err(format!("the local model chose {} {}, which the request does not mention", d["target"], d["params"]["args"]).into());
    }
    Ok(plan)
}

/// Words that ask for a change: the local tier only looks, so such a request goes to Gemini without asking it.
fn changes(request: &str) -> Option<String> {
    const VERBS: [&str; 22] = ["set", "change", "restart", "reboot", "stop", "start", "install", "remove", "uninstall", "delete", "enable",
        "disable", "configure", "switch", "turn", "make", "create", "update", "upgrade", "edit", "write", "kill"];
    let r = request.to_lowercase();
    r.split(|c: char| !c.is_alphanumeric()).find(|w| VERBS.contains(w)).map(String::from)
}

/// Whether the request names what the local model chose (a 1.5B model on the HAT picked NetworkManager for "set the
/// ntp server"): a deterministic check on the model's choice, as every step's result is checked.
fn about(request: &str, target: &str, unit: Option<&str>) -> bool {
    let r = request.to_lowercase();
    let words: &[&str] = match (target, unit) {
        ("/usr/bin/date", _) => &["time", "date", "day", "clock"],
        ("/usr/bin/uname", _) => &["kernel", "uname", "version"],
        ("/usr/bin/df", _) => &["disk", "space", "storage", "drive"],
        ("/usr/bin/uptime", _) => &["uptime", "up", "long", "load", "boot"],
        ("/usr/bin/free", _) => &["memory", "ram"],
        (_, Some("cron.service")) => &["cron"],
        (_, Some("systemd-timesyncd.service")) => &["timesync", "time sync", "ntp", "clock sync"],
        (_, Some("NetworkManager.service")) => &["network", "wifi", "wi-fi", "internet"],
        _ => &[],
    };
    let tokens: Vec<&str> = r.split(|c: char| !c.is_alphanumeric() && c != '-').collect();
    // A phrase must appear as written; a word must be a whole word, or start one if it is long ("timesyncd", "networkmanager").
    let has = |w: &&str| if w.contains(' ') { r.contains(w) } else { tokens.iter().any(|t| t == w || (w.len() > 4 && t.starts_with(w))) };
    // A request about a service is never answered with a read ("is time sync working" -> READ time, on the HAT).
    const SERVICE_WORDS: [&str; 9] = ["service", "cron", "sync", "ntp", "network", "networkmanager", "wifi", "wi-fi", "daemon"];
    words.iter().any(has) && (unit.is_some() || !SERVICE_WORDS.iter().any(has))
}

/// The model's text from an OpenAI reply, an Ollama reply, or an Ollama stream (one JSON object per line), in case
/// a server ignores "stream": false.
fn reply_text(out: &str, openai: bool) -> Option<String> {
    if openai {
        return serde_json::from_str::<Value>(out).ok()?["choices"][0]["message"]["content"].as_str().map(String::from);
    }
    let parts: Vec<Value> = out.lines().filter(|l| !l.trim().is_empty()).map(serde_json::from_str).collect::<Result<_, _>>().ok()?;
    let t: String = parts.iter().filter_map(|p| p["message"]["content"].as_str()).collect();
    (!t.is_empty()).then_some(t)
}

/// The local model's one line -> a plan agentd builds itself. Anything not exactly in the contract escalates:
/// "ESCALATE", prose, commands, unknown tools or units, any modifying action.
fn parse_line(text: &str, who: &str) -> Res<Value> {
    // Formatting slips seen on the HAT ("READ time.", "SERVICE status: cron") are forgiven; nothing else is.
    let line = text.trim().lines().next().unwrap_or_default().trim().trim_matches('`').trim().trim_end_matches('.').trim();
    if let Some(reply) = line.strip_prefix("CHAT:").map(str::trim).filter(|r| !r.is_empty()) {
        let body = json!({"task_id": "chat", "reply": reply, "directives": []}).to_string();
        return Ok(json!({"modelVersion": who, "candidates": [{"content": {"role": "model", "parts": [{"text": body}]}}]}));
    }
    let w: Vec<&str> = line.split_whitespace().map(|x| if x == "status:" { "status" } else { x }).collect();
    match w.as_slice() {
        ["READ", what] => tool(&what.to_lowercase()).map(|t| one_step(who, &format!("read-{}", &t[9..]), "read", t, json!([]))),
        ["SERVICE", "status", u] => unit(&u.to_lowercase()).map(|u| service(who, "service.status", u)),
        _ => None,
    }.ok_or_else(|| if line.starts_with("ESCALATE") { "the local model handed it up".into() }
                    else { format!("the local model's answer is not in its contract: {:?}", line.chars().take(80).collect::<String>()).into() })
}

/// Read tool for a name the person or the local model may use.
fn tool(what: &str) -> Option<&'static str> {
    Some(match what {
        "time" | "date" => "/usr/bin/date",
        "kernel" => "/usr/bin/uname",
        "disk" | "storage" | "space" => "/usr/bin/df",
        "uptime" | "load" => "/usr/bin/uptime",
        "memory" | "ram" => "/usr/bin/free",
        _ => return None,
    })
}

fn unit(u: &str) -> Option<&'static str> {
    Some(match u {
        "cron" | "crond" => "cron.service",
        "timesyncd" | "systemd-timesyncd" | "time sync" | "ntp" => "systemd-timesyncd.service",
        "networkmanager" | "network manager" | "network" | "wifi" => "NetworkManager.service",
        _ => return None,
    })
}

fn service(who: &str, op: &str, u: &str) -> Value {
    one_step(who, &format!("{}-{}", op.replace('.', "-"), u.split('.').next().unwrap_or_default().to_lowercase()), "broker", op, json!([u]))
}

/// A one-step plan, Gemini-shaped, labelled with who chose it.
fn one_step(who: &str, task: &str, action: &str, target: &str, args: Value) -> Value {
    let d = json!({"task_id": task, "step": 1, "tier": 2, "action": action, "target": target, "params": {"args": args, "stdin": ""},
        "validation": {"expected_role": null, "precondition_state": {}, "expected_postcondition": {"output": ""}}});
    json!({"modelVersion": who, "candidates": [{"content": {"role": "model", "parts": [{"text":
        json!({"task_id": task, "directives": [d]}).to_string()}]}}]})
}

/// Known requests, planned with no model. Matching is on the whole normalized request, never a keyword inside it,
/// so "what is the date of the next release" is not "date".
pub fn fixed(intent: &str) -> Option<Value> {
    let words: String = intent.to_lowercase().chars().filter(|c| !"'\u{2019}".contains(*c)).map(|c| if c.is_alphanumeric() || c == '-' { c } else { ' ' }).collect();
    let mut w: Vec<&str> = words.split_whitespace().collect();
    const FILLER: [&str; 14] = ["please", "can", "could", "you", "show", "tell", "me", "what", "whats", "is", "the", "my", "check", "current"];
    while w.first().is_some_and(|x| FILLER.contains(x)) {
        w.remove(0);
    }
    while w.last().is_some_and(|x| ["please", "now"].contains(x)) {
        w.pop();
    }
    let s = w.join(" ");
    let what = match s.as_str() {
        "date" | "time" | "date and time" | "time and date" | "todays date" | "time is it" | "day is it" | "day is today" => "time",
        "disk space" | "free disk space" | "disk usage" | "free space" | "storage" | "disk" => "disk",
        "memory" | "ram" | "memory usage" | "free memory" | "free ram" => "memory",
        "uptime" | "load" | "system load" => "uptime",
        "kernel" | "kernel version" | "uname" | "system info" | "system information" => "kernel",
        _ => {
            let (op, u) = if let Some(u) = s.strip_prefix("restart ") {
                ("service.restart", u)
            } else if let Some(u) = s.strip_prefix("status of ").or_else(|| s.strip_suffix(" status")).or_else(|| s.strip_suffix(" running")) {
                ("service.status", u)
            } else {
                return None;
            };
            return Some(service("deterministic", op, unit(u.strip_suffix(" service").unwrap_or(u))?));
        }
    };
    let t = tool(what)?;
    Some(one_step("deterministic", &format!("read-{}", &t[9..]), "read", t, json!([])))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read};
    use std::net::TcpListener;

    fn step(r: &Value) -> (String, String, Value) {
        let (_, d) = super::super::parse_response(r).unwrap();
        (d[0].action.clone(), d[0].target.clone(), d[0].params["args"].clone())
    }

    #[test]
    fn known_requests_need_no_model_and_pass_the_same_checks() {
        let task = |s: &str| fixed(s).map(|r| step(&r));
        assert_eq!(task("What's the time?").unwrap().1, "/usr/bin/date");
        assert_eq!(task("show me disk space please").unwrap().1, "/usr/bin/df");
        assert_eq!(task("memory").unwrap().1, "/usr/bin/free");
        assert_eq!(task("Restart cron").unwrap(), ("broker".into(), "service.restart".into(), json!(["cron.service"])));
        assert_eq!(task("is network manager running?").unwrap(), ("broker".into(), "service.status".into(), json!(["NetworkManager.service"])));
        assert_eq!(task("status of timesyncd").unwrap().2, json!(["systemd-timesyncd.service"]));
        for other in ["what is the date of the next debian release", "restart apache", "time to write a poem", "", "delete my disk"] {
            assert!(fixed(other).is_none(), "{other:?} must go to a model");
        }
    }

    /// The lines are what qwen2.5-instruct:1.5b really answered on the AI HAT+ 2 (2026-11-18).
    #[test]
    fn local_lines_are_read_only_and_anything_else_escalates() {
        let ok = |l: &str| parse_line(l, "local:m").map(|r| step(&r)).unwrap();
        assert_eq!(ok("READ kernel").1, "/usr/bin/uname");
        assert_eq!(ok("SERVICE status crond"), ("broker".into(), "service.status".into(), json!(["cron.service"])));
        assert_eq!(ok("READ time.").1, "/usr/bin/date");
        assert_eq!(ok("READ storage").1, "/usr/bin/df", "qwen2:1.5b's word for it");
        assert_eq!(ok("SERVICE status: cron").2, json!(["cron.service"]));
        let chat = parse_line("CHAT: Hello! How can I assist you today?", "local:m").unwrap();
        assert_eq!(super::super::chat_reply(&chat), Some(("local:m".into(), "Hello! How can I assist you today?".into())));
        for bad in ["ESCALATE: SERVICE restart timesyncd", "SERVICE restart timesyncd", "SERVICE convert report.ods to pdf",
                    "uptime -SERVICE uptime \"This machine has been up for [uptime] days.\"", "READ timesyndrv",
                    "FREE_MEMORY=$(cat /proc/meminfo | grep MemAvailable | cut -f 2) && echo $MEM", "I'm sorry, but I can't assist with that.",
                    "CHAT:", "", "READ disk now", "SERVICE status apache"] {
            assert!(parse_line(bad, "local:m").is_err(), "{bad:?} must escalate");
        }
    }

    /// "set the ntp server to time.google.com" -> SERVICE status networkmanager was a real answer on the HAT.
    #[test]
    fn the_local_choice_must_fit_the_request() {
        assert_eq!(changes("set the ntp server to time.google.com").as_deref(), Some("set"));
        assert!(changes("Restart cron, please").is_some() && changes("is cron running").is_none() && changes("what's my setup").is_none());
        assert!(about("what kernel am I on", "/usr/bin/uname", None));
        assert!(about("how much RAM is free", "/usr/bin/free", None));
        assert!(about("is the wi-fi service up?", "service.status", Some("NetworkManager.service")));
        assert!(about("is networkmanager ok", "service.status", Some("NetworkManager.service")));
        assert!(!about("what's the ntp server", "service.status", Some("NetworkManager.service")));
        assert!(!about("how much free memory do I have", "/usr/bin/df", None));
        assert!(!about("tell me a story about update", "/usr/bin/uptime", None), "'up' is a word, not a prefix");
        // qwen2:1.5b's wrong answers on the HAT (2026-11-18), all refused:
        assert!(!about("thanks, that helped", "/usr/bin/date", None));
        assert!(!about("how long has this machine been up", "service.status", Some("NetworkManager.service")));
        assert!(!about("when did it last boot", "/usr/bin/date", None));
        assert!(!about("is time sync working", "/usr/bin/date", None), "a service question is not a read");
        assert!(about("is time sync working", "service.status", Some("systemd-timesyncd.service")));
        assert!(about("what's the system load", "/usr/bin/uptime", None) && about("is my storage almost full", "/usr/bin/df", None));
    }

    #[test]
    fn local_endpoint_must_be_loopback() {
        for ok in ["http://127.0.0.1:8080/v1", "http://localhost:11434/v1", "http://[::1]:8080/v1"] {
            assert!(local_url_ok(ok), "{ok}");
        }
        for bad in ["https://api.example.com/v1", "http://127.0.0.1.evil.com:80/v1", "http://localhost:8080/v1\"\nurl = \"http://x",
                    "http://localhost:/v1", "http://10.0.0.2:8080/v1", "http://localhost@evil:80"] {
            assert!(!local_url_ok(bad), "{bad}");
        }
    }

    /// A fake local server answering once per connection with `bodies` in order; returns its base URL.
    fn fake_server(bodies: Vec<String>, openai: bool) -> String {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://127.0.0.1:{}{}", l.local_addr().unwrap().port(), if openai { "/v1" } else { "" });
        std::thread::spawn(move || {
            for (body, conn) in bodies.into_iter().zip(l.incoming()) {
                let mut c = conn.unwrap();
                let mut r = BufReader::new(c.try_clone().unwrap());
                let mut len = 0;
                let mut first = String::new();
                r.read_line(&mut first).unwrap();
                assert!(first.contains(if openai { "/v1/chat/completions" } else { " /api/chat " }), "{first}");
                loop {
                    let mut h = String::new();
                    r.read_line(&mut h).unwrap();
                    if let Some(v) = h.to_lowercase().strip_prefix("content-length:") { len = v.trim().parse().unwrap(); }
                    if h.trim().is_empty() { break; }
                }
                let mut req = vec![0; len];
                r.read_exact(&mut req).unwrap();
                let req: Value = serde_json::from_slice(&req).unwrap();
                assert!(req["messages"][0]["content"].as_str().unwrap().ends_with("Answer (one line):"), "{req}");
                let _ = write!(c, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            }
        });
        url
    }

    #[test]
    fn local_tier_answers_or_refuses_without_gemini() {
        assert!(Path::new("/usr/bin/curl").exists(), "the local tier is called through curl");
        let answer = |content: &str| json!({"choices": [{"message": {"content": content}}]}).to_string();
        let url = fake_server(vec![answer("CHAT: hello"), answer("ESCALATE")], true);
        let r = Router { local: Some((url, "tiny".into())), key: None, models: String::new() };
        let mut note = Vec::new();
        let contents = json!([{"role": "user", "parts": [{"text": "earlier"}]}, {"role": "user", "parts": [{"text": "hi"}]}]);
        let v = r.plan("", &contents, false, &mut note).unwrap();
        assert_eq!(super::super::chat_reply(&v), Some(("local:tiny".into(), "hello".into())));
        let e = r.plan("", &contents, false, &mut note).unwrap_err().to_string();
        assert!(e.starts_with("planner unavailable: this needs a more capable model"), "{e}");
        let log = String::from_utf8(note).unwrap();
        assert!(log.contains(r#""event":"PLANNER_ROUTE""#) && log.contains(r#""tier":"local""#), "{log}");
        assert!(r.plan("", &contents, true, &mut Vec::new()).is_err(), "a repair never goes to the local tier");

        // Ollama style (hailo-ollama): a single reply, then a stream that ignored "stream": false.
        let chunk = |c: &str, done: bool| json!({"message": {"role": "assistant", "content": c}, "done": done}).to_string();
        let url = fake_server(vec![chunk("READ memory", true), format!("{}\n{}\n", chunk("SERVICE sta", false), chunk("tus cron", true)),
                                   chunk("SERVICE status networkmanager", true)], false);
        let r = Router { local: Some((url, "qwen2:1.5b".into())), key: None, models: String::new() };
        let ask = |q: &str| r.plan("", &json!([{"role": "user", "parts": [{"text": q}]}]), false, &mut Vec::new());
        assert_eq!(step(&ask("how much ram do I have left").unwrap()).1, "/usr/bin/free");
        assert_eq!(step(&ask("is the cron daemon alive").unwrap()).2, json!(["cron.service"]));
        assert!(ask("set the ntp server to time.google.com").is_err(), "a change request never reaches the local model");
        assert!(ask("which ntp server do I use").unwrap_err().to_string().contains("does not mention"), "a choice off the request is refused");
    }
}
