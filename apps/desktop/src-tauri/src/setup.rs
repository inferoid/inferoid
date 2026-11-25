//! First run on Windows: check for an NVIDIA GPU, then download the engine (llama.cpp and whisper.cpp, CUDA builds) and
//! the models into %LOCALAPPDATA%\Inferoid Engine, check every file against its SHA-256, and write engine.json.
//! Downloads resume after a dropped connection; files already downloaded and verified are kept.

use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};

/// One file the engine needs. `unpack` = a zip extracted into `into` (a folder under the engine root).
pub(crate) struct Download {
    pub key: &'static str,
    pub label: &'static str,
    pub url: &'static str,
    pub file: &'static str,
    pub size: u64,
    pub sha256: &'static str,
    pub unpack: Option<&'static str>,
}

/// Pinned releases (checked 2026-11-25). The model's Hugging Face revision is also what "Update model" compares.
pub(crate) const MODEL_REVISION: &str = "8078d149286eec7193795413b9e0643da6d11fa1";
pub(crate) const DOWNLOADS: &[Download] = &[
    Download { key: "llama", label: "AI engine (llama.cpp, NVIDIA)", file: "llama-b12649-bin-win-cuda-12.4-x64.zip",
        url: "https://github.com/ggml-org/llama.cpp/releases/download/b12649/llama-b12649-bin-win-cuda-12.4-x64.zip",
        size: 358_031_782, sha256: "f512ff1fcabf545a073b29ecb848611bee02fe564d22709f0e50b4972e18ee46", unpack: Some("llama") },
    Download { key: "cudart", label: "NVIDIA runtime", file: "cudart-llama-bin-win-cuda-12.4-x64.zip",
        url: "https://github.com/ggml-org/llama.cpp/releases/download/b12649/cudart-llama-bin-win-cuda-12.4-x64.zip",
        size: 391_443_627, sha256: "8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6", unpack: Some("llama") },
    Download { key: "whisper", label: "Speech-to-text engine (whisper.cpp, NVIDIA)", file: "whisper-bin-win-cuda-12.4.0-x64.zip",
        url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5907/whisper-bin-win-cuda-12.4.0-x64.zip",
        size: 735_571_214, sha256: "34f872ce724ca1ff0a4afca481853e5ee74250f8cb22153e499f953562846039", unpack: Some("whisper") },
    Download { key: "whisper-model", label: "Speech-to-text model (whisper base.en)", file: "ggml-base.en.bin",
        url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin",
        size: 147_964_211, sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", unpack: None },
    Download { key: "model", label: "AI model (Inkling 2 Mini, 2-bit)", file: "inkling-2-mini-q2kxl.gguf",
        url: "https://huggingface.co/unsloth/Inkling-2-Mini-GGUF/resolve/8078d149286eec7193795413b9e0643da6d11fa1/Mainline_Support/Inkling-2-Mini-UD-Q2_K_XL.gguf_file",
        size: 9_138_716_608, sha256: "b42841608ea380ddde5a3f1125081357128a3c71b80d006246de4e31292fc6c1", unpack: None },
];

/// The layout tested on an 8 GB-class NVIDIA GPU (peak 7.07 GB): some expert layers stay in system RAM.
const SERVER_ARGS: &[&str] = &["--ctx-size", "20480", "-ngl", "99", "-fa", "on", "-ctk", "q8_0", "-ctv", "q8_0", "-cram", "2048",
    "-ub", "256", "-b", "256", "-t", "8", "--parallel", "1", "-lm", "none", "-lzm", "off", "--fit", "off",
    "-ot", r"^blk\.([0-5]|1[89]|2[0-3])\.ffn_(gate_up|gate|up|down)_exps\.weight$=CPU"];
const MIN_VRAM_MB: u64 = 7_000;

static RUNNING: AtomicBool = AtomicBool::new(false);

pub(crate) fn engine_root() -> PathBuf {
    // Not inside %LOCALAPPDATA%\Inferoid: that is the app's install folder, which an update reinstalls.
    std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(".")).join("Inferoid Engine")
}

#[derive(Serialize, Clone)]
pub(crate) struct SetupStatus {
    configured: bool,
    gpu: Option<String>,
    #[serde(rename = "vramMb")]
    vram_mb: Option<u64>,
    supported: bool,
    reason: String,
    #[serde(rename = "totalBytes")]
    total_bytes: u64,
    running: bool,
}

#[derive(Serialize, Clone)]
struct Progress {
    key: String,
    label: String,
    phase: String,
    done: u64,
    total: u64,
}

