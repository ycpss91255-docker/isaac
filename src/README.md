# isaac — workspace

NVIDIA Isaac Sim workspace content (scripts, docs, USD/URDF models) for `ycpss91255-docker/isaac`.

This directory holds the editable content (driver scripts, documentation, 3D models) that runs inside the Isaac Sim Docker development environment defined at the repo root. It used to be a separate repo, `ycpss91255-research/isaac`, which wrapped the Docker environment as a `docker/` submodule. Both were merged into this single repo per [#78](https://github.com/ycpss91255-docker/isaac/issues/78), and the research repo is archived.

**[English](README.md)** | **[繁體中文](doc/readme/README.zh-TW.md)** | **[简体中文](doc/readme/README.zh-CN.md)** | **[日本語](doc/readme/README.ja.md)**

## Structure

```
src/
├── README.md      # This file (English)
├── LICENSE
├── config/        # Sensor / scene config
├── doc/           # Documentation, ADRs, SOPs
│   ├── readme/    # README translations
│   └── adr/       # Architecture Decision Records
├── scene/         # Scene definitions
├── script/        # Driver scripts (run inside Isaac Sim Kit / standalone Python)
└── model/         # 3D models
    ├── sw/        # SolidWorks raw source
    ├── urdf/      # URDF + mesh
    └── usd/       # Authored / converted USD
```

## Getting Started

```bash
git clone https://github.com/ycpss91255-docker/isaac.git
cd isaac
```

Then follow the [root README](../README.md) Quick Start to build and start the Isaac Sim container. The repo root is mounted at `/home/<your user>/work` inside the container, and that directory is the container's working directory. This directory is therefore at `~/work/src/`, and scripts run as `/isaac-sim/python.sh src/script/<name>.py`.

## License

[Apache-2.0](LICENSE)
