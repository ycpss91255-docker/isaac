# isaac

NVIDIA Isaac Sim workspace 内容(scripts、文档、USD/URDF 模型),搭配 [ycpss91255-docker/isaac](https://github.com/ycpss91255-docker/isaac) 使用。

本 repo 收的是跑在 Isaac Sim Docker 开发环境**内**的可编辑内容(driver scripts、文档、3D 模型);Docker 环境本身以 submodule 的方式挂在 `docker/` 之下。

其他语言:[English](README.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

## 目录结构

```
.
├── doc/        # 文档、ADR、SOP
├── script/     # Driver scripts(于 Isaac Sim Kit / standalone Python 内执行)
├── model/      # 3D 模型
│   ├── sw/     # SolidWorks 原始档
│   ├── urdf/   # URDF + mesh
│   └── usd/    # 自制或转档产生的 USD
└── docker/     # Submodule:ycpss91255-docker/isaac(Isaac Sim Docker 环境)
```

## 上手

连 submodule 一起 clone:

```bash
git clone --recurse-submodules https://github.com/ycpss91255/isaac.git
```

接着依 `docker/README.md` 启动 Isaac Sim 开发容器。容器跑起来后,本 repo 内容会挂到容器内的 `/home/yunchien/work/src/`。

## 授权

[Apache-2.0](LICENSE)