/// "NVIDIA GeForce RTX 4070 Laptop GPU, 8188" from nvidia-smi (None without an NVIDIA driver).
pub(crate) fn detect_gpu() -> Option<(String, u64)> {
    let mut command = Command::new("nvidia-smi");
    command.args(["--query-gpu=name,memory.total", "--format=csv,noheader,nounits"]);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let output = command.output().ok()?;
    if !output.status.success() { return None; }
    parse_gpu(&String::from_utf8_lossy(&output.stdout))
}

pub(crate) fn parse_gpu(text: &str) -> Option<(String, u64)> {
    text.lines().filter_map(|line| {
        let (name, memory) = line.rsplit_once(',')?;
        Some((name.trim().to_string(), memory.trim().parse::<u64>().ok()?))
    }).max_by_key(|(_, memory)| *memory)
}

/// engine.json exists and every file it points to is there.
pub(crate) fn is_configured() -> bool {
    let config = super::load_engine_config();
    if config.model_path.is_empty() { return false; }
    let mut paths = vec![config.model_path.clone()];
    if let Some(p) = config.llama_server_path.clone() { paths.push(p); }
    paths.iter().all(|p| Path::new(p).exists())
}

#[tauri::command]
pub(crate) fn setup_status() -> SetupStatus {
    let gpu = detect_gpu();
    let (supported, reason) = match &gpu {
        None => (false, "Inferoid for Windows needs an NVIDIA GPU with 8 GB of memory (RTX 3060 / 4060 or newer) and its driver.".to_string()),
        Some((name, mb)) if *mb < MIN_VRAM_MB => (false, format!("{name} has {} GB of GPU memory; Inferoid needs 8 GB.", mb / 1024)),
        Some(_) => (true, String::new()),
    };
    SetupStatus {
        configured: is_configured(),
        gpu: gpu.as_ref().map(|g| g.0.clone()),
        vram_mb: gpu.as_ref().map(|g| g.1),
        supported,
        reason,
        total_bytes: DOWNLOADS.iter().map(|d| d.size).sum(),
        running: RUNNING.load(Ordering::SeqCst),
    }
}

/// Downloads, verifies and unpacks everything, then writes engine.json. `only` limits it to some keys (model update).
pub(crate) fn install(app: &AppHandle, only: Option<&[&str]>) -> Result<(), String> {
    if RUNNING.swap(true, Ordering::SeqCst) { return Err("Setup is already running.".into()); }
    let result = install_inner(app, only);
    RUNNING.store(false, Ordering::SeqCst);
    result
}

fn install_inner(app: &AppHandle, only: Option<&[&str]>) -> Result<(), String> {
    let root = engine_root();
    let downloads = root.join("downloads");
    fs::create_dir_all(&downloads).map_err(|e| e.to_string())?;
    let client = reqwest::blocking::Client::builder()
        .user_agent("Inferoid-Windows")
        .connect_timeout(Duration::from_secs(20))
        .timeout(None)
        .build()
        .map_err(|e| e.to_string())?;
    for item in DOWNLOADS.iter().filter(|d| only.map(|keys| keys.contains(&d.key)).unwrap_or(true)) {
        let path = downloads.join(item.file);
        if !(path.exists() && file_size(&path) == item.size && sha256_file(&path, app, item)? == item.sha256) {
            fetch(&client, item, &path, app)?;
            let digest = sha256_file(&path, app, item)?;
            if digest != item.sha256 {
                let _ = fs::remove_file(&path);
                return Err(format!("{} did not match its checksum. Run setup again.", item.label));
            }
        }
        if let Some(folder) = item.unpack {
            emit(app, item, "Unpacking", 0, 1);
            unpack(&path, &root.join(folder))?;
        }
        emit(app, item, "Done", item.size, item.size);
    }
    write_engine_json(&root)?;
    // Keep the model and whisper model; the zips can go once unpacked.
    for item in DOWNLOADS.iter().filter(|d| d.unpack.is_some()) { let _ = fs::remove_file(downloads.join(item.file)); }
    Ok(())
}

fn emit(app: &AppHandle, item: &Download, phase: &str, done: u64, total: u64) {
    let _ = app.emit("setup-progress", Progress { key: item.key.into(), label: item.label.into(), phase: phase.into(), done, total });
}

fn file_size(path: &Path) -> u64 { fs::metadata(path).map(|m| m.len()).unwrap_or(0) }

