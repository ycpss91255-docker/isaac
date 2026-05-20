# isaac

NVIDIA Isaac Sim ワークスペースのコンテンツ(scripts、ドキュメント、USD/URDF モデル)。[ycpss91255-docker/isaac](https://github.com/ycpss91255-docker/isaac) と組み合わせて使います。

本 repo は Isaac Sim Docker 開発環境の**内側**で動く編集可能なコンテンツ(driver scripts、ドキュメント、3D モデル)を収めます。Docker 環境そのものは `docker/` 配下に submodule として組み込まれています。

他言語: [English](README.md) | [繁體中文](README.zh-TW.md) | [简体中文](README.zh-CN.md)

## ディレクトリ構成

```
.
├── doc/        # ドキュメント、ADR、SOP
├── script/     # Driver スクリプト(Isaac Sim Kit / standalone Python で実行)
├── model/      # 3D モデル
│   ├── sw/     # SolidWorks 元データ
│   ├── urdf/   # URDF + mesh
│   └── usd/    # 自作 / 変換生成の USD
└── docker/     # Submodule: ycpss91255-docker/isaac(Isaac Sim Docker 環境)
```

## はじめに

submodule も含めて clone:

```bash
git clone --recurse-submodules https://github.com/ycpss91255/isaac.git
```

その後 `docker/README.md` の手順に従って Isaac Sim 開発コンテナを起動します。コンテナ起動後、本 repo のコンテンツはコンテナ内の `/home/yunchien/work/src/` にマウントされます。

## ライセンス

[Apache-2.0](LICENSE)
