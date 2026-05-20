# isaac

NVIDIA Isaac Sim workspace content (scripts, docs, USD/URDF models) for [ycpss91255-docker/isaac](https://github.com/ycpss91255-docker/isaac).

This repository holds the editable content (driver scripts, documentation, 3D models) that runs inside the Isaac Sim Docker development environment. The Docker environment itself is consumed here as a submodule under `docker/`.

Other language versions: [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

## Structure

```
.
├── doc/        # Documentation, ADRs, SOPs
├── script/     # Driver scripts (run inside Isaac Sim Kit / standalone Python)
├── model/      # 3D models
│   ├── sw/     # SolidWorks raw source
│   ├── urdf/   # URDF + mesh
│   └── usd/    # Authored / converted USD
└── docker/     # Submodule: ycpss91255-docker/isaac (Isaac Sim Docker env)
```

## Getting Started

Clone with the submodule:

```bash
git clone --recurse-submodules https://github.com/ycpss91255/isaac.git
```

Then follow the setup steps in `docker/README.md` to bring up the Isaac Sim development container. Once the container is running, this repository's content is mounted into the container at `/home/yunchien/work/src/`.

## License

[Apache-2.0](LICENSE)
