# isaac — workspace

NVIDIA Isaac Sim workspace 內容（scripts、文件、USD/URDF 模型），屬於 `ycpss91255-docker/isaac`。

本目錄收的是跑在 repo 根目錄定義的 Isaac Sim Docker 開發環境**內**的可編輯內容（driver scripts、文件、3D 模型）。它以前是獨立的 repo `ycpss91255-research/isaac`，以 `docker/` submodule 包著 Docker 環境；兩者已依 [#78](https://github.com/ycpss91255-docker/isaac/issues/78) 合併成這一個 repo，research repo 已封存。

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

## 目錄結構

```
src/
├── README.md      # 主 README（英文）
├── LICENSE
├── config/        # Sensor / scene 設定
├── doc/           # 文件、ADR、SOP
│   ├── readme/    # README 翻譯版本
│   └── adr/       # 架構決策紀錄（ADR）
├── scene/         # Scene 定義
├── script/        # Driver scripts（於 Isaac Sim Kit / standalone Python 內執行）
└── model/         # 3D 模型
    ├── sw/        # SolidWorks 原始檔
    ├── urdf/      # URDF + mesh
    └── usd/       # 自製或轉檔產生的 USD
```

## 上手

```bash
git clone https://github.com/ycpss91255-docker/isaac.git
cd isaac
```

接著依 [根目錄 README](../../../README.md) 的 Quick Start build 並啟動 Isaac Sim 容器。repo 根目錄會掛到容器內的 `/home/<你的使用者>/work`，也是容器的工作目錄，所以本目錄在容器內是 `~/work/src/`，script 以 `/isaac-sim/python.sh src/script/<name>.py` 執行。

## 授權

[Apache-2.0](../../LICENSE)
