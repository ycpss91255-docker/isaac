# isaac

NVIDIA Isaac Sim workspace 內容(scripts、文件、USD/URDF 模型),搭配 [ycpss91255-docker/isaac](https://github.com/ycpss91255-docker/isaac) 使用。

本 repo 收的是跑在 Isaac Sim Docker 開發環境**內**的可編輯內容(driver scripts、文件、3D 模型);Docker 環境本身以 submodule 的方式掛在 `docker/` 之下。

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

## 目錄結構

```
.
├── README.md       # 主 README(英文)
├── LICENSE
├── doc/            # 文件、ADR、SOP
│   ├── readme/     # README 翻譯版本
│   └── adr/        # 架構決策紀錄(ADR)
├── script/         # Driver scripts(於 Isaac Sim Kit / standalone Python 內執行)
├── model/          # 3D 模型
│   ├── sw/         # SolidWorks 原始檔
│   ├── urdf/       # URDF + mesh
│   └── usd/        # 自製或轉檔產生的 USD
└── docker/         # Submodule:ycpss91255-docker/isaac(Isaac Sim Docker 環境)
```

## 上手

連 submodule 一起 clone:

```bash
git clone --recurse-submodules https://github.com/ycpss91255/isaac.git
```

接著依 `docker/README.md` 啟動 Isaac Sim 開發容器。容器跑起來後,本 repo 內容會掛到容器內的 `/home/yunchien/work/src/`。

## 授權

[Apache-2.0](../../LICENSE)
