// AI Desk —— 主体与自动更新（Tauri updater）集成。
//
// 这里同时保留两条路，方便验证「用 cpi 装好之后自动更新能不能正常工作」：
//   1. 启动后自动检查（由 ~/.ai-desk-auto-update 这个试验开关驱动，可选自动安装 + 重启）；
//   2. 界面上的按钮（分别走 Rust 命令与官方 JS 插件）。
//
// 之所以用「文件」而不是「环境变量」当开关：经 LaunchServices / `open` 启动的
// app 拿不到调用方的环境变量，而 cpi 的 darwin 启动器默认正是 `exec open '<app>' --args "$@"`。

use std::io::Write as _;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tauri::AppHandle;
use tauri_plugin_updater::UpdaterExt;

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

/// 实验用的日志：默认写 ~/.ai-desk-update.log，可用 AI_DESK_UPDATE_LOG 改。
fn log_path() -> std::path::PathBuf {
    if let Some(p) = std::env::var_os("AI_DESK_UPDATE_LOG") {
        return p.into();
    }
    let home = std::env::var_os("HOME").unwrap_or_default();
    std::path::Path::new(&home).join(".ai-desk-update.log")
}

fn log(msg: &str) {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let line = format!("[{ms}] {msg}\n");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path())
    {
        let _ = f.write_all(line.as_bytes());
    }
    print!("{line}");
    let _ = std::io::stdout().flush();
}

/// 正在运行的这一份在磁盘上的位置 —— 自动更新就地替换的就是这个 .app 目录。
fn where_am_i() -> String {
    let Ok(exe) = std::env::current_exe() else {
        return "<取不到 current_exe>".into();
    };
    let bundle = exe
        .parent() // Contents/MacOS
        .and_then(|p| p.parent()) // Contents
        .and_then(|p| p.parent()) // X.app
        .map(|p| p.display().to_string())
        .unwrap_or_else(|| "<不在 .app 里>".into());
    format!("exe={} bundle={}", exe.display(), bundle)
}

/// 试验开关，文件内容为 `check` / `install` / `install-restart`（空 = 只查不装）。
fn auto_update_mode() -> String {
    if let Ok(v) = std::env::var("AI_DESK_AUTO_UPDATE") {
        if !v.trim().is_empty() {
            return v.trim().to_string();
        }
    }
    let home = std::env::var_os("HOME").unwrap_or_default();
    std::fs::read_to_string(std::path::Path::new(&home).join(".ai-desk-auto-update"))
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

async fn check_and_maybe_install(
    app: &AppHandle,
    install: bool,
    restart: bool,
) -> Result<String, String> {
    let updater = app.updater().map_err(|e| format!("拿不到 Updater: {e}"))?;
    let found = updater
        .check()
        .await
        .map_err(|e| format!("check 失败: {e}"))?;
    let Some(update) = found else {
        log("没有可用更新（已是最新）");
        return Ok("已经是最新版本".into());
    };
    log(&format!(
        "发现新版本 {} （当前 {}，target={}）下载地址 {}",
        update.version, update.current_version, update.target, update.download_url
    ));
    if !install {
        return Ok(format!("发现新版本 {}", update.version));
    }
    let mut got: usize = 0;
    update
        .download_and_install(
            |chunk, total| {
                got += chunk;
                match total {
                    Some(t) => log(&format!("下载中 {got}/{t}")),
                    None => log(&format!("下载中 {got}")),
                }
            },
            || log("下载完成，开始安装"),
        )
        .await
        .map_err(|e| format!("下载或安装失败: {e}"))?;
    log("安装完成");
    if restart {
        // 官方文档写明：macOS / Linux 上 download_and_install 之后需要自己重启。
        log("调用 app.restart() 重启到新版本");
        app.restart();
    }
    Ok(format!("已更新到 {}", update.version))
}

#[tauri::command]
async fn check_update(app: AppHandle) -> Result<String, String> {
    log("界面点了『检查更新』");
    check_and_maybe_install(&app, false, false).await
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![greet, check_update])
        .setup(|app| {
            let handle = app.handle().clone();
            let ver = app.package_info().version.to_string();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs(2));
                let mode = auto_update_mode();
                log(&format!(
                    "启动自动检查 version={ver} mode={mode:?} {}",
                    where_am_i()
                ));
                let install = mode == "install" || mode == "install-restart";
                let restart = mode == "install-restart";
                let r = tauri::async_runtime::block_on(check_and_maybe_install(
                    &handle, install, restart,
                ));
                log(&format!("自动检查结束 {r:?}"));
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
