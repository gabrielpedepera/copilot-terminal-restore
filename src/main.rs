#[cfg(not(windows))]
compile_error!("This helper currently supports Windows only.");

mod windows;

use serde::{Deserialize, Serialize};
use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
type Error = Box<dyn std::error::Error>;
type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct ProcessKey {
    pid: u32,
    created: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
enum State {
    Armed,
    EndObserved,
    Restoring,
    AwaitingHook,
    Dormant,
    Ambiguous,
    Failed,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    version: u32,
    terminal_id: String,
    session_id: String,
    cwd: PathBuf,
    copilot_home: PathBuf,
    owner: ProcessKey,
    shell: ProcessKey,
    generation: String,
    state: State,
    attempts: u32,
    message: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Hook {
    #[serde(alias = "session_id")]
    session_id: String,
    cwd: PathBuf,
    source: Option<String>,
    reason: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Config {
    executable: String,
    args: Vec<String>,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            executable: "copilot".into(),
            args: vec![],
        }
    }
}

fn guid(value: &str) -> Result<String> {
    let value = value.trim_matches(['{', '}']).to_ascii_lowercase();
    if value.len() != 36
        || !value.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
    {
        return Err("Expected a GUID session identifier".into());
    }
    Ok(value)
}

fn home() -> Result<PathBuf> {
    if let Some(value) = env::var_os("COPILOT_HOME") {
        return Ok(value.into());
    }
    Ok(PathBuf::from(env::var_os("USERPROFILE").ok_or("USERPROFILE is missing")?).join(".copilot"))
}

fn root() -> Result<PathBuf> {
    if let Some(value) = env::var_os("CTR_STATE_HOME") {
        return Ok(value.into());
    }
    Ok(
        PathBuf::from(env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA is missing")?)
            .join("CopilotTerminalRestore"),
    )
}

struct Store {
    dir: PathBuf,
    id: String,
    _lock: File,
}
impl Store {
    fn open(root: &Path, terminal: &str) -> Result<Self> {
        let id = guid(terminal)?;
        let dir = root.join("sessions");
        fs::create_dir_all(&dir)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(dir.join(format!("{id}.lock")))?;
        let start = std::time::Instant::now();
        let contended = fs2::lock_contended_error().raw_os_error();
        loop {
            match fs2::FileExt::try_lock_exclusive(&lock) {
                Ok(()) => break,
                Err(e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.raw_os_error() == contended =>
                {
                    if start.elapsed() > Duration::from_secs(2) {
                        return Err("Timed out waiting for the terminal state lock".into());
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => return Err(e.into()),
            }
        }
        Ok(Self {
            dir,
            id,
            _lock: lock,
        })
    }
    fn path(&self) -> PathBuf {
        self.dir.join(format!("{}.json", self.id))
    }
    fn read(&self) -> Result<Option<Record>> {
        let file = match File::open(self.path()) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let mut bytes = vec![];
        file.take(65_537).read_to_end(&mut bytes)?;
        if bytes.len() > 65_536 {
            return Err("Saved record exceeds size limit".into());
        }
        let record: Record = serde_json::from_slice(&bytes)?;
        if record.version != 1
            || record.terminal_id != self.id
            || guid(&record.session_id)? != record.session_id
            || !record.cwd.is_absolute()
            || !record.copilot_home.is_absolute()
        {
            return Err("Saved record has invalid identity, paths, or schema version".into());
        }
        Ok(Some(record))
    }
    fn write(&self, record: &Record) -> Result<()> {
        let bytes = serde_json::to_vec_pretty(record)?;
        if bytes.len() > 65_536 {
            return Err("Saved record would exceed size limit".into());
        }
        let temp = self
            .dir
            .join(format!("{}.{}.tmp", self.id, std::process::id()));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(&temp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            drop(file);
            windows::replace(&temp, &self.path())
        })();
        if result.is_err() && temp.exists() {
            fs::remove_file(&temp)?;
        }
        result
    }
}

fn noninteractive(args: &[String]) -> bool {
    args.iter()
        .any(|a| a == "-p" || a == "--prompt" || a.starts_with("--prompt=") || a.starts_with("-p="))
}

fn cli_candidates(chain: &[(u32, String)], shell_pid: u32) -> Option<Vec<u32>> {
    let end = chain.iter().position(|(id, _)| *id == shell_pid)?;
    if end < 2 {
        return None;
    }
    let first = chain[1..end]
        .iter()
        .position(|(_, name)| name == "copilot.exe")?;
    if chain[1 + first..end]
        .iter()
        .any(|(_, name)| name == "pwsh.exe" || name == "powershell.exe" || name == "cmd.exe")
    {
        return None;
    }
    Some(
        chain[1 + first..end]
            .iter()
            .filter(|(_, name)| name == "copilot.exe")
            .map(|(id, _)| *id)
            .collect(),
    )
}

fn eligible_owner(shell: &ProcessKey) -> Result<Option<ProcessKey>> {
    if !windows::alive(shell)? {
        return Ok(None);
    }
    let Some(candidates) = cli_candidates(&windows::ancestry()?, shell.pid) else {
        return Ok(None);
    };
    for candidate in &candidates {
        if noninteractive(&windows::arguments(&windows::command_line(*candidate)?)?) {
            return Ok(None);
        }
    }
    windows::process_key(*candidates.first().ok_or("Missing Copilot owner")?)
}

fn transition_start(
    previous: Option<Record>,
    mut next: Record,
    previous_owner_alive: bool,
) -> Record {
    if let Some(previous) = previous {
        if previous_owner_alive
            && previous.owner == next.owner
            && previous.session_id != next.session_id
        {
            next.state = State::Ambiguous;
            next.message = Some("Multiple conversations in one CLI are unsupported".into());
        } else if previous.state == State::Ambiguous && previous.owner == next.owner {
            next.state = State::Ambiguous;
            next.message = previous.message;
        }
    }
    next
}

fn record_hook(kind: &str, store: &Store) -> Result<()> {
    let mut bytes = vec![];
    std::io::stdin().take(1_048_577).read_to_end(&mut bytes)?;
    if bytes.len() > 1_048_576 {
        return Err("Hook input exceeds size limit".into());
    }
    let hook: Hook = serde_json::from_slice(&bytes)?;
    let session_id = guid(&hook.session_id)?;
    if !hook.cwd.is_absolute() {
        return Err("Hook cwd must be absolute".into());
    }
    let shell: ProcessKey = serde_json::from_str(&env::var("CTR_SHELL_OWNER")?)?;
    let Some(owner) = eligible_owner(&shell)? else {
        return Ok(());
    };
    let mut previous = store.read()?;
    if let Some(record) = &mut previous {
        if record.state == State::AwaitingHook
            && record.shell == shell
            && windows::alive(&record.owner)?
            && windows::ancestry()?
                .iter()
                .any(|(pid, _)| *pid == record.owner.pid)
        {
            record.owner = owner.clone();
        }
    }
    if kind == "end" {
        if let Some(mut record) = previous {
            if record.owner == owner
                && record.session_id == session_id
                && matches!(record.state, State::Armed | State::AwaitingHook)
            {
                record.state = State::EndObserved;
                record.message = hook.reason.map(|r| format!("CLI end observed: {r}"));
                store.write(&record)?;
            }
        }
        return Ok(());
    }
    if !matches!(
        hook.source.as_deref(),
        Some("startup") | Some("resume") | Some("new")
    ) {
        return Err("Unsupported sessionStart source".into());
    }
    let previous_alive = match &previous {
        Some(record) => windows::alive(&record.owner)?,
        None => false,
    };
    if let Some(old) = &previous {
        if previous_alive && old.owner != owner {
            return Err("This terminal already has a different live Copilot owner".into());
        }
    }
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let next = Record {
        version: 1,
        terminal_id: store.id.clone(),
        session_id,
        cwd: hook.cwd,
        copilot_home: home()?,
        owner,
        shell,
        generation: format!("{now}-{}", std::process::id()),
        state: State::Armed,
        attempts: 0,
        message: None,
    };
    let next = transition_start(previous, next, previous_alive);
    if next.state == State::Ambiguous {
        eprintln!(
            "copilot-terminal-restore: multiple conversations detected; auto-resume disabled"
        );
    }
    store.write(&next)
}

fn config(root: &Path) -> Result<Config> {
    let path = root.join("config.json");
    let c: Config = if path.exists() {
        serde_json::from_slice(&fs::read(path)?)?
    } else {
        Config::default()
    };
    if c.executable.trim().is_empty()
        || c.args.iter().any(|a| {
            [
                "--resume",
                "-r",
                "--continue",
                "--session-id",
                "-p",
                "--prompt",
                "-i",
                "--interactive",
            ]
            .iter()
            .any(|flag| a == flag || a.starts_with(&format!("{flag}=")))
        })
    {
        return Err("Launcher must specify an executable and no session/prompt overrides".into());
    }
    Ok(c)
}

fn emit(value: serde_json::Value) -> Result<()> {
    println!("{}", serde_json::to_string(&value)?);
    Ok(())
}

fn init(store: &Store, shell: ProcessKey, root: &Path) -> Result<()> {
    let Some(mut record) = store.read()? else {
        return emit(serde_json::json!({"action":"none"}));
    };
    if !matches!(
        record.state,
        State::Armed | State::EndObserved | State::Restoring | State::AwaitingHook
    ) {
        return emit(
            serde_json::json!({"action":"none", "state":record.state, "message":record.message}),
        );
    }
    if windows::alive(&record.owner)?
        || (record.state == State::Restoring && windows::alive(&record.shell)?)
    {
        return emit(
            serde_json::json!({"action":"none", "message":"Already owned by a live process"}),
        );
    }
    if record.attempts >= 3
        || !record.cwd.is_dir()
        || !record
            .copilot_home
            .join("session-state")
            .join(&record.session_id)
            .is_dir()
    {
        record.state = State::Failed;
        record.message = Some("Resume limit reached, directory missing, or local session removed; use status and explicit retry".into());
        store.write(&record)?;
        return Err(record.message.ok_or("Missing failure detail")?.into());
    }
    let launcher = config(root)?;
    record.shell = shell;
    record.state = State::Restoring;
    record.attempts += 1;
    record.message = None;
    store.write(&record)?;
    emit(serde_json::json!({
        "action":"restore", "sessionId":record.session_id, "cwd":record.cwd,
        "copilotHome":record.copilot_home, "generation":record.generation,
        "executable":launcher.executable, "args":launcher.args
    }))
}

fn run() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("help");
    if command == "--version" {
        println!("copilot-terminal-restore {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }
    if command == "help" || command == "--help" {
        println!("copilot-terminal-restore: hook <start|end>, shell-owner <pid>, init, launched <generation> <pid>, prompt, status, retry, forget, fail <message>, doctor");
        return Ok(());
    }
    if command == "shell-owner" {
        let pid: u32 = args.get(1).ok_or("shell-owner requires a PID")?.parse()?;
        let key = windows::process_key(pid)?.ok_or("Shell process no longer exists")?;
        return emit(serde_json::to_value(key)?);
    }
    let root = root()?;
    if command == "doctor" {
        let launcher = config(&root)?;
        return emit(serde_json::json!({
            "version":env!("CARGO_PKG_VERSION"), "stateHome":root,
            "copilotHome":home()?, "terminalPresent":env::var_os("WT_SESSION").is_some(),
            "shellRegistered":env::var_os("CTR_SHELL_OWNER").is_some(),
            "launcher":launcher
        }));
    }
    if command == "hook"
        && (env::var_os("CTR_SHELL_OWNER").is_none()
            || env::var("CTR_DISABLE").as_deref() == Ok("1")
            || env::var("COPILOT_HOOK_DEPTH")
                .ok()
                .and_then(|v| v.parse::<u32>().ok())
                .is_some_and(|depth| depth > 1))
    {
        return Ok(());
    }
    let store = Store::open(&root, &env::var("WT_SESSION")?)?;
    match command {
        "hook" => match args.get(1).map(String::as_str) {
            Some(kind @ ("start" | "end")) => record_hook(kind, &store),
            _ => Err("hook requires start or end".into()),
        },
        "init" => {
            let shell: ProcessKey = serde_json::from_str(&env::var("CTR_SHELL_OWNER")?)?;
            if !windows::alive(&shell)? {
                return Err("Registered shell is no longer alive".into());
            }
            init(&store, shell, &root)
        }
        "status" => emit(serde_json::to_value(store.read()?)?),
        "launched" => {
            let mut record = store.read()?.ok_or("No pending restoration")?;
            let shell: ProcessKey = serde_json::from_str(&env::var("CTR_SHELL_OWNER")?)?;
            if record.shell != shell {
                return Err("Restoration shell ownership changed".into());
            }
            if record.state == State::Armed && windows::alive(&record.owner)? {
                return Ok(());
            }
            if record.state != State::Restoring
                || &record.generation != args.get(1).ok_or("Missing restore generation")?
            {
                return Err("Restoration claim no longer matches".into());
            }
            let pid: u32 = args.get(2).ok_or("Missing launcher PID")?.parse()?;
            let owner =
                windows::process_key(pid)?.ok_or("Resume launcher exited before registration")?;
            if !windows::alive(&shell)?
                || windows::ancestry_from(pid)?.get(1).map(|(pid, _)| *pid) != Some(shell.pid)
            {
                return Err("Resume launcher is not a child of the registered shell".into());
            }
            record.owner = owner;
            record.state = State::AwaitingHook;
            record.attempts = 0;
            store.write(&record)
        }
        "prompt" | "forget" | "retry" | "fail" => {
            if let Some(mut record) = store.read()? {
                let shell: ProcessKey = serde_json::from_str(&env::var("CTR_SHELL_OWNER")?)?;
                if command == "prompt" && record.shell != shell {
                    return Ok(());
                }
                if command != "fail" && command != "forget" && windows::alive(&record.owner)? {
                    if command == "retry" {
                        return Err("Cannot retry while this Copilot owner is still alive".into());
                    }
                    return Ok(());
                }
                match command {
                    "prompt" if record.state == State::Restoring => {
                        record.state = State::Failed;
                        record.message =
                            Some("Launcher returned without confirming the resume hook".into());
                        eprintln!("copilot-terminal-restore: launcher returned without confirming the resume hook");
                    }
                    "prompt"
                        if matches!(
                            record.state,
                            State::Armed | State::EndObserved | State::AwaitingHook
                        ) =>
                    {
                        record.state = State::Dormant;
                        record.message = None;
                    }
                    "forget" => {
                        record.state = State::Dormant;
                        record.message = None;
                    }
                    "retry" => {
                        record.state = State::Armed;
                        record.attempts = 0;
                        record.message = None;
                    }
                    "fail" => {
                        record.state = State::Failed;
                        record.message =
                            Some(args.get(1).ok_or("fail requires a message")?.clone());
                    }
                    _ => return Ok(()),
                }
                store.write(&record)?;
            }
            Ok(())
        }
        _ => Err(format!("Unknown command: {command}").into()),
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("copilot-terminal-restore: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(session: &str) -> Record {
        Record {
            version: 1,
            terminal_id: "00000000-0000-0000-0000-000000000001".into(),
            session_id: session.into(),
            cwd: PathBuf::from(r"C:\test space"),
            copilot_home: PathBuf::from(r"C:\copilot"),
            owner: ProcessKey { pid: 1, created: 1 },
            shell: ProcessKey { pid: 2, created: 1 },
            generation: "first".into(),
            state: State::Armed,
            attempts: 0,
            message: None,
        }
    }

    #[test]
    fn multiple_conversations_disable_auto_resume_until_owner_changes() {
        let old = record("00000000-0000-0000-0000-000000000002");
        let next = record("00000000-0000-0000-0000-000000000003");
        let ambiguous = transition_start(Some(old), next.clone(), true);
        assert_eq!(ambiguous.state, State::Ambiguous);
        let mut fresh = next;
        fresh.owner.created = 2;
        assert_eq!(
            transition_start(Some(ambiguous), fresh, false).state,
            State::Armed
        );
    }

    #[test]
    fn invalid_identity_cannot_escape_state_directory() {
        assert!(guid(r"..\other-record").is_err());
        assert!(guid("00000000-0000-0000-0000-00000000000x").is_err());
    }

    #[test]
    fn noninteractive_invocations_are_excluded() {
        assert!(noninteractive(&["copilot".into(), "--prompt=hello".into()]));
        assert!(!noninteractive(&["copilot".into(), "--interactive".into()]));
    }

    #[test]
    fn nested_shell_copilot_is_not_attributed_to_the_outer_prompt() {
        let nested = vec![
            (10, "copilot-terminal-restore.exe".into()),
            (20, "copilot.exe".into()),
            (30, "pwsh.exe".into()),
            (40, "pwsh.exe".into()),
        ];
        assert!(cli_candidates(&nested, 40).is_none());
        let wrapped = vec![
            (10, "copilot-terminal-restore.exe".into()),
            (20, "copilot.exe".into()),
            (25, "copilot.exe".into()),
            (30, "wrapper.exe".into()),
            (40, "pwsh.exe".into()),
        ];
        assert_eq!(cli_candidates(&wrapped, 40), Some(vec![20, 25]));
    }

    #[test]
    fn records_are_separate_and_replacements_do_not_truncate_other_tabs() -> Result<()> {
        let root = env::temp_dir().join(format!("ctr-state-test-{}", std::process::id()));
        fs::create_dir_all(&root)?;
        let first = record("00000000-0000-0000-0000-000000000002");
        let mut second = first.clone();
        second.terminal_id = "00000000-0000-0000-0000-000000000004".into();
        second.session_id = "00000000-0000-0000-0000-000000000005".into();
        {
            let a = Store::open(&root, &first.terminal_id)?;
            let b = Store::open(&root, &second.terminal_id)?;
            a.write(&first)?;
            b.write(&second)?;
            a.write(&first)?;
            assert_ne!(a.read()?.unwrap().session_id, b.read()?.unwrap().session_id);
            fs::write(a.path(), b"{broken")?;
            assert!(a.read().is_err());
        }
        fs::remove_dir_all(root)?;
        Ok(())
    }

    #[test]
    fn process_identity_checks_creation_time_and_windows_argument_boundaries() -> Result<()> {
        let key = windows::process_key(std::process::id())?.unwrap();
        assert!(windows::alive(&key)?);
        assert!(!windows::alive(&ProcessKey {
            created: key.created + 1,
            ..key
        })?);
        assert_eq!(
            windows::arguments(r#""C:\a b\copilot.exe" --interactive "do not --prompt""#)?,
            vec![r"C:\a b\copilot.exe", "--interactive", "do not --prompt"]
        );
        assert!(windows::command_line(std::process::id())?.contains("copilot"));
        Ok(())
    }
}
