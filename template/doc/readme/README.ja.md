# template

[![Self Test](https://github.com/ycpss91255-docker/template/actions/workflows/self-test.yaml/badge.svg)](https://github.com/ycpss91255-docker/template/actions/workflows/self-test.yaml)
[![codecov](https://codecov.io/gh/ycpss91255-docker/template/branch/main/graph/badge.svg)](https://codecov.io/gh/ycpss91255-docker/template)

![Language](https://img.shields.io/badge/Language-Bash-blue?style=flat-square)
![Testing](https://img.shields.io/badge/Testing-Bats-orange?style=flat-square)
![ShellCheck](https://img.shields.io/badge/ShellCheck-Compliant-brightgreen?style=flat-square)
![Coverage](https://img.shields.io/badge/Coverage-Kcov-blueviolet?style=flat-square)
[![License](https://img.shields.io/badge/License-GPL--3.0-yellow?style=flat-square)](./LICENSE)

[ycpss91255-docker](https://github.com/ycpss91255-docker) 組織のすべての Docker コンテナ repo 用共有テンプレート。

**[English](../../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

---

## 目次

- [TL;DR](#tldr)
- [概要](#概要)
- [クイックスタート](#クイックスタート)
- [CI Reusable Workflows](#ci-reusable-workflows)
- [ローカルテスト実行](#ローカルテスト実行)
- [テスト](#テスト)
- [ディレクトリ構造](#ディレクトリ構造)

---

## TL;DR

```bash
# ゼロからの新規 repo：init + 初回コミット + subtree + init.sh
mkdir <repo_name> && cd <repo_name>
git init
git commit --allow-empty -m "chore: initial commit"
git subtree add --prefix=template \
    https://github.com/ycpss91255-docker/template.git main --squash
./template/init.sh

# 最新版にアップグレード
make upgrade-check   # 確認
make upgrade         # pull + バージョンファイル + workflow tag 更新

# CI 実行
make test            # ShellCheck + Bats + Kcov
make help            # 全コマンド表示
```

## 概要

本 repo は、すべての Docker コンテナ repo で共有されるスクリプト、テスト、CI workflow を一元管理しています。15 以上の repo で同一ファイルを個別管理する代わりに、各 repo が **git subtree** としてこのテンプレートを取り込み、symlink で参照します。

### アーキテクチャ

```mermaid
graph TB
    subgraph template["template（共有 repo）"]
        scripts[".hadolint.yaml / Makefile.ci / compose.yaml"]
        smoke["test/smoke/<br/>script_help.bats<br/>display_env.bats"]
        config["config/<br/>bashrc / tmux / terminator / pip"]
        mgmt["script/docker/<br/>build.sh / run.sh / exec.sh / stop.sh / setup.sh"]
        workflows["再利用可能な Workflows<br/>build-worker.yaml<br/>release-worker.yaml"]
    end

    subgraph consumer["Docker Repo（例: ros_noetic）"]
        symlinks["build.sh → template/script/docker/build.sh<br/>run.sh → template/script/docker/run.sh<br/>exec.sh / stop.sh / .hadolint.yaml"]
        dockerfile["Dockerfile<br/>compose.yaml<br/>.env.example<br/>script/entrypoint.sh"]
        repo_test["test/smoke/<br/>ros_env.bats（repo 固有）"]
        main_yaml["main.yaml<br/>→ 再利用可能な workflows を呼び出し"]
    end

    template -- "git subtree" --> consumer
    scripts -. "symlink" .-> symlinks
    smoke -. "Dockerfile COPY" .-> repo_test
    workflows -. "@tag 参照" .-> main_yaml
```

### CI/CD フロー

```mermaid
flowchart LR
    subgraph local["ローカル"]
        build_test["./build.sh test"]
        make_test["make test"]
    end

    subgraph ci_container["CI コンテナ（kcov/kcov）"]
        shellcheck["ShellCheck"]
        hadolint["Hadolint"]
        bats["Bats smoke tests"]
    end

    subgraph github["GitHub Actions"]
        build_worker["build-worker.yaml<br/>（template より）"]
        release_worker["release-worker.yaml<br/>（template より）"]
    end

    build_test --> ci_container
    make_test -->|"script/ci/ci.sh"| ci_container
    shellcheck --> hadolint --> bats

    push["git push / PR"] --> build_worker
    build_worker -->|"docker build test"| ci_container
    tag["git tag v*"] --> release_worker
    release_worker -->|"tar.gz + zip"| release["GitHub Release"]
```

### 含まれるもの

| ファイル | 説明 |
|----------|------|
| `build.sh` | コンテナビルド（`--setup` は TTY がある場合 `setup_tui.sh` を起動、無ければ `setup.sh` を実行） |
| `run.sh` | コンテナ実行（X11/Wayland 対応；`--setup` の意味は `build.sh` と同じ） |
| `exec.sh` | 実行中のコンテナに入る |
| `stop.sh` | コンテナの停止・削除 |
| `setup_tui.sh` | インタラクティブな setup.conf エディタ（dialog / whiptail フロントエンド） |
| `script/docker/setup.sh` | システムパラメータの自動検出と `.env` + `compose.yaml` 生成 |
| `script/docker/_tui_backend.sh` | `setup_tui.sh` が使用する dialog / whiptail ラッパ関数 |
| `script/docker/_tui_conf.sh` | INI バリデータ + 読み書き（`setup_tui.sh` と `setup.sh` の書き戻し用） |
| `script/docker/_lib.sh` | 共有 helper（`_load_env`、`_compose`、`_compose_project` など） |
| `script/docker/i18n.sh` | 共有言語検出（`_detect_lang`、`_LANG`） |
| `config/` | コンテナ内部のシェル設定ファイル（bashrc、tmux、terminator、pip） |
| `setup.conf` | 単一の repo ランタイム設定（image / build / deploy / gui / network / volumes） |
| `test/smoke/` | 共有 smoke テスト + runtime assertion helpers（下記参照） |
| `test/unit/` | Template 自身のテスト（bats + kcov） |
| `test/integration/` | Level-1 `init.sh` 統合テスト |
| `.hadolint.yaml` | 共有 Hadolint ルール |
| `Makefile` | Repo コマンドエントリ（`make build`、`make run`、`make stop` 等） |
| `Makefile.ci` | Template CI コマンドエントリ（`make test`、`make lint` 等） |
| `init.sh` | 初回 symlink セットアップ + 新 repo スケルトン生成 |
| `upgrade.sh` | Subtree バージョンアップグレード |
| `script/ci/ci.sh` | CI パイプライン（ローカル + リモート） |
| `dockerfile/Dockerfile.example` | 新 repo のマルチステージ Dockerfile テンプレート |
| `dockerfile/Dockerfile.test-tools` | プリビルド lint/test ツール image（shellcheck、hadolint、bats、bats-mock） |
| `.github/workflows/` | 再利用可能な CI workflows（build + release） |

### Dockerfile ステージ（規約）

ダウンストリーム repo は `dockerfile/Dockerfile.example` で定義される標準のマルチステージ構成に従います。
すべてのステージは `ARG BASE_IMAGE` で指定されるベース image を共有します。

| ステージ | 親ステージ | 用途 | 出荷 |
|----------|------------|------|------|
| `sys` | `${BASE_IMAGE}` | ユーザー/グループ、sudo、タイムゾーン、ロケール、APT mirror | 中間 |
| `base` | `sys` | 開発ツールと言語パッケージ | 中間 |
| `devel` | `base` | アプリ固有ツール + `entrypoint.sh` + PlotJuggler（env repos） | **はい**（主成果物） |
| `test` | `devel` | 一時的：ShellCheck + Hadolint + Bats smoke（いずれも `test-tools:local` から） | いいえ（build 後破棄） |
| `runtime-base`（任意） | `sys` | 最小 runtime 依存（sudo、tini） | 中間 |
| `runtime`（任意） | `runtime-base` | 軽量 runtime image（application repos で使用） | 有効時に出荷 |

補足：
- developer image のみを出荷する repo（`env/*`）は `runtime-base` /
  `runtime` をスキップし、該当セクションは `Dockerfile.example` 内で
  コメントアウトしたままにします。
- `test` は常に `devel` を継承するため、`test/smoke/<repo>_env.bats` の
  runtime assertion が確認するバイナリやファイルは、ユーザーが
  `docker run ... <repo>:devel` で目にするものと一致します。
- `Dockerfile.test-tools` は lint/test ツールセット（bats + shellcheck + hadolint）をビルドします。ダウンストリームの `test` ステージは `ARG TEST_TOOLS_IMAGE` build arg で参照します — デフォルト `test-tools:local`（ローカル `./build.sh` フロー、`Dockerfile.test-tools` を host Docker daemon に load）。CI では `ghcr.io/ycpss91255-docker/test-tools:vX.Y.Z`（`.github/workflows/release-test-tools.yaml` がタグ push ごとに publish するマルチアーキ image）で override し、buildx が registry からアーキ対応の bats / shellcheck / hadolint binary を直接 pull します。`docker-container` buildx driver の step 間 image store 分離問題を回避。

### Smoke test ヘルパー（ダウンストリーム repo 用）

`test/smoke/test_helper.bash`（各 smoke spec が
`load "${BATS_TEST_DIRNAME}/test_helper"` で読み込み）が runtime
assertion helpers のセットを提供します。ダウンストリーム repo は
素の `[ -f ... ]` / `command -v` より優先してこれらの helper を使用
すべきです。失敗時は欠落している成果物を直接指し示す decorated な
診断メッセージを出力します。

| Helper | 用法 |
|--------|------|
| `assert_cmd_installed <cmd>` | `<cmd>` が `PATH` 上にない場合に失敗 |
| `assert_cmd_runs <cmd> [flag]` | `<cmd> <flag>` が 0 以外で終了した場合に失敗（flag のデフォルトは `--version`） |
| `assert_file_exists <path>` | `<path>` が通常ファイルでない場合に失敗 |
| `assert_dir_exists <path>` | `<path>` がディレクトリでない場合に失敗 |
| `assert_file_owned_by <user> <path>` | `<path>` の所有者が `<user>` でない場合に失敗 |
| `assert_pip_pkg <pkg>` | `pip show <pkg>` が 0 以外で終了した場合に失敗 |

### 各 repo で個別管理するファイル（共有しない）

- `Dockerfile`
- `compose.yaml`
- `.env.example`
- `script/entrypoint.sh`
- `doc/` と `README.md`
- Repo 固有の smoke test

## repo ごとのランタイム設定

各下流 repo は 1 つの `setup.conf` INI ファイルで自身のランタイム設定
（GPU 予約 / GUI env/volumes / network mode / 追加 volume mounts）を
駆動します。`setup.sh` がこれ + システム検出結果を読み、`.env` と
`compose.yaml` を再生成します — この 2 つの生成物をユーザが手動編集
する必要はありません。

### 単一 conf、6 つの section

```
[image]    rules = prefix:docker_, suffix:_ws, @default:unknown
[build]    apt_mirror_ubuntu、apt_mirror_debian            # Dockerfile build args
[deploy]   gpu_mode (auto|force|off)、gpu_count、gpu_capabilities
[gui]      mode (auto|force|off)
[network]  mode (host|bridge|none)、ipc、privileged
[volumes]  mount_1（workspace、初回 setup.sh 実行時に自動記入）
           mount_2..mount_N（ユーザ定義の追加 host mount；/dev デバイスは path 指定）
```

テンプレート既定値は `template/setup.conf`；repo ごとの上書きは
`<repo>/setup.conf`。セクションレベル **replace** 戦略：repo ファイルに
section があれば template の section を全置換；無ければ template 既定値を継承。

初回の `setup.sh` 実行時（repo 側の setup.conf がまだ無い状態）、
template ファイルが repo にコピーされ、検出された workspace が
`[volumes] mount_1` に書き込まれます。以降の実行は `mount_1` を
真のソースとして扱います — 空にすれば workspace マウントを
オプトアウトできます。編集方法：

```bash
./setup_tui.sh                      # インタラクティブな dialog/whiptail エディタ
./setup_tui.sh volumes              # 特定 section に直接ジャンプ
./build.sh --setup            # TTY 下では setup_tui.sh を起動、それ以外は setup.sh を実行
./template/init.sh --gen-conf # template/setup.conf を repo ルートに単純コピー
```

### インタラクティブ TUI

`./setup_tui.sh` はメインメニューを開き、6 つの section すべての値を
編集できます。バックエンドは `dialog` または `whiptail`（どちらも
無い場合は `sudo apt install dialog` のヒントを表示して終了）。
Cancel / Esc で保存せず退出；保存後は自動的に `setup.sh` を呼び
出して `.env` + `compose.yaml` を再生成します。

### setup.sh の実行タイミング

`setup.sh` は明示的にトリガーされた時のみ実行されます — build / run
の度に再実行されることはありません：

- **`./template/init.sh`** がスケルトン生成後に 1 回自動実行
- **`make upgrade` / `./template/upgrade.sh`** が subtree pull の後に
  init.sh 経由でもう一度実行されるため、アップグレードは常に新しい
  baseline で `.env` / `compose.yaml` を再生成した状態で着地します
- **`./build.sh --setup` / `./run.sh --setup`**（または `-s`）— ユーザが
  明示的に再実行。TTY がある場合は先に `setup_tui.sh` を起動して `setup.conf`
  を編集させ、TTY が無い場合は直接 `setup.sh` を呼び出します
- **初回 bootstrap**：`./build.sh` / `./run.sh` は `.env` が無い初回実行
  （CI の新規 clone 等）では、同じ TTY-aware フローを自動で通ります。
  `--setup` 指定は不要

`setup.sh apply` は毎回 `compose.yaml` をゼロから書き直しますが、
既存 `.env` の `WS_PATH` / `APT_MIRROR_UBUNTU` / `APT_MIRROR_DEBIAN` は
保持されるため、手動で調整した workspace パスや apt mirror はアップ
グレードで上書きされません。

### ドリフト検出

`setup.sh` は `.env` に `SETUP_CONF_HASH` / `SETUP_GUI_DETECTED` /
`SETUP_TIMESTAMP` を書き込みます。`./build.sh` / `./run.sh` は毎回
エントリ時点で現行の `setup.conf` ハッシュ + システム検出値と比較し、
以下のいずれかが変化した場合に `[WARNING]` を出力（実行は継続）：

- `setup.conf` の内容（conf hash）
- GPU / GUI の検出結果
- `USER_UID`（ユーザ ID の変化）

`--setup` を付けて再実行すれば `.env` + `compose.yaml` を再生成できます。

### setup.sh のサブコマンド（v0.11.0+）

`setup.sh` は git スタイルのバックエンドで、明示的なサブコマンドを提供します。build / run / TUI スクリプトが内部で呼び出してくれるので、直接呼び出すのはスクリプト化 / 非対話シナリオでの利用が想定されています：

| サブコマンド | 用途 |
|---|---|
| `apply` | setup.conf + システム検出から `.env` + `compose.yaml` を再生成 |
| `check-drift` | 同期なら 0、ドリフトしていれば 1（ドリフト内容は stderr） |
| `set <section>.<key> <value>` | 単一キーを書き込む |
| `show <section>[.<key>]` | 単一キーまたは section 全体を読み取る |
| `list [<section>]` | INI スタイルでダンプ |
| `add <section>.<list> <value>` | リスト型 section（`mount_*` / `env_*` / `port_*` …）に追加；空きスロット優先、無ければ `max+1` |
| `remove <section>.<key>` / `<section>.<list> <value>` | キー指定または値マッチで削除 |
| `reset [-y\|--yes]` | テンプレートのデフォルトに戻す；旧 `setup.conf` → `setup.conf.bak`、旧 `.env` → `.env.bak` |

型付きキーは `_tui_conf.sh` のバリデータ（TUI と同じもの）を経由します。`set` / `add` / `remove` / `reset` は **`.env` を自動再生成しません** — 必要に応じて `apply` を続けて呼ぶか、次回 `build.sh` / `run.sh` の drift 検出で自動再生成されます。

#### v0.10.x からの移行（BREAKING）

`setup.sh`（引数なし）と `setup.sh --base-path X --lang Y`（サブコマンドなし）は従来サイレントに `apply` にフォールスルーしていました。v0.11.0 でこのフォールスルーを廃止：

| 呼び出し方 | v0.11 以前 | v0.11+ |
|---|---|---|
| `setup.sh` | apply 実行 | help を表示して exit 0 |
| `setup.sh --base-path X --lang Y` | apply 実行 | exit 1「Unknown subcommand」 |
| `setup.sh apply [...]` | apply 実行 | apply 実行（変更なし） |

下流 repo にカスタムスクリプトが `setup.sh` を直接呼び出している場合、先頭に `apply` を付けてください。template 同梱の `build.sh` / `run.sh` / `init.sh` / `setup_tui.sh` はすでに更新済みです。

### 生成物（gitignored）

- `.env` — ランタイム変数 + `SETUP_*` drift metadata
- `compose.yaml` — baseline + 条件ブロック込みの完全な compose

いつでも `compose.yaml` を開けば現在の完全なランタイム設定を確認できます。
両ファイルは `make upgrade` のたびに再生成されます（init.sh が subtree
pull 後に `setup.sh apply` を再実行）— 手動編集はしないでください。
override は `setup.conf` に書きます。

## クイックスタート

### 新規 repo への追加

```bash
# 1. 空の repo を初期化（既存の repo でコミットが 1 つ以上ある場合はスキップ）
mkdir <repo_name> && cd <repo_name>
git init
git commit --allow-empty -m "chore: initial commit"

# 2. subtree 追加
git subtree add --prefix=template \
    https://github.com/ycpss91255-docker/template.git main --squash

# 3. symlink 初期化（ワンコマンド）
./template/init.sh
```

> `git subtree add` は `HEAD` の存在を前提とします。`git init` 直後でコミットが無い repo では `ambiguous argument 'HEAD'` と `working tree has modifications` で失敗します。空コミットで `HEAD` を作成しておけば subtree がマージできます。

### アップグレード

前提条件：`git config user.name` / `user.email` が設定済みで、working tree
が merge / rebase / cherry-pick / revert 進行中ではないこと — upgrade.sh
は対処方針付きのメッセージを出して fail-fast し、中途半端な pull を防ぎます。

```bash
# 新バージョンの確認
make upgrade-check

# 最新にアップグレード（subtree pull + バージョンファイル + workflow tag）
make upgrade

# バージョン指定
make upgrade VERSION=v0.3.0
# 指定したバージョンが現在の local pin より古い場合（例：v0.12.0-rc1 から
# v0.11.0 への巻き戻し）は SemVer §11 に従って暗黙の downgrade として
# 拒否されます。意図的な rollback の場合は template/.version を手動編集
# してください。

# make が使えない場合のフォールバック
./template/upgrade.sh v0.3.0
```

`upgrade.sh` は一度に完結します：

1. `git subtree pull --prefix=template ... --squash`
2. Post-pull 整合性チェック — subtree マーカー（`template/.version`、
   `template/init.sh`、`template/script/docker/setup.sh`）が消えた場合は
   `git reset --hard` で rollback（旧 `git-subtree.sh` の destructive FF
   対策）
3. `./template/init.sh` 再実行：root symlinks（`build.sh` / `run.sh`
   / `Makefile` …）の再同期、`.gitignore` を canonical entry set に
   同期、derived artifact になった旧 tracked ファイル（`.env`、
   `compose.yaml`、…）を `git rm --cached`、最後に `setup.sh apply` を
   呼んで `.env` + `compose.yaml` を再生成
4. `sed` で `.github/workflows/main.yaml` の
   `build-worker.yaml@vX.Y.Z` / `release-worker.yaml@vX.Y.Z` を更新

per-repo のファイルは上書きされません：`<repo>/setup.conf` はそのまま
保持され、`<repo>/config/`（bashrc / tmux / terminator …）も触りません
— 上流の `template/config/` が前回 pull 以降変わっていれば、
upgrade.sh が `diff -ruN template/config config` のヒントを表示するの
で、必要に応じて手動で reconcile してください。

手動で `git subtree pull` しないでください — 整合性チェック、init.sh
resync、sed の手順は忘れがちです。

#### 自動バージョン更新（任意）

ダウンストリーム repo は、`template` の新しい tag が出るたびに Dependabot が PR を立てるよう設定できます。`.github/dependabot.yml` を追加します：

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```

Dependabot は `main.yaml` 内の `uses: ycpss91255-docker/template/...@vX.Y.Z` ref を見て、template の最新 tag と照合して PR を出します。subtree 自体は引き続きローカルで `make upgrade VERSION=vX.Y.Z` を実行する必要があります — Dependabot が扱うのは workflow ref のみです。

## CI Reusable Workflows

各 repo のローカル `build-worker.yaml` / `release-worker.yaml` を、本 repo の reusable workflows 呼び出しに置き換えます：

```yaml
# .github/workflows/main.yaml
jobs:
  call-docker-build:
    uses: ycpss91255-docker/template/.github/workflows/build-worker.yaml@v1
    with:
      image_name: ros_noetic
      build_args: |
        ROS_DISTRO=noetic
        ROS_TAG=ros-base
        UBUNTU_CODENAME=focal

  call-release:
    needs: call-docker-build
    if: startsWith(github.ref, 'refs/tags/')
    uses: ycpss91255-docker/template/.github/workflows/release-worker.yaml@v1
    with:
      archive_name_prefix: ros_noetic
```

### build-worker.yaml パラメータ

| パラメータ | 型 | 必須 | デフォルト | 説明 |
|------------|------|------|------------|------|
| `image_name` | string | はい | - | コンテナイメージ名 |
| `build_args` | string | いいえ | `""` | 複数行 KEY=VALUE ビルド引数 |
| `build_runtime` | boolean | いいえ | `true` | runtime stage をビルドするか |
| `platforms` | string | いいえ | `"linux/amd64"` | カンマ区切りのターゲットプラットフォーム；各プラットフォームがネイティブ runner 上で並列実行（`linux/amd64` → ubuntu-latest、`linux/arm64` → ubuntu-24.04-arm） |
| `test_tools_version` | string | いいえ | `"latest"` | `ghcr.io/ycpss91255-docker/test-tools:<tag>` のタグ。下流側は採用した template release にピン留めすると再現性が確保できる |

### release-worker.yaml パラメータ

| パラメータ | 型 | 必須 | デフォルト | 説明 |
|------------|------|------|------------|------|
| `archive_name_prefix` | string | はい | - | アーカイブ名プレフィックス |
| `extra_files` | string | いいえ | `""` | 追加ファイル（スペース区切り） |

## ローカルテスト実行

`Makefile.ci`（template ルートから）を使用：
```bash
make -f Makefile.ci test        # フル CI（ShellCheck + Bats + Kcov）docker compose 経由
make -f Makefile.ci lint        # ShellCheck のみ
make -f Makefile.ci clean       # カバレッジレポート削除
make help        # repo ターゲット表示
make -f Makefile.ci help  # CI ターゲット表示
```

直接実行：
```bash
./script/ci/ci.sh          # フル CI（docker compose 経由）
./script/ci/ci.sh --ci     # コンテナ内で実行（compose から呼び出し）
```

## テスト

詳細は [TEST.md](../test/TEST.md) を参照。

## ディレクトリ構造

```
template/
├── init.sh                           # repo 初期化（新規または既存）
├── upgrade.sh                        # template subtree バージョンアップグレード
├── script/
│   ├── docker/                       # Docker 操作スクリプト（各 repo symlink）
│   │   ├── build.sh
│   │   ├── run.sh
│   │   ├── exec.sh
│   │   ├── stop.sh
│   │   ├── setup_tui.sh                    # インタラクティブな setup.conf エディタ（dialog/whiptail）
│   │   ├── setup.sh                  # .env + compose.yaml ジェネレータ
│   │   ├── _tui_backend.sh           # dialog / whiptail ラッパ関数
│   │   ├── _tui_conf.sh              # INI バリデータ + 読み書き
│   │   ├── _lib.sh                   # 共有 helper（_load_env、_compose、_compose_project）
│   │   ├── i18n.sh                   # 共有言語検出（_detect_lang、_LANG）
│   │   └── Makefile
│   └── ci/
│       └── ci.sh                     # CI パイプライン（ローカル + リモート）
├── dockerfile/
│   ├── Dockerfile.test-tools         # プリビルド lint/test ツール image
│   └── Dockerfile.example            # 新 repo の Dockerfile テンプレート（sys → base → devel → test → [runtime]）
├── setup.conf                        # 単一ランタイム設定（repo 上書き: <repo>/setup.conf）
├── config/                           # コンテナ内部のシェル / ツール設定
│   ├── image_name.conf               # デフォルト IMAGE_NAME 検出ルール
│   ├── pip/
│   │   ├── setup.sh
│   │   └── requirements.txt
│   └── shell/
│       ├── bashrc
│       ├── terminator/
│       │   ├── setup.sh
│       │   └── config
│       └── tmux/
│           ├── setup.sh
│           └── tmux.conf
├── test/
│   ├── smoke/                        # 共有 smoke テスト + runtime assertion helpers
│   │   ├── test_helper.bash          #  → assert_cmd_installed / _runs / file / dir / owned_by / pip_pkg
│   │   ├── script_help.bats
│   │   └── display_env.bats
│   ├── unit/                         # テンプレート自身のテスト（bats + kcov）
│   │   ├── test_helper.bash
│   │   ├── bashrc_spec.bats
│   │   ├── ci_spec.bats              # ci.sh _install_deps
│   │   ├── lib_spec.bats             # _lib.sh
│   │   ├── pip_setup_spec.bats
│   │   ├── setup_spec.bats
│   │   ├── smoke_helper_spec.bats    # Runtime assertion helpers
│   │   ├── template_spec.bats
│   │   ├── terminator_config_spec.bats
│   │   ├── terminator_setup_spec.bats
│   │   ├── tmux_conf_spec.bats
│   │   └── tmux_setup_spec.bats
│   └── integration/
│       └── init_new_repo_spec.bats   # Level-1 init.sh 統合テスト
├── Makefile.ci                       # テンプレート CI エントリ（make test/lint/...）
├── compose.yaml                      # Docker CI ランナー
├── .hadolint.yaml                    # 共有 Hadolint ルール
├── codecov.yml
├── .github/workflows/
│   ├── self-test.yaml                # テンプレート CI
│   ├── build-worker.yaml             # 再利用可能なビルド workflow
│   └── release-worker.yaml           # 再利用可能なリリース workflow
├── doc/
│   ├── readme/                       # README 翻訳（zh-TW / zh-CN / ja）
│   ├── test/TEST.md                  # テスト一覧
│   └── changelog/CHANGELOG.md        # リリース記録
├── .gitignore
├── LICENSE
└── README.md
```