/// Download into `<file>.part`, resuming from its current size with an HTTP Range request (retried up to 5 times).
fn fetch(client: &reqwest::blocking::Client, item: &Download, path: &Path, app: &AppHandle) -> Result<(), String> {
    let part = path.with_extension("part");
    let mut attempts = 0;
    loop {
        attempts += 1;
        let have = file_size(&part);
        if have >= item.size && have > 0 { break; }
        let mut request = client.get(item.url);
        if have > 0 { request = request.header("Range", format!("bytes={have}-")); }
        let outcome = (|| -> Result<(), String> {
            let mut response = request.send().map_err(|e| e.to_string())?;
            let status = response.status();
            if !(status.is_success()) { return Err(format!("{} returned {}", item.label, status)); }
            let resumed = status.as_u16() == 206;
            let mut file = if resumed {
                OpenOptions::new().append(true).open(&part).map_err(|e| e.to_string())?
            } else {
                File::create(&part).map_err(|e| e.to_string())?
            };
            let mut done = if resumed { have } else { 0 };
            let mut buffer = vec![0u8; 1 << 20];
            let mut last = Instant::now();
            loop {
                let read = response.read(&mut buffer).map_err(|e| e.to_string())?;
                if read == 0 { break; }
                file.write_all(&buffer[..read]).map_err(|e| e.to_string())?;
                done += read as u64;
                if last.elapsed() > Duration::from_millis(300) { emit(app, item, "Downloading", done, item.size); last = Instant::now(); }
            }
            file.flush().map_err(|e| e.to_string())?;
            Ok(())
        })();
        match outcome {
            Ok(()) if file_size(&part) >= item.size => break,
            Ok(()) | Err(_) if attempts < 6 => { std::thread::sleep(Duration::from_secs(3)); continue; }
            Ok(()) => return Err(format!("{} stopped downloading early. Check your connection and run setup again.", item.label)),
            Err(error) => return Err(format!("Couldn't download {} ({error}). Check your connection and run setup again.", item.label)),
        }
    }
    fs::rename(&part, path).map_err(|e| e.to_string())
}

fn sha256_file(path: &Path, app: &AppHandle, item: &Download) -> Result<String, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 4 << 20];
    let mut done = 0u64;
    let mut last = Instant::now();
    loop {
        let read = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if read == 0 { break; }
        hasher.update(&buffer[..read]);
        done += read as u64;
        if last.elapsed() > Duration::from_millis(300) { emit(app, item, "Checking", done, item.size); last = Instant::now(); }
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Extract every file of the zip into `dest`, flattening folders (the release zips keep exe and dlls together).
fn unpack(zip_path: &Path, dest: &Path) -> Result<(), String> {
    fs::create_dir_all(dest).map_err(|e| e.to_string())?;
    let file = File::open(zip_path).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(|e| e.to_string())?;
        if entry.is_dir() { continue; }
        let Some(name) = entry.enclosed_name().and_then(|p| p.file_name().map(|n| n.to_owned())) else { continue };
        let mut out = File::create(dest.join(name)).map_err(|e| e.to_string())?;
        std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn write_engine_json(root: &Path) -> Result<(), String> {
    let downloads = root.join("downloads");
    let config = serde_json::json!({
        "model_path": downloads.join("inkling-2-mini-q2kxl.gguf").to_string_lossy(),
        "whisper_model_path": downloads.join("ggml-base.en.bin").to_string_lossy(),
        "style": "inkling",
        "llama_server_path": root.join("llama").join("llama-server.exe").to_string_lossy(),
        "whisper_path": root.join("whisper").join("whisper-cli.exe").to_string_lossy(),
        "server_args": SERVER_ARGS,
        "model_revision": MODEL_REVISION,
    });
    fs::create_dir_all(super::support_root()).map_err(|e| e.to_string())?;
    let text = serde_json::to_string_pretty(&config).map_err(|e| e.to_string())?;
    fs::write(super::support_root().join("engine.json"), text).map_err(|e| e.to_string())
}

#[tauri::command(async)]
pub(crate) fn run_setup(app: AppHandle) -> Result<(), String> { install(&app, None) }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gpu_line_parses_and_picks_the_largest() {
        assert_eq!(parse_gpu("NVIDIA GeForce RTX 4070 Laptop GPU, 8188\n"), Some(("NVIDIA GeForce RTX 4070 Laptop GPU".into(), 8188)));
        assert_eq!(parse_gpu("Intel, 128\nNVIDIA RTX 3060, 12288\n").map(|g| g.1), Some(12288));
        assert_eq!(parse_gpu(""), None);
    }

    #[test]
    fn downloads_are_pinned() {
        assert!(DOWNLOADS.iter().all(|d| d.sha256.len() == 64 && d.size > 0));
        assert!(DOWNLOADS.iter().any(|d| d.key == "model" && d.url.contains(MODEL_REVISION)));
    }
}
