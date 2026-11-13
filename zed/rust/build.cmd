@echo off
rem Rebuilds ..\extension.wasm from src\lib.rs. Only for changing lib.rs: the extension.wasm in
rem the repo is what Zed loads, so installing the extension needs no Rust.
rem   build.cmd       needs Rust (rustup.rs); adds the wasm32-wasip2 target once
setlocal
cd /d "%~dp0"
rustup target add wasm32-wasip2 || exit /b 1
cargo build --release --target wasm32-wasip2 || exit /b 1
copy /y target\wasm32-wasip2\release\zed_delphipp.wasm ..\extension.wasm >nul || exit /b 1
echo built: zed\extension.wasm
