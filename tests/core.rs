use serde_json::{json, Value};
use std::{
    fs,
    io::Write,
    os::windows::process::CommandExt,
    path::PathBuf,
    process::{Command, Output, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

struct Fixture {
    root: PathBuf,
    terminal: String,
    shell: String,
    record: Value,
}
impl Fixture {
    fn new() -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("ctr-integration-{}-{unique}", std::process::id()));
        let terminal = "00000000-0000-0000-0000-000000000001".to_string();
        let session = "00000000-0000-0000-0000-000000000002";
        fs::create_dir_all(root.join("sessions")).unwrap();
        fs::create_dir_all(root.join("home").join("session-state").join(session)).unwrap();
        let owner = Command::new(env!("CARGO_BIN_EXE_copilot-terminal-restore"))
            .args(["shell-owner", &std::process::id().to_string()])
            .output()
            .unwrap();
        assert!(owner.status.success());
        let shell = String::from_utf8(owner.stdout).unwrap().trim().to_string();
        let record = json!({
            "version":1,"terminalId":terminal,"sessionId":session,
            "cwd":root,"copilotHome":root.join("home"),
            "owner":{"pid":4294967294u32,"created":1},
            "shell":{"pid":4294967294u32,"created":1},
            "generation":"original","state":"armed","attempts":0,"message":null
        });
        let fixture = Self {
            root,
            terminal,
            shell,
            record,
        };
        fixture.save(&fixture.record);
        fixture
    }
    fn path(&self) -> PathBuf {
        self.root
            .join("sessions")
            .join(format!("{}.json", self.terminal))
    }
    fn save(&self, value: &Value) {
        fs::write(self.path(), serde_json::to_vec(value).unwrap()).unwrap();
    }
    fn read(&self) -> Value {
        serde_json::from_slice(&fs::read(self.path()).unwrap()).unwrap()
    }
    fn command(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_copilot-terminal-restore"))
            .args(args)
            .env("WT_SESSION", &self.terminal)
            .env("CTR_STATE_HOME", &self.root)
            .env("CTR_SHELL_OWNER", &self.shell)
            .output()
            .unwrap()
    }
    fn key(&self, pid: u32) -> Value {
        let output = self.command(&["shell-owner", &pid.to_string()]);
        assert!(output.status.success());
        serde_json::from_slice(&output.stdout).unwrap()
    }
    // Runs a hook below a renamed cmd.exe "copilot.exe" (optionally under a
    // "launcher.exe"). `prepare` sees the direct child PID while the hook is
    // still blocked reading stdin.
    fn hook(&self, kind: &str, launcher: bool, prepare: impl FnOnce(u32)) -> Output {
        let bin = self.root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let system = PathBuf::from(std::env::var_os("SystemRoot").unwrap()).join("System32");
        let copilot = bin.join("copilot.exe");
        let launcher_exe = bin.join("launcher.exe");
        for target in [&copilot, &launcher_exe] {
            if !target.exists() {
                fs::copy(system.join("cmd.exe"), target).unwrap();
            }
        }
        let core = env!("CARGO_BIN_EXE_copilot-terminal-restore");
        let inner = format!("/d /c \"\"{core}\" hook {kind}\"");
        let (program, raw) = if launcher {
            (
                launcher_exe,
                format!("/d /c \"\"{}\" {inner}\"", copilot.display()),
            )
        } else {
            (copilot, inner)
        };
        let mut child = Command::new(program)
            .raw_arg(raw)
            .env("WT_SESSION", &self.terminal)
            .env("CTR_STATE_HOME", &self.root)
            .env("CTR_SHELL_OWNER", &self.shell)
            .env("COPILOT_HOME", self.root.join("home"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        prepare(child.id());
        let payload = json!({
            "sessionId": self.record["sessionId"], "cwd": self.root,
            "source": "startup", "reason": "user_exit"
        });
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&serde_json::to_vec(&payload).unwrap())
            .unwrap();
        child.wait_with_output().unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).unwrap();
    }
}

