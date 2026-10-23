//! Platform-neutral host contract. Neither Swift nor the Android JNI API is
//! coupled to the SDK's diagnostic JSON schema.
use fusionplay_miplay_sdk::{MiPlayReceiver, ReceiverConfig, ReceiverIdentity};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::os::unix::{
    fs::{OpenOptionsExt, PermissionsExt},
    io::AsRawFd,
};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::Write,
    net::Ipv4Addr,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HostError {
    #[error("Invalid configuration: {message}")]
    InvalidConfig { message: String },
    #[error("Storage: {message}")]
    Storage { message: String },
    #[error("Receiver: {message}")]
    Receiver { message: String },
    #[error("Another receiver is using this data directory")]
    AlreadyRunning,
}
type Result<T> = std::result::Result<T, HostError>;
fn storage(e: impl std::fmt::Display) -> HostError {
    HostError::Storage {
        message: e.to_string(),
    }
}
fn receiver_error(e: impl std::fmt::Display) -> HostError {
    HostError::Receiver {
        message: format!("{e:#}"),
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Settings {
    pub name: String,
    pub interface_name: String,
    pub output_device: String,
    pub volume: u32,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            name: "FusionPlay-Mac".into(),
            interface_name: String::new(),
            output_device: String::new(),
            volume: 50,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum Phase {
    Stopped,
    Starting,
    Ready,
    Connected,
    Playing,
    Paused,
    Failed,
}
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct Snapshot {
    pub phase: Phase,
    pub title: String,
    pub artist: String,
    pub volume: u32,
    pub message: String,
    pub address: String,
    pub output: String,
    pub queue_ms: f64,
    pub output_latency_ms: f64,
    pub schedule_error_ms: f64,
    pub underruns: u64,
    pub dropped_frames: u64,
    pub resyncs: u64,
}
impl Default for Snapshot {
    fn default() -> Self {
        Self {
            phase: Phase::Stopped,
            title: String::new(),
            artist: String::new(),
            volume: 50,
            message: "接收器未启动".into(),
            address: String::new(),
            output: String::new(),
            queue_ms: 0.0,
            output_latency_ms: 0.0,
            schedule_error_ms: 0.0,
            underruns: 0,
            dropped_frames: 0,
            resyncs: 0,
        }
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct NetworkInterface {
    pub name: String,
    pub address: String,
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct AudioDevice {
    pub id: String,
    pub name: String,
    pub is_default: bool,
}

#[uniffi::export]
pub fn network_interfaces() -> Result<Vec<NetworkInterface>> {
    let mut interfaces: Vec<_> = if_addrs::get_if_addrs()
        .map_err(receiver_error)?
        .into_iter()
        .filter(|i| i.is_oper_up() && !i.is_loopback() && !i.is_p2p() && !i.is_link_local())
        .filter_map(|i| match i.ip() {
            std::net::IpAddr::V4(ip) => Some(NetworkInterface {
                name: i.name,
                address: ip.to_string(),
            }),
            _ => None,
        })
        .collect();
    interfaces.sort_by_key(|i| (!i.name.starts_with("en"), i.name.clone(), i.address.clone()));
    Ok(interfaces)
}
#[uniffi::export]
pub fn audio_devices() -> Result<Vec<AudioDevice>> {
    #[cfg(target_os = "macos")]
    {
        use cpal::traits::{DeviceTrait, HostTrait};
        let host = cpal::default_host();
        let default_id = host
            .default_output_device()
            .and_then(|d| d.id().ok())
            .map(|i| i.to_string());
        host.output_devices()
            .map_err(receiver_error)?
            .map(|d| {
                let id = d.id().map_err(receiver_error)?.to_string();
                Ok(AudioDevice {
                    is_default: default_id.as_ref() == Some(&id),
                    id,
                    name: d.description().map_err(receiver_error)?.name().into(),
                })
            })
            .collect()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(Vec::new())
    }
}

#[uniffi::export(callback_interface)]
pub trait StateListener: Send + Sync {
    fn on_state(&self, state: Snapshot);
}

#[derive(Serialize, Deserialize)]
struct Identity {
    idm: String,
    lyra: String,
    media: String,
}
fn load_identity(dir: &Path) -> Result<Identity> {
    let path = dir.join("identity.json");
    if path.exists() {
        return serde_json::from_slice(&fs::read(path).map_err(storage)?).map_err(storage);
    }
    let identity = Identity {
        idm: uuid::Uuid::new_v4().to_string(),
        lyra: uuid::Uuid::new_v4().simple().to_string()[..8].to_uppercase(),
        media: uuid::Uuid::new_v4().simple().to_string()[..8].to_uppercase(),
    };
    save_json(&path, &identity)?;
    Ok(identity)
}
fn save_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(storage)?;
    file.write_all(&serde_json::to_vec_pretty(value).map_err(storage)?)
        .map_err(storage)?;
    file.sync_all().map_err(storage)?;
    fs::rename(tmp, path).map_err(storage)
}
struct Shared {
    state: Mutex<Snapshot>,
    listeners: Mutex<BTreeMap<u64, Arc<dyn StateListener>>>,
    generation: AtomicU64,
    shutdown: AtomicBool,
}
struct Event {
    generation: u64,
    value: Value,
}
#[derive(uniffi::Object)]
pub struct Receiver {
    shared: Arc<Shared>,
    core: Mutex<Option<MiPlayReceiver>>,
    settings: Mutex<Settings>,
    operations: Mutex<()>,
    data: PathBuf,
    _lock: File,
    tx: mpsc::SyncSender<Event>,
    worker: Mutex<Option<thread::JoinHandle<()>>>,
    next_listener: AtomicU64,
}

#[uniffi::export]
impl Receiver {
    #[uniffi::constructor]
    pub fn new(data_directory: String) -> Result<Arc<Self>> {
        let data = PathBuf::from(data_directory);
        if !data.is_absolute() {
            return Err(HostError::InvalidConfig {
                message: "Data directory must be absolute".into(),
            });
        }
        fs::create_dir_all(&data).map_err(storage)?;
        fs::set_permissions(&data, fs::Permissions::from_mode(0o700)).map_err(storage)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(data.join("receiver.lock"))
            .map_err(storage)?;
        // flock owns only this project's lock file; it never addresses another app's PID.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(HostError::AlreadyRunning);
        }
        load_identity(&data)?;
        let settings: Settings = if data.join("settings.json").exists() {
            serde_json::from_slice(&fs::read(data.join("settings.json")).map_err(storage)?)
                .map_err(storage)?
        } else {
            Settings::default()
        };
        let shared = Arc::new(Shared {
            state: Mutex::new(Snapshot {
                volume: settings.volume,
                ..Snapshot::default()
            }),
            listeners: Mutex::new(BTreeMap::new()),
            generation: AtomicU64::new(0),
            shutdown: AtomicBool::new(false),
        });
        let (tx, rx) = mpsc::sync_channel::<Event>(512);
        let log_dir = data.parent().unwrap_or(&data).join("logs");
        fs::create_dir_all(&log_dir).map_err(storage)?;
        let worker_shared = shared.clone();
        let worker = thread::Builder::new()
            .name("fusionplay-events".into())
            .spawn(move || {
                while !worker_shared.shutdown.load(Ordering::Acquire) {
                    match rx.recv_timeout(Duration::from_millis(100)) {
                        Ok(event) => {
                            if event.generation != worker_shared.generation.load(Ordering::Acquire)
                            {
                                continue;
                            }
                            let (snapshot, changed) = {
                                let mut state = worker_shared.state.lock().unwrap();
                                if event.generation
                                    != worker_shared.generation.load(Ordering::Acquire)
                                {
                                    continue;
                                }
                                let previous = state.clone();
                                reduce(&mut state, &event.value);
                                (state.clone(), *state != previous)
                            };
                            write_diagnostic(&log_dir, &event.value);
                            if !changed && event.value["event"] != "host_stopped" {
                                continue;
                            }
                            let listeners: Vec<_> = worker_shared
                                .listeners
                                .lock()
                                .unwrap()
                                .values()
                                .cloned()
                                .collect();
                            for listener in listeners {
                                listener.on_state(snapshot.clone());
                            }
                        }
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                    }
                }
            })
            .map_err(storage)?;
        Ok(Arc::new(Self {
            shared,
            core: Mutex::new(None),
            settings: Mutex::new(settings),
            operations: Mutex::new(()),
            data,
            _lock: lock,
            tx,
            worker: Mutex::new(Some(worker)),
            next_listener: AtomicU64::new(1),
        }))
    }
    pub fn settings(&self) -> Settings {
        self.settings.lock().unwrap().clone()
    }
    pub fn snapshot(&self) -> Snapshot {
        self.shared.state.lock().unwrap().clone()
    }
    pub fn subscribe(&self, listener: Box<dyn StateListener>) -> u64 {
        let id = self.next_listener.fetch_add(1, Ordering::Relaxed);
        self.shared
            .listeners
            .lock()
            .unwrap()
            .insert(id, Arc::from(listener));
        id
    }
    pub fn unsubscribe(&self, token: u64) {
        self.shared.listeners.lock().unwrap().remove(&token);
    }
    pub fn start(&self, settings: Settings) -> Result<()> {
        let _operation = self.operations.lock().unwrap();
        self.stop_inner();
        if settings.name.trim().is_empty()
            || settings.name.chars().count() > 64
            || settings.volume > 100
        {
            return Err(HostError::InvalidConfig {
                message: "Name must contain 1–64 characters; volume must be 0–100".into(),
            });
        }
        let result = self.start_inner(settings);
        if let Err(error) = &result {
            self.emit(serde_json::json!({"event":"host_error", "message": error.to_string()}));
        }
        result
    }
    pub fn stop(&self) {
        let _operation = self.operations.lock().unwrap();
        self.stop_inner();
    }
    pub fn set_volume(&self, volume: u32) -> Result<()> {
        let _operation = self.operations.lock().unwrap();
        if volume > 100 {
            return Err(HostError::InvalidConfig {
                message: "Volume exceeds 100".into(),
            });
        }
        if let Some(core) = self.core.lock().unwrap().as_ref() {
            core.controller()
                .set_volume(volume as u8)
                .map_err(receiver_error)?;
        }
        let mut settings = self.settings.lock().unwrap();
        settings.volume = volume;
        save_json(&self.data.join("settings.json"), &*settings)?;
        self.emit(serde_json::json!({"event":"volume", "percent":volume}));
        Ok(())
    }
}
impl Receiver {
    fn start_inner(&self, settings: Settings) -> Result<()> {
        let interface = network_interfaces()?
            .into_iter()
            .find(|i| settings.interface_name.is_empty() || i.name == settings.interface_name)
            .ok_or_else(|| HostError::InvalidConfig {
                message: "No active LAN interface; reconnect Wi-Fi or select an interface".into(),
            })?;
        if !settings.output_device.is_empty()
            && !audio_devices()?
                .iter()
                .any(|d| d.id == settings.output_device)
        {
            return Err(HostError::InvalidConfig {
                message: "Selected audio output is unavailable".into(),
            });
        }
        let identity = load_identity(&self.data)?;
        let config = ReceiverConfig::new(
            settings.name.trim(),
            ReceiverIdentity::new(identity.idm, identity.lyra, identity.media),
            interface
                .address
                .parse::<Ipv4Addr>()
                .map_err(receiver_error)?,
            interface.name,
        )
        .with_output_device(
            (!settings.output_device.is_empty()).then(|| settings.output_device.clone()),
        )
        .with_initial_volume_percent(settings.volume);
        save_json(&self.data.join("settings.json"), &settings)?;
        *self.settings.lock().unwrap() = settings;
        self.shared.state.lock().unwrap().phase = Phase::Starting;
        let tx = self.tx.clone();
        let generation = self.shared.generation.load(Ordering::Acquire);
        let core = MiPlayReceiver::start(
            config,
            Arc::new(move |value| {
                let _ = tx.try_send(Event { generation, value });
            }),
        )
        .map_err(receiver_error)?;
        *self.core.lock().unwrap() = Some(core);
        Ok(())
    }
    fn emit(&self, value: Value) {
        let _ = self.tx.try_send(Event {
            generation: self.shared.generation.load(Ordering::Acquire),
            value,
        });
    }
    fn stop_inner(&self) {
        self.shared.generation.fetch_add(1, Ordering::AcqRel);
        if let Some(core) = self.core.lock().unwrap().take() {
            core.controller().stop();
            drop(core);
        }
        let volume = self.settings.lock().unwrap().volume;
        *self.shared.state.lock().unwrap() = Snapshot {
            volume,
            ..Snapshot::default()
        };
        self.emit(serde_json::json!({"event":"host_stopped"}));
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        self.stop_inner();
        self.shared.shutdown.store(true, Ordering::Release);
        self.shared.listeners.lock().unwrap().clear();
        if let Some(worker) = self.worker.lock().unwrap().take() {
            let _ = worker.join();
        }
    }
}

fn reduce(state: &mut Snapshot, value: &Value) {
    let text = |key| value[key].as_str().unwrap_or("").to_owned();
    match value["event"].as_str().unwrap_or("") {
        "receiver_ready" => {
            state.phase = Phase::Ready;
            state.address = text("address");
            state.message = "等待手机连接".into();
        }
        "interconnect_stage" if text("stage") == "media_session_established" => {
            state.phase = Phase::Connected;
            state.message = "媒体会话已连接，等待声音".into();
        }
        "audio_output_signal_started" => {
            state.phase = Phase::Playing;
            state.message = "正在播放".into();
        }
        "audio_health" => {
            state.queue_ms = value["queue_ms"].as_f64().unwrap_or(0.0);
            state.output_latency_ms = value["output_latency_ms"].as_f64().unwrap_or(0.0);
            state.schedule_error_ms = value["schedule_error_ms"].as_f64().unwrap_or(0.0);
            state.underruns = value["underruns"].as_u64().unwrap_or(0);
            state.dropped_frames = value["dropped_frames"].as_u64().unwrap_or(0);
            state.resyncs = value["resyncs"].as_u64().unwrap_or(0);
            if value["rendering"].as_bool() == Some(true) && state.phase != Phase::Failed {
                state.phase = Phase::Playing;
                state.message = "正在播放".into();
            } else if state.phase == Phase::Playing {
                state.phase = Phase::Connected;
                state.message = "等待音频数据".into();
            }
        }
        "playback_state" if value["playing"].as_bool() == Some(false) => {
            state.phase = if value["session_active"].as_bool() == Some(false) {
                Phase::Ready
            } else {
                Phase::Paused
            };
            state.message = if state.phase == Phase::Paused {
                "已暂停"
            } else {
                "等待手机连接"
            }
            .into();
        }
        "media_channel_closed" | "stream_stopped" => {
            state.phase = Phase::Ready;
            state.message = "音频会话已结束，等待重新投送".into();
        }
        "media_info" => {
            state.title = text("title");
            state.artist = text("artist");
        }
        "volume" => state.volume = value["percent"].as_u64().unwrap_or(50).min(100) as u32,
        "audio_output_ready" => state.output = text("device_name"),
        "host_error" | "error" => {
            state.phase = Phase::Failed;
            state.message = text("message");
        }
        _ => {}
    }
}
// Allowlist: never persist authentication, packets, artwork or source addresses.
fn write_diagnostic(dir: &Path, event: &Value) {
    let name = event["event"].as_str().unwrap_or("unknown");
    if !matches!(
        name,
        "receiver_ready"
            | "audio_health"
            | "clock_synchronized"
            | "audio_output_ready"
            | "host_stopped"
            | "error"
            | "host_error"
            | "stream_started"
            | "stream_stopped"
    ) {
        return;
    }
    let path = dir.join("receiver.jsonl");
    if fs::metadata(&path)
        .map(|m| m.len() > 5_000_000)
        .unwrap_or(false)
    {
        let _ = fs::rename(&path, dir.join("receiver.previous.jsonl"));
    }
    let mut record = serde_json::json!({"time_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis(), "event": name});
    for key in [
        "queue_ms",
        "output_latency_ms",
        "schedule_error_ms",
        "underruns",
        "dropped_frames",
        "resyncs",
        "rendering",
        "callback_frames",
        "silence_frames",
        "lock_contentions",
        "phase_error_us",
        "network_rtt_us",
        "sample_rate",
        "code",
    ] {
        if let Some(value) = event.get(key) {
            record[key] = value.clone();
        }
    }
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
    {
        let _ = writeln!(file, "{record}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn handshake_is_not_playback() {
        let mut s = Snapshot::default();
        reduce(&mut s, &serde_json::json!({"event":"receiver_ready"}));
        reduce(
            &mut s,
            &serde_json::json!({"event":"interconnect_stage", "stage":"transport_connected"}),
        );
        assert_eq!(s.phase, Phase::Ready);
        reduce(
            &mut s,
            &serde_json::json!({"event":"playback_state", "playing":true}),
        );
        assert_eq!(s.phase, Phase::Ready);
        reduce(
            &mut s,
            &serde_json::json!({"event":"audio_output_signal_started"}),
        );
        assert_eq!(s.phase, Phase::Playing);
    }
    #[test]
    fn identity_persistence_and_exclusive_ownership() {
        let dir = std::env::temp_dir().join(format!("fusionplay-test-{}", uuid::Uuid::new_v4()));
        let r = Receiver::new(dir.to_string_lossy().into()).unwrap();
        let first = load_identity(&dir).unwrap();
        assert!(matches!(
            Receiver::new(dir.to_string_lossy().into()),
            Err(HostError::AlreadyRunning)
        ));
        r.stop();
        r.stop();
        drop(r);
        let r = Receiver::new(dir.to_string_lossy().into()).unwrap();
        assert_eq!(first.idm, load_identity(&dir).unwrap().idm);
        r.set_volume(23).unwrap();
        drop(r);
        let r = Receiver::new(dir.to_string_lossy().into()).unwrap();
        assert_eq!(r.settings().volume, 23);
        drop(r);
        fs::remove_dir_all(dir).unwrap();
    }
}
