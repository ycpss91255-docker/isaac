# isaac — workspace

NVIDIA Isaac Sim の workspace コンテンツ（scripts、ドキュメント、USD/URDF モデル）。`ycpss91255-docker/isaac` の一部。

このディレクトリには、repo ルートで定義された Isaac Sim Docker 開発環境の**中で**動く編集可能なコンテンツ（driver scripts、ドキュメント、3D モデル）が入っている。以前は独立した repo `ycpss91255-research/isaac` で、Docker 環境を `docker/` submodule として包んでいた。[#78](https://github.com/ycpss91255-docker/isaac/issues/78) で両者はこの 1 つの repo に統合され、research repo はアーカイブ済み。

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

## ディレクトリ構成

```
src/
├── README.md      # メイン README（英語）
├── LICENSE
├── config/        # Sensor / scene 設定
├── doc/           # ドキュメント、ADR、SOP
│   ├── readme/    # README 翻訳版
│   └── adr/       # アーキテクチャ決定記録（ADR）
├── scene/         # Scene 定義
├── script/        # Driver scripts（Isaac Sim Kit / standalone Python 内で実行）
└── model/         # 3D モデル
    ├── sw/        # SolidWorks 原本
    ├── urdf/      # URDF + mesh
    └── usd/       # 作成 / 変換した USD
```

## はじめに

```bash
git clone https://github.com/ycpss91255-docker/isaac.git
cd isaac
```

次に [ルート README](../../../README.md) の Quick Start に従って Isaac Sim コンテナを build・起動する。repo ルートはコンテナ内の `/home/<ユーザー名>/work` にマウントされ、そこがコンテナの作業ディレクトリになる。そのためこのディレクトリはコンテナ内では `~/work/src/` で、script は `/isaac-sim/python.sh src/script/<name>.py` で実行する。

## ライセンス

[Apache-2.0](../../LICENSE)