#[test]
fn claim_is_exact_and_prevents_duplicate_launches() {
    let f = Fixture::new();
    let first = f.command(&["init"]);
    assert!(
        first.status.success(),
        "{}",
        String::from_utf8_lossy(&first.stderr)
    );
    let decision: Value = serde_json::from_slice(&first.stdout).unwrap();
    assert_eq!(decision["action"], "restore");
    assert_eq!(decision["sessionId"], f.record["sessionId"]);
    assert_eq!(decision["cwd"], f.record["cwd"]);
    assert_eq!(f.read()["state"], "restoring");
    let second = f.command(&["init"]);
    assert!(second.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&second.stdout).unwrap()["action"],
        "none"
    );
}

#[test]
fn missing_local_session_fails_without_creating_a_new_one() {
    let f = Fixture::new();
    let mut broken = f.record.clone();
    broken["sessionId"] = json!("00000000-0000-0000-0000-000000000003");
    f.save(&broken);
    let output = f.command(&["init"]);
    assert!(!output.status.success());
    assert_eq!(f.read()["state"], "failed");
    assert!(!f
        .root
        .join("home")
        .join("session-state")
        .join("00000000-0000-0000-0000-000000000003")
        .exists());
}

#[test]
fn old_shell_notifications_cannot_disarm_a_record() {
    let f = Fixture::new();
    assert!(f.command(&["prompt"]).status.success());
    assert_eq!(f.read()["state"], "armed");
    let mut current = f.record.clone();
    current["shell"] = serde_json::from_str(&f.shell).unwrap();
    f.save(&current);
    assert!(f.command(&["prompt"]).status.success());
    assert_eq!(f.read()["state"], "dormant");
}

#[test]
fn failed_attempts_require_explicit_retry() {
    let f = Fixture::new();
    let mut exhausted = f.record.clone();
    exhausted["attempts"] = json!(3);
    f.save(&exhausted);
    assert!(!f.command(&["init"]).status.success());
    assert!(f.command(&["retry"]).status.success());
    assert_eq!(f.read()["attempts"], 0);
    assert!(f.command(&["init"]).status.success());
}

#[test]
fn corrupted_state_is_reported_and_preserved() {
    let f = Fixture::new();
    fs::write(f.path(), "{broken").unwrap();
    let output = f.command(&["init"]);
    assert!(!output.status.success());
    assert!(!output.stderr.is_empty());
    assert_eq!(fs::read_to_string(f.path()).unwrap(), "{broken");
}

