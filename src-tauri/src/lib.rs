// AI Desk —— Tauri 主体。
//
// v0.2.1 起这里不再有自动更新。原来集成了 Tauri updater
// （Rust 的 tauri-plugin-updater + JS 的 @tauri-apps/plugin-updater），但端点写的是
// 开发期的 http://127.0.0.1:8787/latest.json，发布流程里也没有任何一步会上传
// 更新包或 latest.json —— 对用户从来没生效过，只会在每次启动时白跑一次必然
// 失败的请求、并往 ~/.ai-desk-update.log 记一行。升级改为重新跑一次 gpm 分发
// 包（覆盖式安装），见 README 的「更新方式」。
//
// 真要加回来的话，三件事别忘：Rust 侧与 JS 侧的版本必须钉同一个 major/minor
// （tauri-cli 会检查，否则直接拒绝构建）、端点与签名公钥写在
// src-tauri/tauri.conf.json 的 plugins.updater 里、发布流程里得真的把
// .app.tar.gz / .sig 与 latest.json 传上去。

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/
#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![greet])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
