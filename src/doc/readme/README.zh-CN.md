# isaac — workspace

NVIDIA Isaac Sim workspace 内容（scripts、文档、USD/URDF 模型），属于 `ycpss91255-docker/isaac`。

本目录收的是运行在 repo 根目录定义的 Isaac Sim Docker 开发环境**内**的可编辑内容（driver scripts、文档、3D 模型）。它以前是独立的 repo `ycpss91255-research/isaac`，以 `docker/` submodule 包着 Docker 环境；两者已依 [#78](https://github.com/ycpss91255-docker/isaac/issues/78) 合并成这一个 repo，research repo 已归档。

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

## 目录结构

```
src/
├── README.md      # 主 README（英文）
├── LICENSE
├── config/        # Sensor / scene 配置
├── doc/           # 文档、ADR、SOP
│   ├── readme/    # README 翻译版本
│   └── adr/       # 架构决策记录（ADR）
├── scene/         # Scene 定义
├── script/        # Driver scripts（在 Isaac Sim Kit / standalone Python 内执行）
└── model/         # 3D 模型
    ├── sw/        # SolidWorks 原始文件
    ├── urdf/      # URDF + mesh
    └── usd/       # 自制或转换生成的 USD
```

## 上手

```bash
git clone https://github.com/ycpss91255-docker/isaac.git
cd isaac
```

接着按 [根目录 README](../../../README.md) 的 Quick Start build 并启动 Isaac Sim 容器。repo 根目录会挂到容器内的 `/home/<你的用户>/work`，也是容器的工作目录，所以本目录在容器内是 `~/work/src/`，script 以 `/isaac-sim/python.sh src/script/<name>.py` 运行。

## 许可

[Apache-2.0](../../LICENSE)