#[test]
fn concurrent_startup_gets_one_claim() {
    let f = Fixture::new();
    let results = std::thread::scope(|scope| {
        let a = scope.spawn(|| f.command(&["init"]));
        let b = scope.spawn(|| f.command(&["init"]));
        vec![a.join().unwrap(), b.join().unwrap()]
    });
    let actions: Vec<String> = results
        .iter()
        .map(|output| {
            assert!(output.status.success());
            serde_json::from_slice::<Value>(&output.stdout).unwrap()["action"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect();
    assert_eq!(actions.iter().filter(|a| *a == "restore").count(), 1);
}

#[test]
fn configured_launcher_cannot_override_the_session_or_submit_a_prompt() {
    let f = Fixture::new();
    for argument in [
        "--resume=other",
        "--prompt=hello",
        "-i",
        "--session-id=other",
    ] {
        fs::write(
            f.root.join("config.json"),
            serde_json::to_vec(&json!({"executable":"copilot","args":[argument]})).unwrap(),
        )
        .unwrap();
        let output = f.command(&["init"]);
        assert!(!output.status.success());
        assert_eq!(f.read()["state"], "armed");
    }
}

#[test]
fn idle_resume_is_owned_before_a_start_hook_and_disarmed_on_shell_return() {
    let f = Fixture::new();
    assert!(f.command(&["init"]).status.success());
    let mut child = Command::new("pwsh")
        .args([
            "-NoLogo",
            "-NoProfile",
            "-Command",
            "Start-Sleep -Seconds 2",
        ])
        .spawn()
        .unwrap();
    let output = f.command(&["launched", "original", &child.id().to_string()]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(f.read()["state"], "awaitingHook");
    assert_eq!(f.read()["sessionId"], f.record["sessionId"]);
    assert_eq!(f.read()["attempts"], 0);
    assert!(f.command(&["prompt"]).status.success());
    assert_eq!(f.read()["state"], "awaitingHook");
    assert!(child.wait().unwrap().success());
    assert!(f.command(&["prompt"]).status.success());
    assert_eq!(f.read()["state"], "dormant");
}

#[test]
fn stale_launcher_claim_cannot_take_ownership() {
    let f = Fixture::new();
    assert!(f.command(&["init"]).status.success());
    let output = f.command(&[
        "launched",
        "wrong-generation",
        &std::process::id().to_string(),
    ]);
    assert!(!output.status.success());
    assert_eq!(f.read()["state"], "restoring");
    assert_eq!(f.read()["owner"], f.record["owner"]);
}

#[test]
fn inaccessible_reused_owner_pid_does_not_block_restore() {
    let f = Fixture::new();
    let mut reused = f.record.clone();
    reused["owner"] = json!({"pid": 4, "created": 1});
    f.save(&reused);
    let output = f.command(&["init"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["action"],
        "restore"
    );
}

#[test]
fn contended_state_lock_is_awaited() {
    use fs2::FileExt;
    let f = Fixture::new();
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(f.root.join("sessions").join(format!("{}.lock", f.terminal)))
        .unwrap();
    lock.lock_exclusive().unwrap();
    let output = std::thread::scope(|scope| {
        let waiting = scope.spawn(|| f.command(&["status"]));
        std::thread::sleep(Duration::from_millis(500));
        FileExt::unlock(&lock).unwrap();
        waiting.join().unwrap()
    });
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn start_hook_enrolls_the_interactive_cli() {
    let f = Fixture::new();
    fs::remove_file(f.path()).unwrap();
    let mut cli = 0;
    let output = f.hook("start", false, |pid| cli = pid);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let record = f.read();
    assert_eq!(record["state"], "armed");
    assert_eq!(record["sessionId"], f.record["sessionId"]);
    assert_eq!(record["owner"]["pid"], cli);
    assert_eq!(record["cwd"], f.record["cwd"]);
}

#[test]
fn end_hook_alone_keeps_the_record_recoverable() {
    let f = Fixture::new();
    let output = f.hook("end", false, |pid| {
        let mut armed = f.record.clone();
        armed["owner"] = f.key(pid);
        armed["shell"] = serde_json::from_str(&f.shell).unwrap();
        f.save(&armed);
    });
    assert!(output.status.success());
    assert_eq!(f.read()["state"], "endObserved");
    let init = f.command(&["init"]);
    assert_eq!(
        serde_json::from_slice::<Value>(&init.stdout).unwrap()["action"],
        "restore"
    );
}

#[test]
fn start_hook_replaces_provisional_launcher_ownership() {
    let f = Fixture::new();
    let mut launcher = Value::Null;
    let output = f.hook("start", true, |pid| {
        launcher = f.key(pid);
        let mut awaiting = f.record.clone();
        awaiting["state"] = json!("awaitingHook");
        awaiting["owner"] = launcher.clone();
        awaiting["shell"] = serde_json::from_str(&f.shell).unwrap();
        f.save(&awaiting);
    });
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let record = f.read();
    assert_eq!(record["state"], "armed");
    assert_ne!(record["owner"], launcher);
    assert_eq!(record["sessionId"], f.record["sessionId"]);
}

#[test]
fn start_hook_rejects_a_different_live_owner() {
    let f = Fixture::new();
    let mut owned = f.record.clone();
    owned["owner"] = serde_json::from_str(&f.shell).unwrap();
    f.save(&owned);
    let output = f.hook("start", false, |_| {});
    assert!(!output.status.success());
    assert_eq!(f.read(), owned);
}

#[test]
fn second_conversation_in_one_cli_disables_auto_resume() {
    let f = Fixture::new();
    let output = f.hook("start", false, |pid| {
        let mut other = f.record.clone();
        other["sessionId"] = json!("00000000-0000-0000-0000-000000000003");
        other["owner"] = f.key(pid);
        f.save(&other);
    });
    assert!(output.status.success());
    assert_eq!(f.read()["state"], "ambiguous");
}
