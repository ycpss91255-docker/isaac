#!/usr/bin/env bash
#
# setup_tui.sh — interactive setup.conf editor (dialog / whiptail front-end).
#
# Usage:
#   ./setup_tui.sh                 # main menu
#   ./setup_tui.sh <section>       # jump directly to one section editor
#                            # image | build | network | deploy | gui | volumes
#   ./setup_tui.sh -h | --help     # show help
#   ./setup_tui.sh --lang <code>   # en | zh | zh-CN | ja
#
# On save, setup_tui.sh writes <repo>/setup.conf and exec()s setup.sh to
# regenerate .env + compose.yaml. Cancel / Esc exits 0 without saving.
#
# Style: Google Shell Style Guide.

set -euo pipefail

# ── Script / template paths (resolve symlink to locate siblings) ───────────
FILE_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly FILE_PATH

_TUI_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_TUI_SCRIPT_DIR="$(cd -- "$(dirname -- "${_TUI_SELF}")" && pwd -P)"
_TUI_TPL_DIR="$(cd -- "${_TUI_SCRIPT_DIR}/../.." && pwd -P)"

# shellcheck disable=SC1091
source "${_TUI_SCRIPT_DIR}/i18n.sh"
# shellcheck disable=SC1091
source "${_TUI_SCRIPT_DIR}/_tui_backend.sh"
# shellcheck disable=SC1091
source "${_TUI_SCRIPT_DIR}/_tui_conf.sh"

# ── Messages (4 languages) ────────────────────────────────────────────────
# Flat associative arrays per language. Key format: <ns>.<name>. Missing
# keys fall back to English.

declare -gA _TUI_MSG_EN=()
_TUI_MSG_EN[title]="Docker Container Configuration"
_TUI_MSG_EN[main.prompt]=""
_TUI_MSG_EN[main.image]="IMAGE_NAME detection rules"
_TUI_MSG_EN[main.build]="APT mirrors + Dockerfile build args"
_TUI_MSG_EN[main.network]="mode / ipc / name"
_TUI_MSG_EN[main.deploy]="GPU reservation"
_TUI_MSG_EN[main.gui]="display mode"
_TUI_MSG_EN[main.volumes]="workspace + extra mounts"
_TUI_MSG_EN[main.devices]="host device bindings"
_TUI_MSG_EN[main.environment]="runtime env vars"
_TUI_MSG_EN[main.tmpfs]="RAM-backed mounts"
_TUI_MSG_EN[main.advanced]="Advanced"
_TUI_MSG_EN[main.save]="Save & Exit"
_TUI_MSG_EN[main.security]="privileged / cap_add / security_opt"
_TUI_MSG_EN[main.additional_contexts]="Named build contexts (build.additional_contexts)"
_TUI_MSG_EN[advanced.title]="Advanced"
_TUI_MSG_EN[advanced.menu]="Select an advanced section"
_TUI_MSG_EN[advanced.back]="Back to main menu"
_TUI_MSG_EN[advanced.reset]="Reset to defaults"
_TUI_MSG_EN[reset.title]="Reset to defaults"
_TUI_MSG_EN[reset.confirm]=$'Reset ALL settings to template defaults?\n\n  - <repo>/setup.conf will be removed\n  - setup.sh re-runs to regenerate from template\n  - Your current customizations will be LOST\n\nThis cannot be undone.'
_TUI_MSG_EN[reset.done]="All settings reset to template defaults."
_TUI_MSG_EN[security.title]="Security"
_TUI_MSG_EN[security.menu]="Select: privileged / cap_add / cap_drop / security_opt"
_TUI_MSG_EN[security.back]="Back to main menu"
_TUI_MSG_EN[security.privileged.prompt]="Run container privileged?"
_TUI_MSG_EN[security.cap_add]="cap_add"
_TUI_MSG_EN[security.cap_add.menu]="Select a cap_add entry or Add one"
_TUI_MSG_EN[security.cap_add.add]="Add cap_add"
_TUI_MSG_EN[security.cap_add.prompt]=$'Capability to ADD\n  - Empty = delete this entry\n  - Common: SYS_ADMIN, NET_ADMIN, MKNOD, SYS_PTRACE'
_TUI_MSG_EN[security.cap_drop]="cap_drop"
_TUI_MSG_EN[security.cap_drop.menu]="Select a cap_drop entry or Add one"
_TUI_MSG_EN[security.cap_drop.add]="Add cap_drop"
_TUI_MSG_EN[security.cap_drop.prompt]=$'Capability to DROP\n  - Empty = delete this entry\n  - Example: ALL'
_TUI_MSG_EN[security.security_opt]="security_opt"
_TUI_MSG_EN[security.security_opt.menu]="Select a security_opt entry or Add one"
_TUI_MSG_EN[security.security_opt.add]="Add security_opt"
_TUI_MSG_EN[security.security_opt.prompt]=$'security_opt entry\n  - Empty = delete this entry\n  - Examples: seccomp:unconfined, apparmor:unconfined, label=disable'
_TUI_MSG_EN[image.title]="Image"
_TUI_MSG_EN[image.menu]="Select a rule to edit, or Add a new one"
_TUI_MSG_EN[image.add]="Add rule"
_TUI_MSG_EN[image.back]="Back to main menu"
_TUI_MSG_EN[image.type.prompt]="Rule type"
_TUI_MSG_EN[image.type.string]="string    (exact image name, skip path inference)"
_TUI_MSG_EN[image.type.prefix]="prefix    (strip leading <value> from dirname)"
_TUI_MSG_EN[image.type.suffix]="suffix    (strip trailing <value> from any path component)"
_TUI_MSG_EN[image.type.basename]="@basename (use dirname as-is, last-resort fallback)"
_TUI_MSG_EN[image.type.default]="@default  (use <value> when nothing else matches)"
_TUI_MSG_EN[image.type.move_up]="Move up   (swap with previous rule)"
_TUI_MSG_EN[image.type.move_down]="Move down (swap with next rule)"
_TUI_MSG_EN[image.type.remove]="Remove    (delete this rule)"
_TUI_MSG_EN[image.value.prompt]=$'Rule value\n  - Empty = cancel\n  - prefix / suffix / @default: strip or fall-back value\n  - string: exact image name (e.g. my_app)\n  - e.g. prefix:docker_ → enter: docker_'
_TUI_MSG_EN[build.title]="Build configuration"
_TUI_MSG_EN[build.menu]="Pick an item to edit"
_TUI_MSG_EN[build.add]="Add build arg"
_TUI_MSG_EN[build.back]="Back to main menu"
_TUI_MSG_EN[build.arg.prompt]=$'Build arg (Dockerfile ARG override)\n  - Format: KEY=VALUE (KEY must match [A-Z_][A-Z0-9_]*)\n  - Empty = delete this entry\n  - Known keys (Dockerfile provides defaults when left empty here):\n      APT_MIRROR_UBUNTU   default archive.ubuntu.com\n      APT_MIRROR_DEBIAN   default deb.debian.org\n      TZ                  default Asia/Taipei\n  - User-added: any KEY that your Dockerfile declares with `ARG KEY`\n  - Example: APT_MIRROR_UBUNTU=tw.archive.ubuntu.com\n  - Example: PYTHON_VERSION=3.12'
_TUI_MSG_EN[build.target_arch.label]="TARGETARCH override"
_TUI_MSG_EN[build.target_arch.prompt]=$'Docker TARGETARCH override\n  - Empty = let BuildKit auto-fill from host / --platform (default)\n  - amd64 / arm64 / arm / 386 / ppc64le / s390x / riscv64\n  - Applies to the main image + the test-tools image\n  - Pin when you need cross-builds or explicit control'
_TUI_MSG_EN[build.target_arch.auto]="(auto)"
_TUI_MSG_EN[build.network.label]="Build network"
_TUI_MSG_EN[build.network.prompt]=$'Docker build-time network (only the build stage; runtime is separate)\n  - auto = detect Jetson (/etc/nv_tegra_release) → host; desktop → Docker default (default)\n  - host = force host network stack. Required when bridge NAT is\n          unusable (stripped kernels, iptables: false, firewall-locked CI)\n  - bridge / none / default = explicit Docker modes\n  - off (or empty) = explicit opt-out; stay on Docker default bridge'
_TUI_MSG_EN[build.network.default]="(default: auto)"
_TUI_MSG_EN[build.args.label]="Extra build args"
_TUI_MSG_EN[err.invalid_target_arch]="Invalid TARGETARCH. Use empty or amd64 / arm64 / arm / 386 / ppc64le / s390x / riscv64."
_TUI_MSG_EN[err.invalid_build_network]="Invalid build network. Use auto / host / bridge / none / default / off (or empty)."
_TUI_MSG_EN[network.title]="Network"
_TUI_MSG_EN[network.mode.prompt]="Network mode"
_TUI_MSG_EN[network.mode.host]="host (share host network stack)"
_TUI_MSG_EN[network.mode.bridge]="bridge (isolated; can attach named network)"
_TUI_MSG_EN[network.mode.none]="none (no networking)"
_TUI_MSG_EN[network.ipc.prompt]="IPC namespace"
_TUI_MSG_EN[network.ipc.host]="host (share host IPC / shared memory)"
_TUI_MSG_EN[network.ipc.shareable]="shareable (own IPC, accessible to other containers)"
_TUI_MSG_EN[network.ipc.private]="private (own IPC, isolated — Docker default)"
_TUI_MSG_EN[network.priv.prompt]="Run container privileged?"
_TUI_MSG_EN[network.name.prompt]=$'Bridge network name\n  - Empty = compose auto-creates <project>_default bridge each run\n  - Non-empty = compose creates a bridge with this name (auto-managed)\n      Example: my_bridge\n        → compose creates <project>_my_bridge on up\n        → removed on down'
_TUI_MSG_EN[deploy.title]="Deploy"
_TUI_MSG_EN[deploy.mode.prompt]="GPU mode"
_TUI_MSG_EN[deploy.mode.auto]="auto (detect nvidia-container-toolkit)"
_TUI_MSG_EN[deploy.mode.force]="force (always emit GPU block)"
_TUI_MSG_EN[deploy.mode.off]="off (never emit GPU block)"
_TUI_MSG_EN[deploy.count.prompt]=$'GPU count\n  - \'all\' = reserve all host GPUs\n  - <N> = reserve N GPUs (1, 2, ...)\n  - Detected on host: %s'
_TUI_MSG_EN[deploy.caps.prompt]="GPU capabilities (Space to toggle)"
_TUI_MSG_EN[deploy.caps.gpu]="gpu (basic)"
_TUI_MSG_EN[deploy.caps.compute]="compute (CUDA compute)"
_TUI_MSG_EN[deploy.caps.utility]="utility (nvidia-smi, monitoring)"
_TUI_MSG_EN[deploy.caps.graphics]="graphics (OpenGL, Vulkan)"
_TUI_MSG_EN[deploy.runtime.prompt]="Docker runtime override (Jetson / csv-mode toolkit)"
_TUI_MSG_EN[deploy.runtime.auto]="auto (emit runtime: nvidia on Jetson — /etc/nv_tegra_release)"
_TUI_MSG_EN[deploy.runtime.nvidia]="nvidia (force emit on all hosts)"
_TUI_MSG_EN[deploy.runtime.off]="off (no runtime override — Docker default runc)"
_TUI_MSG_EN[deploy.mig.title]="Deploy — NVIDIA MIG detected"
_TUI_MSG_EN[deploy.mig.warning]=$'NVIDIA MIG (Multi-Instance GPU) mode is enabled on this host.\n\nDocker\'s deploy `count=N` reservation addresses whole GPUs; it cannot pin a specific MIG slice. To target one slice, leave count as-is and add to the [environment] section:\n  NVIDIA_VISIBLE_DEVICES=<MIG-UUID>\n\nAvailable GPU / MIG instances:\n%s'
_TUI_MSG_EN[gui.title]="GUI"
_TUI_MSG_EN[gui.mode.prompt]="GUI mode"
_TUI_MSG_EN[gui.mode.auto]="auto (detect \$DISPLAY / \$WAYLAND_DISPLAY)"
_TUI_MSG_EN[gui.mode.force]="force (always emit GUI block)"
_TUI_MSG_EN[gui.mode.off]="off (never emit GUI block)"
_TUI_MSG_EN[volumes.title]="Volumes"
_TUI_MSG_EN[volumes.menu]="Select a mount to edit, or Add a new one"
_TUI_MSG_EN[volumes.add]="Add mount"
_TUI_MSG_EN[volumes.edit.prompt]=$'Mount spec\n  - Format: <host>:<container>[:ro|rw]\n  - Empty = delete this entry\n  - Example: /data:/home/${USER_NAME}/data:rw'
_TUI_MSG_EN[volumes.delete.confirm]="Delete mount \"%s\"?"
_TUI_MSG_EN[volumes.back]="Back to main menu"
_TUI_MSG_EN[devices.title]="Devices"
_TUI_MSG_EN[devices.menu]="Pick which list to edit"
_TUI_MSG_EN[devices.edit_devices]="Device bindings (devices:)"
_TUI_MSG_EN[devices.edit_cgroup]="Cgroup rules (device_cgroup_rules:)"
_TUI_MSG_EN[devices.add_device]="Add device binding"
_TUI_MSG_EN[devices.add_cgroup]="Add cgroup rule"
_TUI_MSG_EN[devices.back]="Back to main menu"
_TUI_MSG_EN[devices.device.prompt]=$'Device binding\n  - Format: <host>[:<container>[:rwm]]\n  - Empty = delete this entry\n  - Default: /dev:/dev (bind whole /dev tree)\n  - Example (single): /dev/video0:/dev/video0'
_TUI_MSG_EN[devices.cgroup.title]="Cgroup rules"
_TUI_MSG_EN[devices.cgroup.menu]="Select an entry to edit, or Add a new cgroup rule"
_TUI_MSG_EN[devices.cgroup.prompt]=$'Cgroup rule\n  - Format: <type> <major>:<minor|*> <perms>\n    type: c (char), b (block), a (all)\n    perms: any of r / w / m\n  - Empty = delete this entry\n  - Example (USB): c 189:* rwm\n  - Example (V4L2): c 81:* rwm'
_TUI_MSG_EN[resources.title]="Resources"
_TUI_MSG_EN[resources.shm_size.prompt]=$'/dev/shm size\n  - Empty = Docker default (64mb)\n  - Examples: 2gb, 512mb\n  - Only applies when [network] ipc != host'
_TUI_MSG_EN[resources.shm_size.ignored]="Warning: [network] ipc is currently '%s'. Docker IGNORES shm_size unless ipc is 'private' or 'shareable'. Change ipc first if you need this value to take effect."
_TUI_MSG_EN[environment.title]="Environment"
_TUI_MSG_EN[environment.menu]="Select an env var to edit, or Add a new one"
_TUI_MSG_EN[environment.add]="Add env var"
_TUI_MSG_EN[environment.back]="Back to main menu"
_TUI_MSG_EN[environment.entry.prompt]=$'Environment variable\n  - Format: KEY=VALUE\n  - Empty = delete this entry\n  - Example: ROS_DOMAIN_ID=7'
_TUI_MSG_EN[tmpfs.title]="Tmpfs"
_TUI_MSG_EN[tmpfs.menu]="Select a tmpfs entry to edit, or Add a new one"
_TUI_MSG_EN[tmpfs.add]="Add tmpfs mount"
_TUI_MSG_EN[tmpfs.back]="Back to main menu"
_TUI_MSG_EN[tmpfs.entry.prompt]=$'Tmpfs mount\n  - Format: <path>[:size=<size>]\n  - Empty = delete this entry\n  - Example: /tmp:size=1g'
_TUI_MSG_EN[ports.title]="Ports"
_TUI_MSG_EN[ports.menu]="Select a port mapping to edit, or Add a new one"
_TUI_MSG_EN[ports.add]="Add port mapping"
_TUI_MSG_EN[ports.back]="Back to main menu"
_TUI_MSG_EN[ports.entry.prompt]=$'Port mapping\n  - Format: <host>:<container>[/protocol]\n  - Empty = delete this entry\n  - Example: 8080:80 or 5000:5000/udp'
_TUI_MSG_EN[ports.not_bridge]="Note: [network] mode is currently '%s'. Ports are only emitted into compose.yaml when mode=bridge."
_TUI_MSG_EN[additional_contexts.title]="Additional build contexts"
_TUI_MSG_EN[additional_contexts.menu]="Select a named context to edit, or Add a new one"
_TUI_MSG_EN[additional_contexts.add]="Add named context"
_TUI_MSG_EN[additional_contexts.back]="Back to main menu"
_TUI_MSG_EN[additional_contexts.entry.prompt]=$'Named build context\n  - Format: <name>=<source>\n  - Empty = delete this entry\n  - <source> is anything BuildKit accepts: relative path, docker-image://, https://, oci-layout://\n  - Example (relative): repo=..\n  - Example (image): base=docker-image://debian:bookworm-slim'
_TUI_MSG_EN[err.invalid_mount]="Invalid mount format (expected <host>:<container>[:ro|rw])"
_TUI_MSG_EN[err.invalid_cgroup_rule]="Invalid cgroup rule (expected: <c|b|a> <major>:<minor|*> <r|w|m>)"
_TUI_MSG_EN[err.invalid_gpu_count]="Invalid GPU count (expected 'all' or a positive integer)"
_TUI_MSG_EN[err.invalid_runtime]="Invalid runtime (expected 'auto', 'nvidia', or 'off')"
_TUI_MSG_EN[err.invalid_shm_size]=$'Invalid shm_size\n  - Expected: <num><unit>\n  - Units: b, k/kb, m/mb, g/gb (case-insensitive)\n  - Example: 2gb, 512mb'
_TUI_MSG_EN[err.invalid_port_mapping]=$'Invalid port mapping\n  - Expected: <host>:<container>[/tcp|udp]\n  - Example: 8080:80, 5000:5000/udp'
_TUI_MSG_EN[err.invalid_env_kv]=$'Invalid env var\n  - Expected: KEY=VALUE\n  - KEY must start with letter or _ and contain only [A-Za-z0-9_]'
_TUI_MSG_EN[err.invalid_network_name]=$'Invalid network name\n  - Expected: start with [a-zA-Z0-9]\n  - Then letters/digits/[_.-]\n  - Example: my_bridge'
_TUI_MSG_EN[err.invalid_capability]=$'Invalid capability name\n  - Expected: ALL_UPPERCASE with optional underscores\n  - Example: SYS_ADMIN, NET_ADMIN, ALL'
_TUI_MSG_EN[err.invalid_additional_context]=$'Invalid named build context\n  - Expected: <name>=<source>\n  - <name>: starts with [A-Za-z0-9], then letters/digits/[_.-]\n  - <source>: must be non-empty\n  - Example: repo=..'
_TUI_MSG_EN[err.no_backend]="Neither dialog nor whiptail is installed. Install with: sudo apt install dialog"
_TUI_MSG_EN[lang.invalid.title]="Language fallback"
_TUI_MSG_EN[lang.invalid.body]=$'Invalid --lang value: \'%s\'\n\nFalling back to English (en).\n\nValid values:\n  en      English\n  zh-TW   Traditional Chinese (Taiwan)\n  zh-CN   Simplified Chinese\n  ja      Japanese'
_TUI_MSG_EN[saved]="Saved to %s. Regenerating .env + compose.yaml..."
_TUI_MSG_EN[action.prompt]="Choose an action"
_TUI_MSG_EN[action.edit]="Edit"
_TUI_MSG_EN[action.remove]="Remove (delete entry)"
_TUI_MSG_EN[action.back]="Back"


declare -gA _TUI_MSG_ZH_TW=()
_TUI_MSG_ZH_TW[title]="Docker 容器設定"
_TUI_MSG_ZH_TW[main.prompt]=""
_TUI_MSG_ZH_TW[main.image]="IMAGE_NAME 偵測規則"
_TUI_MSG_ZH_TW[main.build]="APT 鏡像與 Dockerfile build args"
_TUI_MSG_ZH_TW[main.network]="網路模式／IPC／名稱"
_TUI_MSG_ZH_TW[main.deploy]="GPU 保留"
_TUI_MSG_ZH_TW[main.gui]="顯示模式"
_TUI_MSG_ZH_TW[main.volumes]="工作區與額外掛載"
_TUI_MSG_ZH_TW[main.devices]="主機裝置綁定"
_TUI_MSG_ZH_TW[main.environment]="執行時期環境變數"
_TUI_MSG_ZH_TW[main.tmpfs]="RAM 掛載點"
_TUI_MSG_ZH_TW[main.advanced]="進階"
_TUI_MSG_ZH_TW[main.save]="儲存並結束"
_TUI_MSG_ZH_TW[main.security]="privileged／cap_add／security_opt"
_TUI_MSG_ZH_TW[main.additional_contexts]="具名 build context（build.additional_contexts）"
_TUI_MSG_ZH_TW[advanced.title]="Advanced"
_TUI_MSG_ZH_TW[advanced.menu]="選擇進階區段"
_TUI_MSG_ZH_TW[advanced.back]="回主選單"
_TUI_MSG_ZH_TW[advanced.reset]="重置為預設值"
_TUI_MSG_ZH_TW[reset.title]="重置為預設值"
_TUI_MSG_ZH_TW[reset.confirm]=$'重置所有設定為 template 預設值？\n\n  - 移除 <repo>/setup.conf\n  - 重跑 setup.sh 從 template 重建\n  - 你目前的客製化會遺失\n\n無法復原。'
_TUI_MSG_ZH_TW[reset.done]="所有設定已重置為預設值。"
_TUI_MSG_ZH_TW[security.title]="Security"
_TUI_MSG_ZH_TW[security.menu]="選擇：privileged／cap_add／cap_drop／security_opt"
_TUI_MSG_ZH_TW[security.back]="回主選單"
_TUI_MSG_ZH_TW[security.privileged.prompt]="以特權模式執行？"
_TUI_MSG_ZH_TW[security.cap_add]="cap_add"
_TUI_MSG_ZH_TW[security.cap_add.menu]="選擇 cap_add 項目或新增"
_TUI_MSG_ZH_TW[security.cap_add.add]="新增 cap_add"
_TUI_MSG_ZH_TW[security.cap_add.prompt]=$'要 ADD 的 Capability\n  - 留空 = 刪除此項目\n  - 常用：SYS_ADMIN、NET_ADMIN、MKNOD、SYS_PTRACE'
_TUI_MSG_ZH_TW[security.cap_drop]="cap_drop"
_TUI_MSG_ZH_TW[security.cap_drop.menu]="選擇 cap_drop 項目或新增"
_TUI_MSG_ZH_TW[security.cap_drop.add]="新增 cap_drop"
_TUI_MSG_ZH_TW[security.cap_drop.prompt]=$'要 DROP 的 Capability\n  - 留空 = 刪除此項目\n  - 範例：ALL'
_TUI_MSG_ZH_TW[security.security_opt]="security_opt"
_TUI_MSG_ZH_TW[security.security_opt.menu]="選擇 security_opt 項目或新增"
_TUI_MSG_ZH_TW[security.security_opt.add]="新增 security_opt"
_TUI_MSG_ZH_TW[security.security_opt.prompt]=$'security_opt 項目\n  - 留空 = 刪除此項目\n  - 範例：seccomp:unconfined、apparmor:unconfined、label=disable'
_TUI_MSG_ZH_TW[image.title]="Image"
_TUI_MSG_ZH_TW[image.menu]="選擇規則編輯或新增"
_TUI_MSG_ZH_TW[image.add]="新增規則"
_TUI_MSG_ZH_TW[image.back]="回主選單"
_TUI_MSG_ZH_TW[image.type.prompt]="規則類型"
_TUI_MSG_ZH_TW[image.type.string]="string    （直接用此值為 image 名稱，不解析路徑）"
_TUI_MSG_ZH_TW[image.type.prefix]="prefix    （從目錄名剝除前綴 <value>）"
_TUI_MSG_ZH_TW[image.type.suffix]="suffix    （從路徑中任一段剝除後綴 <value>）"
_TUI_MSG_ZH_TW[image.type.basename]="@basename （直接使用目錄名，最後備用）"
_TUI_MSG_ZH_TW[image.type.default]="@default  （全無匹配時使用 <value>）"
_TUI_MSG_ZH_TW[image.type.move_up]="往上      （與前一條規則交換）"
_TUI_MSG_ZH_TW[image.type.move_down]="往下      （與後一條規則交換）"
_TUI_MSG_ZH_TW[image.type.remove]="移除      （刪除此規則）"
_TUI_MSG_ZH_TW[image.value.prompt]=$'規則參數\n  - 留空 = 取消\n  - prefix / suffix / @default：剝除或預設值\n  - string：直接用做 image 名稱（例：my_app）\n  - 例：prefix:docker_ → 輸入 docker_'
_TUI_MSG_ZH_TW[build.title]="Build 設定"
_TUI_MSG_ZH_TW[build.menu]="選擇項目編輯"
_TUI_MSG_ZH_TW[build.add]="新增 build arg"
_TUI_MSG_ZH_TW[build.back]="回主選單"
_TUI_MSG_ZH_TW[build.arg.prompt]=$'Build arg（Dockerfile ARG 覆蓋）\n  - 格式：KEY=VALUE（KEY 需符合 [A-Z_][A-Z0-9_]*）\n  - 留空 = 刪除此項目\n  - 已知 key（留空時 Dockerfile 預設生效）：\n      APT_MIRROR_UBUNTU   預設 archive.ubuntu.com\n      APT_MIRROR_DEBIAN   預設 deb.debian.org\n      TZ                  預設 Asia/Taipei\n  - 自訂：任何 Dockerfile 中 `ARG KEY` 宣告過的 key\n  - 範例：APT_MIRROR_UBUNTU=tw.archive.ubuntu.com\n  - 範例：PYTHON_VERSION=3.12'
_TUI_MSG_ZH_TW[build.target_arch.label]="TARGETARCH 覆寫"
_TUI_MSG_ZH_TW[build.target_arch.prompt]=$'Docker TARGETARCH 覆寫\n  - 留空 = 交給 BuildKit 依 host / --platform 自動填（預設）\n  - amd64 / arm64 / arm / 386 / ppc64le / s390x / riscv64\n  - 同時套用主 image 與 test-tools image\n  - 需要跨架構編譯或明確指定時才填'
_TUI_MSG_ZH_TW[build.target_arch.auto]="（自動）"
_TUI_MSG_ZH_TW[build.network.label]="Build 網路"
_TUI_MSG_ZH_TW[build.network.prompt]=$'Docker build 階段使用的網路（不影響 runtime 容器的網路）\n  - auto = 自動偵測 Jetson（/etc/nv_tegra_release）→ host；桌機 → Docker 預設（預設）\n  - host = 強制 host 網路 stack。當主機的 bridge NAT 無法用時需要：\n          例如 kernel 缺 iptable_raw（Jetson L4T）、\n          daemon.json 有 iptables: false、或 CI runner 防火牆限制\n  - bridge / none / default = 其他明確 Docker 選項\n  - off（或留空）= 明確關閉；用 Docker 預設的 bridge'
_TUI_MSG_ZH_TW[build.network.default]="（預設：auto）"
_TUI_MSG_ZH_TW[build.args.label]="額外 build args"
_TUI_MSG_ZH_TW[err.invalid_target_arch]="TARGETARCH 無效，請填空值或 amd64 / arm64 / arm / 386 / ppc64le / s390x / riscv64。"
_TUI_MSG_ZH_TW[err.invalid_build_network]="Build 網路無效，請填 auto / host / bridge / none / default / off（或留空）。"
_TUI_MSG_ZH_TW[network.title]="Network"
_TUI_MSG_ZH_TW[network.mode.prompt]="網路模式"
_TUI_MSG_ZH_TW[network.mode.host]="host（共用主機網路堆疊）"
_TUI_MSG_ZH_TW[network.mode.bridge]="bridge（隔離；可指定具名網路）"
_TUI_MSG_ZH_TW[network.mode.none]="none（無網路）"
_TUI_MSG_ZH_TW[network.ipc.prompt]="IPC 命名空間"
_TUI_MSG_ZH_TW[network.ipc.host]="host（共用主機 IPC／共享記憶體）"
_TUI_MSG_ZH_TW[network.ipc.shareable]="shareable（獨立 IPC，其他容器可存取）"
_TUI_MSG_ZH_TW[network.ipc.private]="private（獨立 IPC，Docker 預設）"
_TUI_MSG_ZH_TW[network.priv.prompt]="以特權模式執行？"
_TUI_MSG_ZH_TW[network.name.prompt]=$'Bridge 網路名稱\n  - 留空 = compose 每次自動建立 <project>_default bridge\n  - 填寫 = compose 建立以此為名的 bridge（仍由 compose 管理）\n      範例：my_bridge\n        → compose 啟動時建立 <project>_my_bridge\n        → 停止時自動移除'
_TUI_MSG_ZH_TW[deploy.title]="Deploy"
_TUI_MSG_ZH_TW[deploy.mode.prompt]="GPU 模式"
_TUI_MSG_ZH_TW[deploy.mode.auto]="auto（偵測 nvidia-container-toolkit）"
_TUI_MSG_ZH_TW[deploy.mode.force]="force（永遠輸出 GPU 區塊）"
_TUI_MSG_ZH_TW[deploy.mode.off]="off（永遠不輸出 GPU 區塊）"
_TUI_MSG_ZH_TW[deploy.count.prompt]=$'GPU 數量\n  - \'all\' = 保留主機所有 GPU\n  - <N> = 保留 N 張 GPU（1、2、...）\n  - 主機偵測到：%s'
_TUI_MSG_ZH_TW[deploy.caps.prompt]="GPU 功能（Space 鍵切換勾選）"
_TUI_MSG_ZH_TW[deploy.caps.gpu]="gpu（基本）"
_TUI_MSG_ZH_TW[deploy.caps.compute]="compute（CUDA 運算）"
_TUI_MSG_ZH_TW[deploy.caps.utility]="utility（nvidia-smi、監控）"
_TUI_MSG_ZH_TW[deploy.caps.graphics]="graphics（OpenGL、Vulkan）"
_TUI_MSG_ZH_TW[deploy.runtime.prompt]="Docker runtime 覆寫（Jetson / csv 模式 toolkit）"
_TUI_MSG_ZH_TW[deploy.runtime.auto]="auto（Jetson 自動輸出 runtime: nvidia — /etc/nv_tegra_release）"
_TUI_MSG_ZH_TW[deploy.runtime.nvidia]="nvidia（所有主機強制輸出）"
_TUI_MSG_ZH_TW[deploy.runtime.off]="off（不覆寫 — Docker 預設 runc）"
_TUI_MSG_ZH_TW[deploy.mig.title]="Deploy — 偵測到 NVIDIA MIG"
_TUI_MSG_ZH_TW[deploy.mig.warning]=$'此主機已啟用 NVIDIA MIG（Multi-Instance GPU）模式。\n\nDocker 的 deploy `count=N` 只能預留整張 GPU，無法指定特定 MIG slice。若要使用單一 slice，請維持 count 不變，並在 [environment] 區塊加入：\n  NVIDIA_VISIBLE_DEVICES=<MIG-UUID>\n\n主機上的 GPU / MIG 實例：\n%s'
_TUI_MSG_ZH_TW[gui.title]="GUI"
_TUI_MSG_ZH_TW[gui.mode.prompt]="GUI 模式"
_TUI_MSG_ZH_TW[gui.mode.auto]="auto（偵測 \$DISPLAY／\$WAYLAND_DISPLAY）"
_TUI_MSG_ZH_TW[gui.mode.force]="force（永遠輸出 GUI 區塊）"
_TUI_MSG_ZH_TW[gui.mode.off]="off（永遠不輸出 GUI 區塊）"
_TUI_MSG_ZH_TW[volumes.title]="Volumes"
_TUI_MSG_ZH_TW[volumes.menu]="選擇掛載點編輯或新增"
_TUI_MSG_ZH_TW[volumes.add]="新增掛載"
_TUI_MSG_ZH_TW[volumes.edit.prompt]=$'掛載規格\n  - 格式：<host>:<container>[:ro|rw]\n  - 留空 = 刪除此項目\n  - 範例：/data:/home/${USER_NAME}/data:rw'
_TUI_MSG_ZH_TW[volumes.delete.confirm]="刪除掛載「%s」？"
_TUI_MSG_ZH_TW[volumes.back]="回主選單"
_TUI_MSG_ZH_TW[devices.title]="Devices"
_TUI_MSG_ZH_TW[devices.menu]="選擇要編輯的清單"
_TUI_MSG_ZH_TW[devices.edit_devices]="Device bindings（devices:）"
_TUI_MSG_ZH_TW[devices.edit_cgroup]="Cgroup 規則（device_cgroup_rules:）"
_TUI_MSG_ZH_TW[devices.add_device]="新增 device binding"
_TUI_MSG_ZH_TW[devices.add_cgroup]="新增 cgroup rule"
_TUI_MSG_ZH_TW[devices.back]="回主選單"
_TUI_MSG_ZH_TW[devices.device.prompt]=$'Device 綁定\n  - 格式：<host>[:<container>[:rwm]]\n  - 留空 = 刪除此項目\n  - 預設：/dev:/dev（綁定整個 /dev）\n  - 範例（單一）：/dev/video0:/dev/video0'
_TUI_MSG_ZH_TW[devices.cgroup.title]="Cgroup 規則"
_TUI_MSG_ZH_TW[devices.cgroup.menu]="選擇項目編輯，或新增 cgroup 規則"
_TUI_MSG_ZH_TW[devices.cgroup.prompt]=$'Cgroup 規則\n  - 格式：<type> <major>:<minor|*> <perms>\n    type: c（字元）、b（區塊）、a（全部）\n    perms: r / w / m 任意組合\n  - 留空 = 刪除此項目\n  - USB 範例：c 189:* rwm\n  - V4L2 範例：c 81:* rwm'
_TUI_MSG_ZH_TW[resources.title]="Resources"
_TUI_MSG_ZH_TW[resources.shm_size.prompt]=$'/dev/shm 大小\n  - 留空 = Docker 預設 64mb\n  - 範例：2gb、512mb\n  - 僅在 [network] ipc ≠ host 時生效'
_TUI_MSG_ZH_TW[resources.shm_size.ignored]="注意：目前 [network] ipc = '%s'。Docker 會忽略 shm_size（只在 ipc 為 'private' 或 'shareable' 時生效）。"
_TUI_MSG_ZH_TW[environment.title]="Environment"
_TUI_MSG_ZH_TW[environment.menu]="選擇要編輯的環境變數，或新增"
_TUI_MSG_ZH_TW[environment.add]="新增環境變數"
_TUI_MSG_ZH_TW[environment.back]="回主選單"
_TUI_MSG_ZH_TW[environment.entry.prompt]=$'環境變數\n  - 格式：KEY=VALUE\n  - 留空 = 刪除此項目\n  - 範例：ROS_DOMAIN_ID=7'
_TUI_MSG_ZH_TW[tmpfs.title]="Tmpfs"
_TUI_MSG_ZH_TW[tmpfs.menu]="選擇 tmpfs 項目編輯，或新增"
_TUI_MSG_ZH_TW[tmpfs.add]="新增 tmpfs 掛載"
_TUI_MSG_ZH_TW[tmpfs.back]="回主選單"
_TUI_MSG_ZH_TW[tmpfs.entry.prompt]=$'Tmpfs 掛載\n  - 格式：<path>[:size=<size>]\n  - 留空 = 刪除此項目\n  - 範例：/tmp:size=1g'
_TUI_MSG_ZH_TW[ports.title]="Ports"
_TUI_MSG_ZH_TW[ports.menu]="選擇 port 映射編輯，或新增"
_TUI_MSG_ZH_TW[ports.add]="新增 port 映射"
_TUI_MSG_ZH_TW[ports.back]="回主選單"
_TUI_MSG_ZH_TW[ports.entry.prompt]=$'Port 映射\n  - 格式：<host>:<container>[/protocol]\n  - 留空 = 刪除此項目\n  - 範例：8080:80 或 5000:5000/udp'
_TUI_MSG_ZH_TW[ports.not_bridge]="注意：目前 [network] mode = '%s'。ports 只在 mode=bridge 時寫入 compose.yaml。"
_TUI_MSG_ZH_TW[additional_contexts.title]="額外 build context"
_TUI_MSG_ZH_TW[additional_contexts.menu]="選擇具名 context 編輯或新增"
_TUI_MSG_ZH_TW[additional_contexts.add]="新增具名 context"
_TUI_MSG_ZH_TW[additional_contexts.back]="回主選單"
_TUI_MSG_ZH_TW[additional_contexts.entry.prompt]=$'具名 build context\n  - 格式：<name>=<source>\n  - 留空 = 刪除此項目\n  - <source> 可以是 BuildKit 接受的任意來源：相對路徑、docker-image://、https://、oci-layout://\n  - 範例（相對路徑）：repo=..\n  - 範例（image）：base=docker-image://debian:bookworm-slim'
_TUI_MSG_ZH_TW[err.invalid_mount]="掛載格式錯誤（預期 <host>:<container>[:ro|rw]）"
_TUI_MSG_ZH_TW[err.invalid_cgroup_rule]="Cgroup 規則格式錯誤（預期：<c|b|a> <major>:<minor|*> <r|w|m>）"
_TUI_MSG_ZH_TW[err.invalid_gpu_count]="GPU 數量格式錯誤（預期 'all' 或正整數）"
_TUI_MSG_ZH_TW[err.invalid_runtime]="runtime 值不合法（預期 'auto'、'nvidia' 或 'off'）"
_TUI_MSG_ZH_TW[err.invalid_shm_size]=$'shm_size 格式錯誤\n  - 預期：<數字><單位>\n  - 單位：b、k/kb、m/mb、g/gb（大小寫不限）\n  - 範例：2gb、512mb'
_TUI_MSG_ZH_TW[err.invalid_port_mapping]=$'Port 映射格式錯誤\n  - 預期：<host>:<container>[/tcp|udp]\n  - 範例：8080:80、5000:5000/udp'
_TUI_MSG_ZH_TW[err.invalid_env_kv]=$'環境變數格式錯誤\n  - 預期：KEY=VALUE\n  - KEY 需以字母或 _ 開頭，僅含 [A-Za-z0-9_]'
_TUI_MSG_ZH_TW[err.invalid_network_name]=$'網路名稱格式錯誤\n  - 預期：開頭為 [a-zA-Z0-9]\n  - 後續含字母／數字／[_.-]\n  - 範例：my_bridge'
_TUI_MSG_ZH_TW[err.invalid_capability]=$'Capability 名稱錯誤\n  - 預期：全大寫 ASCII + 底線\n  - 範例：SYS_ADMIN、NET_ADMIN、ALL'
_TUI_MSG_ZH_TW[err.invalid_additional_context]=$'具名 build context 格式錯誤\n  - 預期：<name>=<source>\n  - <name>：以 [A-Za-z0-9] 開頭，僅含字母／數字／[_.-]\n  - <source>：不可為空\n  - 範例：repo=..'
_TUI_MSG_ZH_TW[err.no_backend]="未安裝 dialog 或 whiptail，請執行：sudo apt install dialog"
_TUI_MSG_ZH_TW[saved]="已儲存至 %s，正在重新產生 .env + compose.yaml..."
_TUI_MSG_ZH_TW[action.prompt]="選擇動作"
_TUI_MSG_ZH_TW[action.edit]="編輯"
_TUI_MSG_ZH_TW[action.remove]="移除（刪除項目）"
_TUI_MSG_ZH_TW[action.back]="返回"


declare -gA _TUI_MSG_ZH_CN=()
_TUI_MSG_ZH_CN[title]="Docker 容器配置"
_TUI_MSG_ZH_CN[main.prompt]=""
_TUI_MSG_ZH_CN[main.image]="IMAGE_NAME 检测规则"
_TUI_MSG_ZH_CN[main.build]="APT 镜像与 Dockerfile build args"
_TUI_MSG_ZH_CN[main.network]="网络模式／IPC／名称"
_TUI_MSG_ZH_CN[main.deploy]="GPU 预留"
_TUI_MSG_ZH_CN[main.gui]="显示模式"
_TUI_MSG_ZH_CN[main.volumes]="工作区与额外挂载"
_TUI_MSG_ZH_CN[main.devices]="主机设备绑定"
_TUI_MSG_ZH_CN[main.environment]="运行时环境变量"
_TUI_MSG_ZH_CN[main.tmpfs]="RAM 挂载点"
_TUI_MSG_ZH_CN[main.advanced]="进阶"
_TUI_MSG_ZH_CN[main.save]="保存并退出"
_TUI_MSG_ZH_CN[main.security]="privileged／cap_add／security_opt"
_TUI_MSG_ZH_CN[main.additional_contexts]="具名 build context（build.additional_contexts）"
_TUI_MSG_ZH_CN[advanced.title]="Advanced"
_TUI_MSG_ZH_CN[advanced.menu]="选择进阶区段"
_TUI_MSG_ZH_CN[advanced.back]="回主菜单"
_TUI_MSG_ZH_CN[advanced.reset]="重置为默认值"
_TUI_MSG_ZH_CN[reset.title]="重置为默认值"
_TUI_MSG_ZH_CN[reset.confirm]=$'重置所有设定为 template 默认值？\n\n  - 移除 <repo>/setup.conf\n  - 重跑 setup.sh 从 template 重建\n  - 你当前的定制会丢失\n\n无法撤销。'
_TUI_MSG_ZH_CN[reset.done]="所有设定已重置为默认值。"
_TUI_MSG_ZH_CN[security.title]="Security"
_TUI_MSG_ZH_CN[security.menu]="选择：privileged／cap_add／cap_drop／security_opt"
_TUI_MSG_ZH_CN[security.back]="回主菜单"
_TUI_MSG_ZH_CN[security.privileged.prompt]="以特权模式运行？"
_TUI_MSG_ZH_CN[security.cap_add]="cap_add"
_TUI_MSG_ZH_CN[security.cap_add.menu]="选择 cap_add 项目或新增"
_TUI_MSG_ZH_CN[security.cap_add.add]="新增 cap_add"
_TUI_MSG_ZH_CN[security.cap_add.prompt]=$'要 ADD 的 Capability\n  - 留空 = 删除此项目\n  - 常用：SYS_ADMIN、NET_ADMIN、MKNOD、SYS_PTRACE'
_TUI_MSG_ZH_CN[security.cap_drop]="cap_drop"
_TUI_MSG_ZH_CN[security.cap_drop.menu]="选择 cap_drop 项目或新增"
_TUI_MSG_ZH_CN[security.cap_drop.add]="新增 cap_drop"
_TUI_MSG_ZH_CN[security.cap_drop.prompt]=$'要 DROP 的 Capability\n  - 留空 = 删除此项目\n  - 示例：ALL'
_TUI_MSG_ZH_CN[security.security_opt]="security_opt"
_TUI_MSG_ZH_CN[security.security_opt.menu]="选择 security_opt 项目或新增"
_TUI_MSG_ZH_CN[security.security_opt.add]="新增 security_opt"
_TUI_MSG_ZH_CN[security.security_opt.prompt]=$'security_opt 项目\n  - 留空 = 删除此项目\n  - 示例：seccomp:unconfined、apparmor:unconfined、label=disable'
_TUI_MSG_ZH_CN[image.title]="Image"
_TUI_MSG_ZH_CN[image.menu]="选择规则编辑或新增"
_TUI_MSG_ZH_CN[image.add]="新增规则"
_TUI_MSG_ZH_CN[image.back]="回主菜单"
_TUI_MSG_ZH_CN[image.type.prompt]="规则类型"
_TUI_MSG_ZH_CN[image.type.string]="string    （直接用此值为 image 名称，不解析路径）"
_TUI_MSG_ZH_CN[image.type.prefix]="prefix    （从目录名剥除前缀 <value>）"
_TUI_MSG_ZH_CN[image.type.suffix]="suffix    （从路径中任一段剥除后缀 <value>）"
_TUI_MSG_ZH_CN[image.type.basename]="@basename （直接使用目录名，最后备用）"
_TUI_MSG_ZH_CN[image.type.default]="@default  （全无匹配时使用 <value>）"
_TUI_MSG_ZH_CN[image.type.move_up]="上移      （与前一条规则交换）"
_TUI_MSG_ZH_CN[image.type.move_down]="下移      （与后一条规则交换）"
_TUI_MSG_ZH_CN[image.type.remove]="移除      （删除此规则）"
_TUI_MSG_ZH_CN[image.value.prompt]=$'规则参数\n  - 留空 = 取消\n  - prefix / suffix / @default：剥除或默认值\n  - string：直接作为 image 名称（例：my_app）\n  - 例：prefix:docker_ → 输入 docker_'
_TUI_MSG_ZH_CN[build.title]="Build 配置"
_TUI_MSG_ZH_CN[build.menu]="选择项目编辑"
_TUI_MSG_ZH_CN[build.add]="新增 build arg"
_TUI_MSG_ZH_CN[build.back]="回主菜单"
_TUI_MSG_ZH_CN[build.arg.prompt]=$'Build arg（Dockerfile ARG 覆盖）\n  - 格式：KEY=VALUE（KEY 需符合 [A-Z_][A-Z0-9_]*）\n  - 留空 = 删除此项目\n  - 已知 key（留空时 Dockerfile 默认生效）：\n      APT_MIRROR_UBUNTU   默认 archive.ubuntu.com\n      APT_MIRROR_DEBIAN   默认 deb.debian.org\n      TZ                  默认 Asia/Taipei\n  - 自定：任何 Dockerfile 中 `ARG KEY` 声明过的 key\n  - 示例：APT_MIRROR_UBUNTU=tw.archive.ubuntu.com\n  - 示例：PYTHON_VERSION=3.12'
_TUI_MSG_ZH_CN[build.target_arch.label]="TARGETARCH 覆盖"
_TUI_MSG_ZH_CN[build.target_arch.prompt]=$'Docker TARGETARCH 覆盖\n  - 留空 = 交给 BuildKit 依 host / --platform 自动填（默认）\n  - amd64 / arm64 / arm / 386 / ppc64le / s390x / riscv64\n  - 同时应用于主 image 与 test-tools image\n  - 需要跨架构构建或明确指定时才填'
_TUI_MSG_ZH_CN[build.target_arch.auto]="（自动）"
_TUI_MSG_ZH_CN[build.network.label]="Build 网络"
_TUI_MSG_ZH_CN[build.network.prompt]=$'Docker build 阶段使用的网络（不影响 runtime 容器的网络）\n  - auto = 自动检测 Jetson（/etc/nv_tegra_release）→ host；桌机 → Docker 默认（默认）\n  - host = 强制 host 网络 stack。当主机的 bridge NAT 无法用时需要：\n          例如 kernel 缺 iptable_raw（Jetson L4T）、\n          daemon.json 有 iptables: false、或 CI runner 防火墙限制\n  - bridge / none / default = 其他明确 Docker 选项\n  - off（或留空）= 明确关闭；用 Docker 默认的 bridge'
_TUI_MSG_ZH_CN[build.network.default]="（默认：auto）"
_TUI_MSG_ZH_CN[build.args.label]="额外 build args"
_TUI_MSG_ZH_CN[err.invalid_target_arch]="TARGETARCH 无效，请填空值或 amd64 / arm64 / arm / 386 / ppc64le / s390x / riscv64。"
_TUI_MSG_ZH_CN[err.invalid_build_network]="Build 网络无效，请填 auto / host / bridge / none / default / off（或留空）。"
_TUI_MSG_ZH_CN[network.title]="Network"
_TUI_MSG_ZH_CN[network.mode.prompt]="网络模式"
_TUI_MSG_ZH_CN[network.mode.host]="host（共用主机网络栈）"
_TUI_MSG_ZH_CN[network.mode.bridge]="bridge（隔离；可指定命名网络）"
_TUI_MSG_ZH_CN[network.mode.none]="none（无网络）"
_TUI_MSG_ZH_CN[network.ipc.prompt]="IPC 命名空间"
_TUI_MSG_ZH_CN[network.ipc.host]="host（共用主机 IPC／共享内存）"
_TUI_MSG_ZH_CN[network.ipc.shareable]="shareable（独立 IPC，其他容器可访问）"
_TUI_MSG_ZH_CN[network.ipc.private]="private（独立 IPC，Docker 默认）"
_TUI_MSG_ZH_CN[network.priv.prompt]="以特权模式运行？"
_TUI_MSG_ZH_CN[network.name.prompt]=$'Bridge 网络名称\n  - 留空 = compose 每次自动建立 <project>_default bridge\n  - 填写 = compose 建立以此为名的 bridge（仍由 compose 管理）\n      示例：my_bridge\n        → compose 启动时建立 <project>_my_bridge\n        → 停止时自动移除'
_TUI_MSG_ZH_CN[deploy.title]="Deploy"
_TUI_MSG_ZH_CN[deploy.mode.prompt]="GPU 模式"
_TUI_MSG_ZH_CN[deploy.mode.auto]="auto（检测 nvidia-container-toolkit）"
_TUI_MSG_ZH_CN[deploy.mode.force]="force（永远输出 GPU 区块）"
_TUI_MSG_ZH_CN[deploy.mode.off]="off（永远不输出 GPU 区块）"
_TUI_MSG_ZH_CN[deploy.count.prompt]=$'GPU 数量\n  - \'all\' = 保留主机所有 GPU\n  - <N> = 保留 N 张 GPU（1、2、...）\n  - 主机检测到：%s'
_TUI_MSG_ZH_CN[deploy.caps.prompt]="GPU 功能（Space 键切换勾选）"
_TUI_MSG_ZH_CN[deploy.caps.gpu]="gpu（基本）"
_TUI_MSG_ZH_CN[deploy.caps.compute]="compute（CUDA 计算）"
_TUI_MSG_ZH_CN[deploy.caps.utility]="utility（nvidia-smi、监控）"
_TUI_MSG_ZH_CN[deploy.caps.graphics]="graphics（OpenGL、Vulkan）"
_TUI_MSG_ZH_CN[deploy.runtime.prompt]="Docker runtime 覆盖（Jetson / csv 模式 toolkit）"
_TUI_MSG_ZH_CN[deploy.runtime.auto]="auto（Jetson 自动输出 runtime: nvidia — /etc/nv_tegra_release）"
_TUI_MSG_ZH_CN[deploy.runtime.nvidia]="nvidia（所有主机强制输出）"
_TUI_MSG_ZH_CN[deploy.runtime.off]="off（不覆盖 — Docker 默认 runc）"
_TUI_MSG_ZH_CN[deploy.mig.title]="Deploy — 检测到 NVIDIA MIG"
_TUI_MSG_ZH_CN[deploy.mig.warning]=$'此主机已启用 NVIDIA MIG（Multi-Instance GPU）模式。\n\nDocker 的 deploy `count=N` 只能预留整张 GPU，无法指定特定 MIG slice。若要使用单一 slice，请保持 count 不变，并在 [environment] 区块加入：\n  NVIDIA_VISIBLE_DEVICES=<MIG-UUID>\n\n主机上的 GPU / MIG 实例：\n%s'
_TUI_MSG_ZH_CN[gui.title]="GUI"
_TUI_MSG_ZH_CN[gui.mode.prompt]="GUI 模式"
_TUI_MSG_ZH_CN[gui.mode.auto]="auto（检测 \$DISPLAY／\$WAYLAND_DISPLAY）"
_TUI_MSG_ZH_CN[gui.mode.force]="force（永远输出 GUI 区块）"
_TUI_MSG_ZH_CN[gui.mode.off]="off（永远不输出 GUI 区块）"
_TUI_MSG_ZH_CN[volumes.title]="Volumes"
_TUI_MSG_ZH_CN[volumes.menu]="选择挂载点编辑或新增"
_TUI_MSG_ZH_CN[volumes.add]="新增挂载"
_TUI_MSG_ZH_CN[volumes.edit.prompt]=$'挂载规格\n  - 格式：<host>:<container>[:ro|rw]\n  - 留空 = 删除此项目\n  - 示例：/data:/home/${USER_NAME}/data:rw'
_TUI_MSG_ZH_CN[volumes.delete.confirm]="删除挂载「%s」？"
_TUI_MSG_ZH_CN[volumes.back]="回主菜单"
_TUI_MSG_ZH_CN[devices.title]="Devices"
_TUI_MSG_ZH_CN[devices.menu]="选择要编辑的列表"
_TUI_MSG_ZH_CN[devices.edit_devices]="Device bindings（devices:）"
_TUI_MSG_ZH_CN[devices.edit_cgroup]="Cgroup 规则（device_cgroup_rules:）"
_TUI_MSG_ZH_CN[devices.add_device]="新增 device binding"
_TUI_MSG_ZH_CN[devices.add_cgroup]="新增 cgroup rule"
_TUI_MSG_ZH_CN[devices.back]="回主菜单"
_TUI_MSG_ZH_CN[devices.device.prompt]=$'Device 绑定\n  - 格式：<host>[:<container>[:rwm]]\n  - 留空 = 删除此项目\n  - 默认：/dev:/dev（绑定整个 /dev）\n  - 示例（单一）：/dev/video0:/dev/video0'
_TUI_MSG_ZH_CN[devices.cgroup.title]="Cgroup 规则"
_TUI_MSG_ZH_CN[devices.cgroup.menu]="选择项目编辑，或新增 cgroup 规则"
_TUI_MSG_ZH_CN[devices.cgroup.prompt]=$'Cgroup 规则\n  - 格式：<type> <major>:<minor|*> <perms>\n    type: c（字符）、b（块）、a（全部）\n    perms: r / w / m 任意组合\n  - 留空 = 删除此项目\n  - USB 示例：c 189:* rwm\n  - V4L2 示例：c 81:* rwm'
_TUI_MSG_ZH_CN[resources.title]="Resources"
_TUI_MSG_ZH_CN[resources.shm_size.prompt]=$'/dev/shm 大小\n  - 留空 = Docker 默认 64mb\n  - 示例：2gb、512mb\n  - 仅在 [network] ipc ≠ host 时生效'
_TUI_MSG_ZH_CN[resources.shm_size.ignored]="注意：当前 [network] ipc = '%s'。Docker 会忽略 shm_size（仅在 ipc 为 'private' 或 'shareable' 时生效）。"
_TUI_MSG_ZH_CN[environment.title]="Environment"
_TUI_MSG_ZH_CN[environment.menu]="选择要编辑的环境变量，或新增"
_TUI_MSG_ZH_CN[environment.add]="新增环境变量"
_TUI_MSG_ZH_CN[environment.back]="回主菜单"
_TUI_MSG_ZH_CN[environment.entry.prompt]=$'环境变量\n  - 格式：KEY=VALUE\n  - 留空 = 删除此项目\n  - 示例：ROS_DOMAIN_ID=7'
_TUI_MSG_ZH_CN[tmpfs.title]="Tmpfs"
_TUI_MSG_ZH_CN[tmpfs.menu]="选择 tmpfs 项目编辑，或新增"
_TUI_MSG_ZH_CN[tmpfs.add]="新增 tmpfs 挂载"
_TUI_MSG_ZH_CN[tmpfs.back]="回主菜单"
_TUI_MSG_ZH_CN[tmpfs.entry.prompt]=$'Tmpfs 挂载\n  - 格式：<path>[:size=<size>]\n  - 留空 = 删除此项目\n  - 示例：/tmp:size=1g'
_TUI_MSG_ZH_CN[ports.title]="Ports"
_TUI_MSG_ZH_CN[ports.menu]="选择 port 映射编辑，或新增"
_TUI_MSG_ZH_CN[ports.add]="新增 port 映射"
_TUI_MSG_ZH_CN[ports.back]="回主菜单"
_TUI_MSG_ZH_CN[ports.entry.prompt]=$'Port 映射\n  - 格式：<host>:<container>[/protocol]\n  - 留空 = 删除此项目\n  - 示例：8080:80 或 5000:5000/udp'
_TUI_MSG_ZH_CN[ports.not_bridge]="注意：当前 [network] mode = '%s'。ports 仅在 mode=bridge 时写入 compose.yaml。"
_TUI_MSG_ZH_CN[additional_contexts.title]="额外 build context"
_TUI_MSG_ZH_CN[additional_contexts.menu]="选择具名 context 编辑或新增"
_TUI_MSG_ZH_CN[additional_contexts.add]="新增具名 context"
_TUI_MSG_ZH_CN[additional_contexts.back]="回主菜单"
_TUI_MSG_ZH_CN[additional_contexts.entry.prompt]=$'具名 build context\n  - 格式：<name>=<source>\n  - 留空 = 删除此项目\n  - <source> 可以是 BuildKit 接受的任意来源：相对路径、docker-image://、https://、oci-layout://\n  - 示例（相对路径）：repo=..\n  - 示例（image）：base=docker-image://debian:bookworm-slim'
_TUI_MSG_ZH_CN[err.invalid_mount]="挂载格式错误（预期 <host>:<container>[:ro|rw]）"
_TUI_MSG_ZH_CN[err.invalid_additional_context]=$'具名 build context 格式错误\n  - 预期：<name>=<source>\n  - <name>：以 [A-Za-z0-9] 开头，仅含字母／数字／[_.-]\n  - <source>：不可为空\n  - 示例：repo=..'
_TUI_MSG_ZH_CN[err.invalid_cgroup_rule]="Cgroup 规则格式错误（预期：<c|b|a> <major>:<minor|*> <r|w|m>）"
_TUI_MSG_ZH_CN[err.invalid_gpu_count]="GPU 数量格式错误（预期 'all' 或正整数）"
_TUI_MSG_ZH_CN[err.invalid_runtime]="runtime 值不合法（预期 'auto'、'nvidia' 或 'off'）"
_TUI_MSG_ZH_CN[err.no_backend]="未安装 dialog 或 whiptail，请执行：sudo apt install dialog"
_TUI_MSG_ZH_CN[saved]="已保存至 %s，正在重新生成 .env + compose.yaml..."
_TUI_MSG_ZH_CN[action.prompt]="选择动作"
_TUI_MSG_ZH_CN[action.edit]="编辑"
_TUI_MSG_ZH_CN[action.remove]="移除（删除项目）"
_TUI_MSG_ZH_CN[action.back]="返回"


declare -gA _TUI_MSG_JA=()
_TUI_MSG_JA[title]="Docker コンテナ設定"
_TUI_MSG_JA[main.prompt]=""
_TUI_MSG_JA[main.image]="IMAGE_NAME 検出ルール"
_TUI_MSG_JA[main.build]="APT ミラー / Dockerfile build args"
_TUI_MSG_JA[main.network]="ネットワークモード／IPC／name"
_TUI_MSG_JA[main.deploy]="GPU 予約"
_TUI_MSG_JA[main.gui]="表示モード"
_TUI_MSG_JA[main.volumes]="ワークスペースと追加マウント"
_TUI_MSG_JA[main.devices]="ホストデバイスバインド"
_TUI_MSG_JA[main.environment]="実行時環境変数"
_TUI_MSG_JA[main.tmpfs]="RAM マウント"
_TUI_MSG_JA[main.advanced]="詳細"
_TUI_MSG_JA[main.save]="保存して終了"
_TUI_MSG_JA[main.security]="privileged／cap_add／security_opt"
_TUI_MSG_JA[main.additional_contexts]="名前付き build context（build.additional_contexts）"
_TUI_MSG_JA[advanced.title]="Advanced"
_TUI_MSG_JA[advanced.menu]="Advanced セクションを選択"
_TUI_MSG_JA[advanced.back]="メインメニューへ戻る"
_TUI_MSG_JA[advanced.reset]="デフォルトにリセット"
_TUI_MSG_JA[reset.title]="デフォルトにリセット"
_TUI_MSG_JA[reset.confirm]=$'全ての設定を template のデフォルトにリセット？\n\n  - <repo>/setup.conf を削除\n  - setup.sh を再実行して template から再生成\n  - 現在のカスタマイズは失われます\n\n元に戻せません。'
_TUI_MSG_JA[reset.done]="全ての設定がデフォルトにリセットされました。"
_TUI_MSG_JA[security.title]="Security"
_TUI_MSG_JA[security.menu]="選択：privileged／cap_add／cap_drop／security_opt"
_TUI_MSG_JA[security.back]="メインメニューへ戻る"
_TUI_MSG_JA[security.privileged.prompt]="特権モードで実行？"
_TUI_MSG_JA[security.cap_add]="cap_add"
_TUI_MSG_JA[security.cap_add.menu]="cap_add を選択、または追加"
_TUI_MSG_JA[security.cap_add.add]="cap_add を追加"
_TUI_MSG_JA[security.cap_add.prompt]=$'ADD する Capability\n  - 空 = この項目を削除\n  - よく使う: SYS_ADMIN、NET_ADMIN、MKNOD、SYS_PTRACE'
_TUI_MSG_JA[security.cap_drop]="cap_drop"
_TUI_MSG_JA[security.cap_drop.menu]="cap_drop を選択、または追加"
_TUI_MSG_JA[security.cap_drop.add]="cap_drop を追加"
_TUI_MSG_JA[security.cap_drop.prompt]=$'DROP する Capability\n  - 空 = この項目を削除\n  - 例: ALL'
_TUI_MSG_JA[security.security_opt]="security_opt"
_TUI_MSG_JA[security.security_opt.menu]="security_opt を選択、または追加"
_TUI_MSG_JA[security.security_opt.add]="security_opt を追加"
_TUI_MSG_JA[security.security_opt.prompt]=$'security_opt 項目\n  - 空 = この項目を削除\n  - 例: seccomp:unconfined、apparmor:unconfined、label=disable'
_TUI_MSG_JA[image.title]="Image"
_TUI_MSG_JA[image.menu]="編集または追加するルールを選択"
_TUI_MSG_JA[image.add]="ルールを追加"
_TUI_MSG_JA[image.back]="メインメニューへ戻る"
_TUI_MSG_JA[image.type.prompt]="ルール種別"
_TUI_MSG_JA[image.type.string]="string    （この値をそのまま image 名にする、パス解析なし）"
_TUI_MSG_JA[image.type.prefix]="prefix    （ディレクトリ名の先頭から <value> を除去）"
_TUI_MSG_JA[image.type.suffix]="suffix    （パス構成要素の末尾から <value> を除去）"
_TUI_MSG_JA[image.type.basename]="@basename （ディレクトリ名をそのまま使用、最終手段）"
_TUI_MSG_JA[image.type.default]="@default  （他のどれにも該当しない時 <value> を使用）"
_TUI_MSG_JA[image.type.move_up]="上へ      （前のルールと入れ替え）"
_TUI_MSG_JA[image.type.move_down]="下へ      （次のルールと入れ替え）"
_TUI_MSG_JA[image.type.remove]="削除      （このルールを削除）"
_TUI_MSG_JA[image.value.prompt]=$'ルール値\n  - 空 = キャンセル\n  - prefix / suffix / @default：除去または fallback 値\n  - string：そのまま image 名として使用（例：my_app）\n  - 例：prefix:docker_ → docker_ と入力'
_TUI_MSG_JA[build.title]="Build 設定"
_TUI_MSG_JA[build.menu]="編集する項目を選択"
_TUI_MSG_JA[build.add]="build arg を追加"
_TUI_MSG_JA[build.back]="メインメニューへ戻る"
_TUI_MSG_JA[build.arg.prompt]=$'Build arg（Dockerfile ARG 上書き）\n  - 形式: KEY=VALUE (KEY は [A-Z_][A-Z0-9_]* に合致)\n  - 空 = この項目を削除\n  - 既知の key（空の場合は Dockerfile のデフォルトが効く）：\n      APT_MIRROR_UBUNTU   デフォルト archive.ubuntu.com\n      APT_MIRROR_DEBIAN   デフォルト deb.debian.org\n      TZ                  デフォルト Asia/Taipei\n  - ユーザ定義：Dockerfile で `ARG KEY` 宣言済みの任意の key\n  - 例：APT_MIRROR_UBUNTU=tw.archive.ubuntu.com\n  - 例：PYTHON_VERSION=3.12'
_TUI_MSG_JA[build.target_arch.label]="TARGETARCH 上書き"
_TUI_MSG_JA[build.target_arch.prompt]=$'Docker TARGETARCH 上書き\n  - 空 = BuildKit が host / --platform から自動補完（デフォルト）\n  - amd64 / arm64 / arm / 386 / ppc64le / s390x / riscv64\n  - メイン image と test-tools image の両方に適用\n  - クロスビルドや明示指定が必要なときのみ設定'
_TUI_MSG_JA[build.target_arch.auto]="（自動）"
_TUI_MSG_JA[build.network.label]="Build ネットワーク"
_TUI_MSG_JA[build.network.prompt]=$'Docker build 時のネットワーク（runtime コンテナは別管理）\n  - auto = Jetson（/etc/nv_tegra_release）検出時は host、デスクトップは Docker 既定（既定）\n  - host = 強制的にホストネットワーク stack を使用。ホストの bridge NAT が\n          使えない場合に必要：kernel が iptable_raw 欠落（Jetson L4T）、\n          daemon.json に iptables: false、CI runner のファイアウォール制限など\n  - bridge / none / default = 明示指定（Docker の既知モード）\n  - off（または空）= 明示的にオプトアウト。Docker 既定の bridge を使用'
_TUI_MSG_JA[build.network.default]="（デフォルト：auto）"
_TUI_MSG_JA[build.args.label]="追加 build args"
_TUI_MSG_JA[err.invalid_target_arch]="TARGETARCH が不正です。空、または amd64 / arm64 / arm / 386 / ppc64le / s390x / riscv64 を指定してください。"
_TUI_MSG_JA[err.invalid_build_network]="Build ネットワークが不正です。auto / host / bridge / none / default / off（または空）を指定してください。"
_TUI_MSG_JA[network.title]="Network"
_TUI_MSG_JA[network.mode.prompt]="ネットワークモード"
_TUI_MSG_JA[network.mode.host]="host（ホストネットワークスタックを共有）"
_TUI_MSG_JA[network.mode.bridge]="bridge（分離；ネームドネットワークを指定可）"
_TUI_MSG_JA[network.mode.none]="none（ネットワークなし）"
_TUI_MSG_JA[network.ipc.prompt]="IPC 名前空間"
_TUI_MSG_JA[network.ipc.host]="host（ホスト IPC／共有メモリを共有）"
_TUI_MSG_JA[network.ipc.shareable]="shareable（独自 IPC、他コンテナから可）"
_TUI_MSG_JA[network.ipc.private]="private（独自 IPC、Docker デフォルト）"
_TUI_MSG_JA[network.priv.prompt]="特権モードで実行？"
_TUI_MSG_JA[network.name.prompt]=$'Bridge ネットワーク名\n  - 空 = compose が実行ごとに <project>_default bridge を自動作成\n  - 非空 = この名前の bridge を compose が作成 (compose が管理)\n      例: my_bridge\n        → 起動時 <project>_my_bridge を作成\n        → 停止時に自動削除'
_TUI_MSG_JA[deploy.title]="Deploy"
_TUI_MSG_JA[deploy.mode.prompt]="GPU モード"
_TUI_MSG_JA[deploy.mode.auto]="auto（nvidia-container-toolkit を検出）"
_TUI_MSG_JA[deploy.mode.force]="force（常に GPU ブロックを出力）"
_TUI_MSG_JA[deploy.mode.off]="off（GPU ブロックを出力しない）"
_TUI_MSG_JA[deploy.count.prompt]=$'GPU 数\n  - \'all\' = ホストの全 GPU を予約\n  - <N> = N 個の GPU を予約 (1、2、...)\n  - ホスト検出: %s'
_TUI_MSG_JA[deploy.caps.prompt]="GPU ケイパビリティ（Space で切替）"
_TUI_MSG_JA[deploy.caps.gpu]="gpu（基本）"
_TUI_MSG_JA[deploy.caps.compute]="compute（CUDA 計算）"
_TUI_MSG_JA[deploy.caps.utility]="utility（nvidia-smi、監視）"
_TUI_MSG_JA[deploy.caps.graphics]="graphics（OpenGL、Vulkan）"
_TUI_MSG_JA[deploy.runtime.prompt]="Docker ランタイムオーバーライド（Jetson / csv モード toolkit）"
_TUI_MSG_JA[deploy.runtime.auto]="auto（Jetson で自動的に runtime: nvidia を出力 — /etc/nv_tegra_release）"
_TUI_MSG_JA[deploy.runtime.nvidia]="nvidia（全ホストで強制出力）"
_TUI_MSG_JA[deploy.runtime.off]="off（オーバーライドなし — Docker 既定の runc）"
_TUI_MSG_JA[deploy.mig.title]="Deploy — NVIDIA MIG を検出"
_TUI_MSG_JA[deploy.mig.warning]=$'このホストでは NVIDIA MIG（Multi-Instance GPU）モードが有効です。\n\nDocker の deploy `count=N` は GPU 単位の予約であり、特定の MIG スライスを指定できません。特定スライスを使う場合は count を変更せず、[environment] セクションに次を追加してください：\n  NVIDIA_VISIBLE_DEVICES=<MIG-UUID>\n\nホストで利用可能な GPU / MIG インスタンス：\n%s'
_TUI_MSG_JA[gui.title]="GUI"
_TUI_MSG_JA[gui.mode.prompt]="GUI モード"
_TUI_MSG_JA[gui.mode.auto]="auto（\$DISPLAY／\$WAYLAND_DISPLAY を検出）"
_TUI_MSG_JA[gui.mode.force]="force（常に GUI ブロックを出力）"
_TUI_MSG_JA[gui.mode.off]="off（GUI ブロックを出力しない）"
_TUI_MSG_JA[volumes.title]="Volumes"
_TUI_MSG_JA[volumes.menu]="編集または追加するマウントを選択"
_TUI_MSG_JA[volumes.add]="マウントを追加"
_TUI_MSG_JA[volumes.edit.prompt]=$'マウント指定\n  - 形式: <host>:<container>[:ro|rw]\n  - 空 = この項目を削除\n  - 例: /data:/home/${USER_NAME}/data:rw'
_TUI_MSG_JA[volumes.delete.confirm]="マウント「%s」を削除？"
_TUI_MSG_JA[volumes.back]="メインメニューへ戻る"
_TUI_MSG_JA[devices.title]="Devices"
_TUI_MSG_JA[devices.menu]="編集するリストを選択"
_TUI_MSG_JA[devices.edit_devices]="Device bindings (devices:)"
_TUI_MSG_JA[devices.edit_cgroup]="Cgroup ルール (device_cgroup_rules:)"
_TUI_MSG_JA[devices.add_device]="device binding を追加"
_TUI_MSG_JA[devices.add_cgroup]="cgroup rule を追加"
_TUI_MSG_JA[devices.back]="メインメニューへ戻る"
_TUI_MSG_JA[devices.device.prompt]=$'デバイスバインド\n  - 形式: <host>[:<container>[:rwm]]\n  - 空 = この項目を削除\n  - デフォルト: /dev:/dev (/dev ツリー全体をバインド)\n  - 例 (単一): /dev/video0:/dev/video0'
_TUI_MSG_JA[devices.cgroup.title]="Cgroup ルール"
_TUI_MSG_JA[devices.cgroup.menu]="編集する項目を選択、または cgroup ルールを追加"
_TUI_MSG_JA[devices.cgroup.prompt]=$'Cgroup ルール\n  - 形式: <type> <major>:<minor|*> <perms>\n    type: c (文字)、b (ブロック)、a (全)\n    perms: r / w / m の任意組合せ\n  - 空 = この項目を削除\n  - USB 例: c 189:* rwm\n  - V4L2 例: c 81:* rwm'
_TUI_MSG_JA[resources.title]="Resources"
_TUI_MSG_JA[resources.shm_size.prompt]=$'/dev/shm サイズ\n  - 空 = Docker デフォルト 64mb\n  - 例: 2gb、512mb\n  - [network] ipc ≠ host のときのみ有効'
_TUI_MSG_JA[resources.shm_size.ignored]="注意：現在 [network] ipc = '%s'。Docker は shm_size を無視します（ipc が 'private' または 'shareable' のときのみ有効）。"
_TUI_MSG_JA[environment.title]="Environment"
_TUI_MSG_JA[environment.menu]="編集する環境変数を選択、または追加"
_TUI_MSG_JA[environment.add]="環境変数を追加"
_TUI_MSG_JA[environment.back]="メインメニューへ戻る"
_TUI_MSG_JA[environment.entry.prompt]=$'環境変数\n  - 形式: KEY=VALUE\n  - 空 = この項目を削除\n  - 例: ROS_DOMAIN_ID=7'
_TUI_MSG_JA[tmpfs.title]="Tmpfs"
_TUI_MSG_JA[tmpfs.menu]="編集する tmpfs 項目を選択、または追加"
_TUI_MSG_JA[tmpfs.add]="tmpfs マウントを追加"
_TUI_MSG_JA[tmpfs.back]="メインメニューへ戻る"
_TUI_MSG_JA[tmpfs.entry.prompt]=$'Tmpfs マウント\n  - 形式: <path>[:size=<size>]\n  - 空 = この項目を削除\n  - 例: /tmp:size=1g'
_TUI_MSG_JA[ports.title]="Ports"
_TUI_MSG_JA[ports.menu]="編集する port マッピングを選択、または追加"
_TUI_MSG_JA[ports.add]="port マッピングを追加"
_TUI_MSG_JA[ports.back]="メインメニューへ戻る"
_TUI_MSG_JA[ports.entry.prompt]=$'Port マッピング\n  - 形式: <host>:<container>[/protocol]\n  - 空 = この項目を削除\n  - 例: 8080:80 または 5000:5000/udp'
_TUI_MSG_JA[ports.not_bridge]="注意：現在 [network] mode = '%s'。ports は mode=bridge のときのみ compose.yaml に書き込まれます。"
_TUI_MSG_JA[additional_contexts.title]="追加 build context"
_TUI_MSG_JA[additional_contexts.menu]="編集または追加する名前付き context を選択"
_TUI_MSG_JA[additional_contexts.add]="名前付き context を追加"
_TUI_MSG_JA[additional_contexts.back]="メインメニューへ戻る"
_TUI_MSG_JA[additional_contexts.entry.prompt]=$'名前付き build context\n  - 形式: <name>=<source>\n  - 空 = この項目を削除\n  - <source> は BuildKit が受け付ける任意の形式: 相対パス、docker-image://、https://、oci-layout://\n  - 例（相対パス）: repo=..\n  - 例（image）: base=docker-image://debian:bookworm-slim'
_TUI_MSG_JA[err.invalid_mount]="マウント形式が不正（<host>:<container>[:ro|rw] を期待）"
_TUI_MSG_JA[err.invalid_additional_context]=$'名前付き build context が不正\n  - 形式: <name>=<source>\n  - <name>: [A-Za-z0-9] で始まり、文字／数字／[_.-]\n  - <source>: 空にできません\n  - 例: repo=..'
_TUI_MSG_JA[err.invalid_cgroup_rule]="Cgroup ルール形式が不正（<c|b|a> <major>:<minor|*> <r|w|m> を期待）"
_TUI_MSG_JA[err.invalid_gpu_count]="GPU 数が不正（'all' または正の整数を期待）"
_TUI_MSG_JA[err.invalid_runtime]="無効な runtime（'auto'、'nvidia'、'off' のいずれか）"
_TUI_MSG_JA[err.no_backend]="dialog または whiptail がインストールされていません：sudo apt install dialog"
_TUI_MSG_JA[saved]="%s に保存しました。.env + compose.yaml を再生成中..."
_TUI_MSG_JA[action.prompt]="アクションを選択"
_TUI_MSG_JA[action.edit]="編集"
_TUI_MSG_JA[action.remove]="削除（項目を削除）"
_TUI_MSG_JA[action.back]="戻る"


# _tui_msg <key>
_tui_msg() {
  local _key="${1}"
  local -n _table="_TUI_MSG_${_TUI_LANG_UPPER}"
  if [[ -n "${_table[${_key}]+x}" ]]; then
    printf '%s' "${_table[${_key}]}"
    return 0
  fi
  # fallback to English
  printf '%s' "${_TUI_MSG_EN[${_key}]:-${_key}}"
}

_tui_init_lang() {
  case "${_LANG}" in
    zh-TW) _TUI_LANG_UPPER="ZH_TW" ;;
    zh-CN) _TUI_LANG_UPPER="ZH_CN" ;;
    ja)    _TUI_LANG_UPPER="JA" ;;
    *)     _TUI_LANG_UPPER="EN" ;;
  esac
}

# Source-time default so _tui_msg works even when setup_tui.sh is sourced
# without going through main() (e.g. bats tests that source + invoke a
# specific section editor directly). main() re-runs _tui_init_lang after
# --lang parsing.
_TUI_LANG_UPPER="${_TUI_LANG_UPPER:-EN}"
_tui_init_lang 2>/dev/null || true

# ── Usage ─────────────────────────────────────────────────────────────────

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./setup_tui.sh [-h] [--lang <en|zh-TW|zh-CN|ja>] [SECTION]

互動式編輯 <repo>/setup.conf，完成後自動呼叫 setup.sh 重新產生
.env 與 compose.yaml。需要已安裝 dialog 或 whiptail。

SECTION（可直接跳至特定區段）:
  image     IMAGE_NAME 偵測規則
  build     Dockerfile build args（APT mirror）
  network   Network mode / IPC / privileged
  deploy    GPU 保留設定
  gui       GUI 顯示模式
  volumes   工作區與額外掛載
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./setup_tui.sh [-h] [--lang <en|zh-TW|zh-CN|ja>] [SECTION]

交互式编辑 <repo>/setup.conf，完成后自动调用 setup.sh 重新生成
.env 和 compose.yaml。需要已安装 dialog 或 whiptail。

SECTION（可直接跳至指定区段）:
  image     IMAGE_NAME 检测规则
  build     Dockerfile build args（APT mirror）
  network   Network mode / IPC / privileged
  deploy    GPU 预留设置
  gui       GUI 显示模式
  volumes   工作区与额外挂载
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./setup_tui.sh [-h] [--lang <en|zh-TW|zh-CN|ja>] [SECTION]

<repo>/setup.conf を対話的に編集し、完了後 setup.sh を自動実行して
.env と compose.yaml を再生成します。dialog または whiptail が必要。

SECTION（特定セクションへ直接移動）:
  image     IMAGE_NAME 検出ルール
  build     Dockerfile build args（APT ミラー）
  network   Network mode / IPC / privileged
  deploy    GPU 予約設定
  gui       GUI 表示モード
  volumes   ワークスペースと追加マウント
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./setup_tui.sh [-h] [--lang <en|zh-TW|zh-CN|ja>] [SECTION]

Interactively edit <repo>/setup.conf. On save, setup.sh is invoked
automatically to regenerate .env and compose.yaml. Requires dialog
or whiptail.

SECTION (jump directly to one section editor):
  image     IMAGE_NAME detection rules
  build     Dockerfile build args (APT mirrors)
  network   Network mode / IPC / privileged
  deploy    GPU reservation
  gui       GUI display mode
  volumes   Workspace + extra mounts
EOF
      ;;
  esac
  exit 0
}

# ── Overrides accumulator ────────────────────────────────────────────────
#
# Session state is stored in two parallel arrays used by _write_setup_conf:
#   _TUI_OVR_KEYS[i]   = "<section>.<key>"
#   _TUI_OVR_VALUES[i] = value
#
# _override_set appends or updates; _override_get returns current (falling
# back to the value loaded from the repo/template setup.conf).

declare -ga _TUI_OVR_KEYS=()
declare -ga _TUI_OVR_VALUES=()
declare -ga _TUI_REMOVED=()    # namespaced keys to drop on save
declare -gA _TUI_CURRENT=()    # baseline values loaded from setup.conf

_mark_removed() {
  local _nskey="${1}"
  # Drop any pending override for the same key; it's going away
  local i
  for (( i=0; i<${#_TUI_OVR_KEYS[@]}; i++ )); do
    if [[ "${_TUI_OVR_KEYS[i]}" == "${_nskey}" ]]; then
      unset '_TUI_OVR_KEYS[i]' '_TUI_OVR_VALUES[i]'
    fi
  done
  _TUI_OVR_KEYS=("${_TUI_OVR_KEYS[@]}")
  _TUI_OVR_VALUES=("${_TUI_OVR_VALUES[@]}")
  # Also wipe the baseline so the menu stops showing it
  unset '_TUI_CURRENT[${_nskey}]'
  local _x _found=0
  for _x in "${_TUI_REMOVED[@]}"; do
    [[ "${_x}" == "${_nskey}" ]] && _found=1 && break
  done
  (( _found )) || _TUI_REMOVED+=("${_nskey}")
}

# Show an Edit / Remove / Back sub-menu for an existing list entry.
# Echoes: __edit | __remove | __back (or empty on cancel)
_item_action_menu() {
  local _label="${1}"
  _tui_menu "${_label}" "$(_tui_msg action.prompt)" \
    __edit   "$(_tui_msg action.edit)" \
    __remove "$(_tui_msg action.remove)" \
    __back   "$(_tui_msg action.back)"
}

_override_set() {
  local _nskey="${1}"
  local _value="${2}"
  local i
  for (( i=0; i<${#_TUI_OVR_KEYS[@]}; i++ )); do
    if [[ "${_TUI_OVR_KEYS[i]}" == "${_nskey}" ]]; then
      _TUI_OVR_VALUES[i]="${_value}"
      return 0
    fi
  done
  _TUI_OVR_KEYS+=("${_nskey}")
  _TUI_OVR_VALUES+=("${_value}")
}

_override_get() {
  local _nskey="${1}"
  local _default="${2:-}"
  local i
  for (( i=0; i<${#_TUI_OVR_KEYS[@]}; i++ )); do
    if [[ "${_TUI_OVR_KEYS[i]}" == "${_nskey}" ]]; then
      printf '%s' "${_TUI_OVR_VALUES[i]}"
      return 0
    fi
  done
  printf '%s' "${_TUI_CURRENT[${_nskey}]:-${_default}}"
}

_load_current() {
  local _repo_conf="${1}"
  local _tpl_conf="${2}"
  local _src=""
  if [[ -f "${_repo_conf}" ]]; then
    _src="${_repo_conf}"
  elif [[ -f "${_tpl_conf}" ]]; then
    _src="${_tpl_conf}"
  else
    return 0
  fi
  local -a _sections=() _keys=() _values=()
  _load_setup_conf_full "${_src}" _sections _keys _values
  local i
  for (( i=0; i<${#_keys[@]}; i++ )); do
    _TUI_CURRENT[${_keys[i]}]="${_values[i]}"
  done
}

# ── Section editors ──────────────────────────────────────────────────────

_edit_section_image() {
  while :; do
    # Gather rule_N keys from baseline + overrides, dedupe, sort numerically.
    local -a _rule_nums=()
    local _k _n _x _found
    # shellcheck disable=SC2154
    for _k in "${!_TUI_CURRENT[@]}"; do
      if [[ "${_k}" == image.rule_* ]]; then
        _n="${_k#image.rule_}"
        [[ "${_n}" =~ ^[0-9]+$ ]] && _rule_nums+=("${_n}")
      fi
    done
    local i
    for (( i=0; i<${#_TUI_OVR_KEYS[@]}; i++ )); do
      if [[ "${_TUI_OVR_KEYS[i]}" == image.rule_* ]]; then
        _n="${_TUI_OVR_KEYS[i]#image.rule_}"
        if [[ "${_n}" =~ ^[0-9]+$ ]]; then
          _found=0
          for _x in "${_rule_nums[@]}"; do [[ "${_x}" == "${_n}" ]] && _found=1 && break; done
          (( _found )) || _rule_nums+=("${_n}")
        fi
      fi
    done
    # shellcheck disable=SC2207
    mapfile -t _rule_nums < <(printf '%s\n' "${_rule_nums[@]}" | sort -n | uniq)

    local -a _menu_args=()
    for _n in "${_rule_nums[@]}"; do
      local _cur_v
      _cur_v="$(_override_get "image.rule_${_n}" "")"
      [[ -z "${_cur_v}" ]] && continue
      _menu_args+=("rule_${_n}" "${_cur_v}")
    done
    _menu_args+=("add" "$(_tui_msg image.add)")
    _menu_args+=("back" "$(_tui_msg image.back)")

    local _choice
    _choice="$(_tui_menu "$(_tui_msg image.title)" \
      "$(_tui_msg image.menu)" "${_menu_args[@]}")" || return 0

    case "${_choice}" in
      back|"") return 0 ;;
      add)
        local _max=0 _x
        for _x in "${_rule_nums[@]}"; do (( _x > _max )) && _max="${_x}"; done
        _edit_image_rule "$(( _max + 1 ))" || true
        ;;
      rule_*)
        _edit_image_rule "${_choice#rule_}" || true
        ;;
    esac
  done
}

# _edit_image_rule <N>
#
# Two-step editor: select rule type (radiolist) → enter value (inputbox,
# skipped for typeless rules). Empty value at any step = leave unchanged.
_edit_image_rule() {
  local _n="${1}"
  local _cur _type _value
  _cur="$(_override_get "image.rule_${_n}" "")"

  # Derive current type + value from the stored string
  local _cur_type="" _cur_value=""
  if [[ "${_cur}" == prefix:* ]]; then _cur_type="prefix"; _cur_value="${_cur#prefix:}"
  elif [[ "${_cur}" == suffix:* ]]; then _cur_type="suffix"; _cur_value="${_cur#suffix:}"
  elif [[ "${_cur}" == string:* ]]; then _cur_type="string"; _cur_value="${_cur#string:}"
  elif [[ "${_cur}" == "@basename" ]]; then _cur_type="basename"
  elif [[ "${_cur}" == @default:* ]]; then _cur_type="default"; _cur_value="${_cur#@default:}"
  fi

  # Build radiolist dynamically: remove / move_up / move_down only
  # make sense when editing an EXISTING rule (_cur non-empty). For
  # "Add new rule" (_cur empty, N is max+1), hide them — there's
  # nothing to remove or relocate yet. Also hide move_up when _n == 1
  # (already at top, target would be < 1).
  local -a _opts=(
    string    "$(_tui_msg image.type.string)"   "$([[ "${_cur_type}" == string   ]] && echo ON || echo off)"
    prefix    "$(_tui_msg image.type.prefix)"   "$([[ "${_cur_type}" == prefix   ]] && echo ON || echo off)"
    suffix    "$(_tui_msg image.type.suffix)"   "$([[ "${_cur_type}" == suffix   ]] && echo ON || echo off)"
    basename  "$(_tui_msg image.type.basename)" "$([[ "${_cur_type}" == basename ]] && echo ON || echo off)"
    default   "$(_tui_msg image.type.default)"  "$([[ "${_cur_type}" == default  ]] && echo ON || echo off)"
  )
  if [[ -n "${_cur}" ]]; then
    (( _n > 1 )) && _opts+=(__move_up   "$(_tui_msg image.type.move_up)"   "off")
    _opts+=(__move_down "$(_tui_msg image.type.move_down)" "off")
    _opts+=(__remove    "$(_tui_msg image.type.remove)"    "off")
  fi
  _type="$(_tui_select "rule" "$(_tui_msg image.type.prompt)" "${_opts[@]}")" \
    || return 0

  local _final=""
  case "${_type}" in
    __remove)
      _compact_image_rules_after_remove "${_n}"
      return 0
      ;;
    __move_up)
      _swap_image_rule "${_n}" "$(( _n - 1 ))"
      return 0
      ;;
    __move_down)
      _swap_image_rule "${_n}" "$(( _n + 1 ))"
      return 0
      ;;
    prefix|suffix|string|default)
      _value="$(_tui_inputbox "rule" "$(_tui_msg image.value.prompt)" "${_cur_value}")" \
        || return 0
      if [[ "${_type}" == default ]]; then
        _final="@default:${_value}"
      else
        _final="${_type}:${_value}"
      fi
      ;;
    basename)
      _final="@basename"
      ;;
  esac

  # Dedupe: if the new rule string already exists at another slot,
  # drop the old slot so we end up with a single entry at _n
  # (adding a rule that already exists is treated as "move to this
  # position" — the user's intent when re-adding is usually to bump
  # the rule's priority, not to leave two identical copies).
  local _m _other
  for _m in "${!_TUI_CURRENT[@]}"; do
    [[ "${_m}" == image.rule_* ]] || continue
    [[ "${_m}" == "image.rule_${_n}" ]] && continue
    _other="$(_override_get "${_m}" "")"
    [[ "${_other}" == "${_final}" ]] && _mark_removed "${_m}"
  done
  local _i
  for (( _i=0; _i<${#_TUI_OVR_KEYS[@]}; _i++ )); do
    [[ "${_TUI_OVR_KEYS[_i]}" == image.rule_* ]] || continue
    [[ "${_TUI_OVR_KEYS[_i]}" == "image.rule_${_n}" ]] && continue
    [[ "${_TUI_OVR_VALUES[_i]}" == "${_final}" ]] && _mark_removed "${_TUI_OVR_KEYS[_i]}"
  done

  _override_set "image.rule_${_n}" "${_final}"
}

# _compact_image_rules_after_remove <n>
#
# Drop image.rule_${_n} and shift the values of higher-numbered rules
# down by one slot, so the user always sees consecutive indices
# (rule_1 .. rule_M) after a delete and the next "add" allocates
# max+1 without leaving a gap (#177). Also collapses any pre-existing
# sparse slots above _n as a side effect, since the loop only walks
# occupied slots in ascending order.
_compact_image_rules_after_remove() {
  local _removed_n="${1:?}"
  local -a _nums=()
  local _k _n _x _found _i
  for _k in "${!_TUI_CURRENT[@]}"; do
    if [[ "${_k}" == image.rule_* ]]; then
      _n="${_k#image.rule_}"
      [[ "${_n}" =~ ^[0-9]+$ ]] && _nums+=("${_n}")
    fi
  done
  for (( _i=0; _i<${#_TUI_OVR_KEYS[@]}; _i++ )); do
    if [[ "${_TUI_OVR_KEYS[_i]}" == image.rule_* ]]; then
      _n="${_TUI_OVR_KEYS[_i]#image.rule_}"
      if [[ "${_n}" =~ ^[0-9]+$ ]]; then
        _found=0
        for _x in "${_nums[@]}"; do [[ "${_x}" == "${_n}" ]] && _found=1 && break; done
        (( _found )) || _nums+=("${_n}")
      fi
    fi
  done
  # shellcheck disable=SC2207
  mapfile -t _nums < <(printf '%s\n' "${_nums[@]}" | sort -n | uniq)

  local _slot="${_removed_n}"
  local _val
  for _n in "${_nums[@]}"; do
    (( _n <= _removed_n )) && continue
    _val="$(_override_get "image.rule_${_n}" "")"
    [[ -z "${_val}" ]] && continue
    _override_set "image.rule_${_slot}" "${_val}"
    _slot="${_n}"
  done
  _mark_removed "image.rule_${_slot}"
}

# _swap_image_rule <n> <m>
#
# Swap image.rule_${_n} ↔ image.rule_${_m}. Used by Move up / Move
# down. Out-of-range targets (m < 1, or m not occupied when moving
# down) are silently no-ops: UI wise the user sees the list unchanged,
# which matches the natural "already at top / bottom" expectation.
_swap_image_rule() {
  local _n="${1:?}"
  local _m="${2:?}"
  (( _m < 1 )) && return 0
  local _a _b
  _a="$(_override_get "image.rule_${_n}" "")"
  _b="$(_override_get "image.rule_${_m}" "")"
  # Both empty → nothing to do. One empty → treat as swap with empty
  # (equivalent to moving the non-empty entry into the empty slot and
  # removing the old one).
  if [[ -z "${_a}" && -z "${_b}" ]]; then
    return 0
  fi
  if [[ -z "${_b}" ]]; then
    _mark_removed "image.rule_${_n}"
    _override_set "image.rule_${_m}" "${_a}"
    return 0
  fi
  if [[ -z "${_a}" ]]; then
    _mark_removed "image.rule_${_m}"
    _override_set "image.rule_${_n}" "${_b}"
    return 0
  fi
  _override_set "image.rule_${_n}" "${_b}"
  _override_set "image.rule_${_m}" "${_a}"
}

_edit_section_build() {
  while true; do
    local _arch_cur _arch_display _net_cur _net_display _args_cnt
    _arch_cur="$(_override_get "build.target_arch" "")"
    if [[ -n "${_arch_cur}" ]]; then
      _arch_display="${_arch_cur}"
    else
      _arch_display="$(_tui_msg build.target_arch.auto)"
    fi
    _net_cur="$(_override_get "build.network" "")"
    if [[ -n "${_net_cur}" ]]; then
      _net_display="${_net_cur}"
    else
      _net_display="$(_tui_msg build.network.default)"
    fi
    # Count populated arg_N slots for the menu-item badge. Pulls from
    # the pending override state (_TUI_CURRENT is the effective view
    # after overrides + removals have been merged).
    _args_cnt=0
    local _ak
    # shellcheck disable=SC2154
    for _ak in "${!_TUI_CURRENT[@]}"; do
      [[ "${_ak}" == build.arg_* ]] || continue
      [[ -n "${_TUI_CURRENT[${_ak}]}" ]] && _args_cnt=$((_args_cnt + 1))
    done

    local _choice
    _choice="$(_tui_menu "$(_tui_msg build.title)" "$(_tui_msg build.menu)" \
      target_arch "$(_tui_msg build.target_arch.label) = ${_arch_display}" \
      network     "$(_tui_msg build.network.label) = ${_net_display}" \
      args        "$(_tui_msg build.args.label) (${_args_cnt})" \
      __back      "$(_tui_msg build.back)")" || return 0

    case "${_choice}" in
      target_arch)
        local _new
        _new="$(_tui_inputbox "$(_tui_msg build.title)" \
          "$(_tui_msg build.target_arch.prompt)" "${_arch_cur}")" || continue
        if ! _validate_target_arch "${_new}"; then
          _tui_msgbox "$(_tui_msg build.title)" "$(_tui_msg err.invalid_target_arch)"
          continue
        fi
        # Consistent with other scalar keys (e.g. resources.shm_size):
        # empty value keeps the key present with "" in setup.conf, and
        # setup.sh's `[[ -n $target_arch ]]` check handles the empty
        # case by omitting TARGETARCH from .env + compose.yaml.
        _override_set "build.target_arch" "${_new}"
        ;;
      network)
        local _new_net
        _new_net="$(_tui_inputbox "$(_tui_msg build.title)" \
          "$(_tui_msg build.network.prompt)" "${_net_cur}")" || continue
        if ! _validate_build_network "${_new_net}"; then
          _tui_msgbox "$(_tui_msg build.title)" "$(_tui_msg err.invalid_build_network)"
          continue
        fi
        _override_set "build.network" "${_new_net}"
        ;;
      args)
        _edit_list_section build arg_ \
          build.title build.menu build.add build.back \
          build.arg.prompt _validate_env_kv err.invalid_env_kv
        ;;
      __back|"") return 0 ;;
    esac
  done
}

_edit_section_network() {
  local _v _cur
  _cur="$(_override_get "network.mode" "host")"
  _v="$(_tui_select "$(_tui_msg network.title)" "$(_tui_msg network.mode.prompt)" \
    host   "$(_tui_msg network.mode.host)"   "$([[ "${_cur}" == host ]]   && echo ON || echo off)" \
    bridge "$(_tui_msg network.mode.bridge)" "$([[ "${_cur}" == bridge ]] && echo ON || echo off)" \
    none   "$(_tui_msg network.mode.none)"   "$([[ "${_cur}" == none ]]   && echo ON || echo off)")" \
    || return 0
  _override_set "network.mode" "${_v}"
  local _selected_mode="${_v}"

  _cur="$(_override_get "network.ipc" "host")"
  _v="$(_tui_select "$(_tui_msg network.title)" "$(_tui_msg network.ipc.prompt)" \
    host      "$(_tui_msg network.ipc.host)"      "$([[ "${_cur}" == host ]]      && echo ON || echo off)" \
    shareable "$(_tui_msg network.ipc.shareable)" "$([[ "${_cur}" == shareable ]] && echo ON || echo off)" \
    private   "$(_tui_msg network.ipc.private)"   "$([[ "${_cur}" == private ]]   && echo ON || echo off)")" \
    || return 0
  _override_set "network.ipc" "${_v}"
  local _selected_ipc="${_v}"

  # mode=bridge triggers: network_name + ports list
  if [[ "${_selected_mode}" == "bridge" ]]; then
    _cur="$(_override_get "network.network_name" "")"
    while :; do
      _v="$(_tui_inputbox "$(_tui_msg network.title)" "$(_tui_msg network.name.prompt)" "${_cur}")" \
        || return 0
      # Empty is allowed (compose creates default bridge) — skip validation.
      if [[ -z "${_v}" ]] || _validate_network_name "${_v}"; then
        _override_set "network.network_name" "${_v}"
        break
      fi
      _tui_msgbox "$(_tui_msg network.title)" "$(_tui_msg err.invalid_network_name)"
      _cur="${_v}"
    done
    _edit_section_ports || true
  else
    _override_set "network.network_name" ""
  fi

  # ipc != host triggers: shm_size prompt (empty leaves Docker default 64mb).
  # Inline the inputbox so the dialog title says "shm_size" instead of the
  # generic "Resources" (users reported missing this prompt otherwise).
  if [[ "${_selected_ipc}" != "host" ]]; then
    _cur="$(_override_get "resources.shm_size" "")"
    while :; do
      _v="$(_tui_inputbox "shm_size (ipc=${_selected_ipc})" \
        "$(_tui_msg resources.shm_size.prompt)" "${_cur}")" || return 0
      # Empty is allowed (Docker default 64mb) — skip validation.
      if [[ -z "${_v}" ]] || _validate_shm_size "${_v}"; then
        _override_set "resources.shm_size" "${_v}"
        break
      fi
      _tui_msgbox "shm_size" "$(_tui_msg err.invalid_shm_size)"
      _cur="${_v}"
    done
  fi
}

_edit_section_security() {
  while :; do
    local _priv_cur
    _priv_cur="$(_override_get "security.privileged" "true")"
    local _cap_add_cnt=0 _cap_drop_cnt=0 _sec_opt_cnt=0
    local _k
    # shellcheck disable=SC2154
    for _k in "${!_TUI_CURRENT[@]}"; do
      case "${_k}" in
        security.cap_add_*)      _cap_add_cnt=$(( _cap_add_cnt + 1 )) ;;
        security.cap_drop_*)     _cap_drop_cnt=$(( _cap_drop_cnt + 1 )) ;;
        security.security_opt_*) _sec_opt_cnt=$(( _sec_opt_cnt + 1 )) ;;
      esac
    done

    local _choice
    _choice="$(_tui_menu "$(_tui_msg security.title)" "$(_tui_msg security.menu)" \
      privileged   "privileged = ${_priv_cur}" \
      cap_add      "$(_tui_msg security.cap_add) (${_cap_add_cnt})" \
      cap_drop     "$(_tui_msg security.cap_drop) (${_cap_drop_cnt})" \
      security_opt "$(_tui_msg security.security_opt) (${_sec_opt_cnt})" \
      __back       "$(_tui_msg security.back)")" || return 0

    case "${_choice}" in
      privileged)
        if _tui_yesno "$(_tui_msg security.title)" "$(_tui_msg security.privileged.prompt)"; then
          _override_set "security.privileged" "true"
        else
          _override_set "security.privileged" "false"
        fi
        ;;
      cap_add)
        _edit_list_section security cap_add_ \
          security.title security.cap_add.menu security.cap_add.add security.back \
          security.cap_add.prompt _validate_capability err.invalid_capability
        ;;
      cap_drop)
        _edit_list_section security cap_drop_ \
          security.title security.cap_drop.menu security.cap_drop.add security.back \
          security.cap_drop.prompt _validate_capability err.invalid_capability
        ;;
      security_opt)
        _edit_list_section security security_opt_ \
          security.title security.security_opt.menu security.security_opt.add security.back \
          security.security_opt.prompt
        ;;
      __back|"") return 0 ;;
    esac
  done
}

_edit_section_deploy() {
  local _v _cur
  _cur="$(_override_get "deploy.gpu_mode" "auto")"
  _v="$(_tui_select "$(_tui_msg deploy.title)" "$(_tui_msg deploy.mode.prompt)" \
    auto  "$(_tui_msg deploy.mode.auto)"  "$([[ "${_cur}" == auto ]]  && echo ON || echo off)" \
    force "$(_tui_msg deploy.mode.force)" "$([[ "${_cur}" == force ]] && echo ON || echo off)" \
    off   "$(_tui_msg deploy.mode.off)"   "$([[ "${_cur}" == off ]]   && echo ON || echo off)")" \
    || return 0
  _override_set "deploy.gpu_mode" "${_v}"
  # GPU disabled → count/capabilities are irrelevant; skip the rest.
  [[ "${_v}" == "off" ]] && return 0

  # MIG (Multi-Instance GPU) advisory. When the host has MIG enabled,
  # Docker's `count=N` reservation addresses whole GPUs, not MIG slices.
  # Warn the user and show available slice UUIDs so they can pin a
  # specific slice via NVIDIA_VISIBLE_DEVICES=<MIG-UUID> in the
  # [environment] section. Proceeds with the normal count/capabilities
  # flow either way.
  if _detect_mig; then
    local _mig_fmt _mig_msg _mig_list
    _mig_list="$(_list_gpu_instances)"
    _mig_fmt="$(_tui_msg deploy.mig.warning)"
    # shellcheck disable=SC2059  # msg source is our own i18n table
    _mig_msg="$(printf "${_mig_fmt}" "${_mig_list}")"
    _tui_msgbox "$(_tui_msg deploy.mig.title)" "${_mig_msg}"
  fi

  # Probe host for installed NVIDIA GPU count; surface in prompt so the
  # user has a reference value when choosing "all" vs a specific integer.
  local _host_gpu_count=0
  if command -v nvidia-smi >/dev/null 2>&1; then
    _host_gpu_count="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
    [[ "${_host_gpu_count}" =~ ^[0-9]+$ ]] || _host_gpu_count=0
  fi
  local _count_fmt _count_prompt
  _count_fmt="$(_tui_msg deploy.count.prompt)"
  # shellcheck disable=SC2059  # format string sourced from our own i18n table
  _count_prompt="$(printf "${_count_fmt}" "${_host_gpu_count}")"

  while :; do
    _cur="$(_override_get "deploy.gpu_count" "all")"
    _v="$(_tui_inputbox "$(_tui_msg deploy.title)" "${_count_prompt}" "${_cur}")" \
      || return 0
    if _validate_gpu_count "${_v}"; then
      _override_set "deploy.gpu_count" "${_v}"
      break
    fi
    _tui_msgbox "$(_tui_msg deploy.title)" "$(_tui_msg err.invalid_gpu_count)"
  done

  _cur="$(_override_get "deploy.gpu_capabilities" "gpu")"
  local _on_gpu=off _on_compute=off _on_utility=off _on_graphics=off
  [[ " ${_cur} " == *" gpu "* ]]      && _on_gpu=ON
  [[ " ${_cur} " == *" compute "* ]]  && _on_compute=ON
  [[ " ${_cur} " == *" utility "* ]]  && _on_utility=ON
  [[ " ${_cur} " == *" graphics "* ]] && _on_graphics=ON
  _v="$(_tui_checklist "$(_tui_msg deploy.title)" "$(_tui_msg deploy.caps.prompt)" \
    gpu      "$(_tui_msg deploy.caps.gpu)"      "${_on_gpu}" \
    compute  "$(_tui_msg deploy.caps.compute)"  "${_on_compute}" \
    utility  "$(_tui_msg deploy.caps.utility)"  "${_on_utility}" \
    graphics "$(_tui_msg deploy.caps.graphics)" "${_on_graphics}")" \
    || return 0
  # checklist with --separate-output returns newline-separated; flatten to space
  _v="$(echo "${_v}" | tr '\n' ' ' | sed -e 's/ *$//')"
  [[ -z "${_v}" ]] && _v="gpu"
  _override_set "deploy.gpu_capabilities" "${_v}"

  # runtime override (Jetson / csv-mode nvidia-container-toolkit).
  _cur="$(_override_get "deploy.runtime" "auto")"
  _v="$(_tui_select "$(_tui_msg deploy.title)" "$(_tui_msg deploy.runtime.prompt)" \
    auto   "$(_tui_msg deploy.runtime.auto)"   "$([[ "${_cur}" == auto ]]   && echo ON || echo off)" \
    nvidia "$(_tui_msg deploy.runtime.nvidia)" "$([[ "${_cur}" == nvidia ]] && echo ON || echo off)" \
    off    "$(_tui_msg deploy.runtime.off)"    "$([[ "${_cur}" == off ]]    && echo ON || echo off)")" \
    || return 0
  if _validate_runtime "${_v}"; then
    _override_set "deploy.runtime" "${_v}"
  else
    _tui_msgbox "$(_tui_msg deploy.title)" "$(_tui_msg err.invalid_runtime)"
  fi
}

_edit_section_gui() {
  local _v _cur
  _cur="$(_override_get "gui.mode" "auto")"
  _v="$(_tui_select "$(_tui_msg gui.title)" "$(_tui_msg gui.mode.prompt)" \
    auto  "$(_tui_msg gui.mode.auto)"  "$([[ "${_cur}" == auto ]]  && echo ON || echo off)" \
    force "$(_tui_msg gui.mode.force)" "$([[ "${_cur}" == force ]] && echo ON || echo off)" \
    off   "$(_tui_msg gui.mode.off)"   "$([[ "${_cur}" == off ]]   && echo ON || echo off)")" \
    || return 0
  _override_set "gui.mode" "${_v}"
}

_edit_section_volumes() {
  _edit_list_section volumes mount_ \
    volumes.title volumes.menu volumes.add volumes.back volumes.edit.prompt \
    _validate_mount err.invalid_mount
}

_edit_section_resources() {
  local _v _cur _ipc
  _ipc="$(_override_get "network.ipc" "host")"
  if [[ "${_ipc}" == "host" ]]; then
    local _fmt _msg
    _fmt="$(_tui_msg resources.shm_size.ignored)"
    # shellcheck disable=SC2059  # msg source is our own i18n table
    _msg="$(printf "${_fmt}" "${_ipc}")"
    _tui_msgbox "$(_tui_msg resources.title)" "${_msg}"
    # Still allow setting it (for when user later flips ipc to private).
  fi
  _cur="$(_override_get "resources.shm_size" "")"
  _v="$(_tui_inputbox "$(_tui_msg resources.title)" \
    "$(_tui_msg resources.shm_size.prompt)" "${_cur}")" || return 0
  _override_set "resources.shm_size" "${_v}"
}

# _edit_list_section <section> <prefix> <title_key> <menu_key> <add_key> <back_key> <entry_prompt_key>
#
# Generic list editor used by environment / tmpfs / ports. Mirrors the
# volumes pattern: shows existing entries, Add creates the next numbered
# slot, existing items go through Edit / Remove / Back sub-menu.
_edit_list_section() {
  local _section="${1}" _prefix="${2}"
  local _title_key="${3}" _menu_key="${4}" _add_key="${5}" _back_key="${6}"
  local _entry_key="${7}"
  local _validator="${8:-}" _err_key="${9:-}"

  while :; do
    local -a _nums=()
    local _k _n _x _found
    # shellcheck disable=SC2154
    for _k in "${!_TUI_CURRENT[@]}"; do
      if [[ "${_k}" == "${_section}.${_prefix}"* ]]; then
        _n="${_k#"${_section}.${_prefix}"}"
        [[ "${_n}" =~ ^[0-9]+$ ]] && _nums+=("${_n}")
      fi
    done
    local i
    for (( i=0; i<${#_TUI_OVR_KEYS[@]}; i++ )); do
      if [[ "${_TUI_OVR_KEYS[i]}" == "${_section}.${_prefix}"* ]]; then
        _n="${_TUI_OVR_KEYS[i]#"${_section}.${_prefix}"}"
        if [[ "${_n}" =~ ^[0-9]+$ ]]; then
          _found=0
          for _x in "${_nums[@]}"; do [[ "${_x}" == "${_n}" ]] && _found=1 && break; done
          (( _found )) || _nums+=("${_n}")
        fi
      fi
    done
    # shellcheck disable=SC2207
    mapfile -t _nums < <(printf '%s\n' "${_nums[@]}" | sort -n | uniq)

    local -a _menu_args=()
    for _n in "${_nums[@]}"; do
      local _cur_v
      _cur_v="$(_override_get "${_section}.${_prefix}${_n}" "")"
      # Skip empty entries — cleaner "new list" look (no dangling
      # "<prefix>_N <empty>" rows the user cleared or never filled).
      [[ -z "${_cur_v}" ]] && continue
      _menu_args+=("${_prefix}${_n}" "${_cur_v}")
    done
    _menu_args+=("add"  "$(_tui_msg "${_add_key}")")
    _menu_args+=("back" "$(_tui_msg "${_back_key}")")

    local _choice
    _choice="$(_tui_menu "$(_tui_msg "${_title_key}")" \
      "$(_tui_msg "${_menu_key}")" "${_menu_args[@]}")" || return 0

    case "${_choice}" in
      back|"") return 0 ;;
      add)
        # Pick the lowest index >= 1 that is free — either the key does
        # not exist, or its value is empty (user cleared it = opted out,
        # safe to reuse). Prevents `mount_2` from appearing when the
        # user cleared `mount_1`, which would leave a confusing hole.
        local _next=1 _v
        while :; do
          _v="$(_override_get "${_section}.${_prefix}${_next}" "")"
          [[ -z "${_v}" ]] && break
          (( _next++ ))
        done
        _edit_list_entry "${_section}" "${_prefix}" "${_next}" \
          "$(_tui_msg "${_entry_key}")" "${_validator}" "${_err_key}" || true
        ;;
      "${_prefix}"*)
        # Direct edit: click item -> inputbox. Empty value marks the key
        # for removal (no separate Edit/Remove sub-menu).
        _edit_list_entry "${_section}" "${_prefix}" "${_choice#"${_prefix}"}" \
          "$(_tui_msg "${_entry_key}")" "${_validator}" "${_err_key}" || true
        ;;
    esac
  done
}

_edit_list_entry() {
  local _section="${1}" _prefix="${2}" _n="${3}" _prompt="${4}"
  local _validator="${5:-}" _err_key="${6:-}"
  local _nskey="${_section}.${_prefix}${_n}"
  # Dialog title strips the trailing underscore so "env_" becomes "env",
  # "mount_" becomes "mount" — cleaner header without the per-entry index.
  local _title="${_prefix%_}"
  local _cur _v
  _cur="$(_override_get "${_nskey}" "")"
  while :; do
    _v="$(_tui_inputbox "${_title}" "${_prompt}" "${_cur}")" || return 0
    # Empty input = delete the entry (user opted out).
    if [[ -z "${_v}" ]]; then
      _mark_removed "${_nskey}"
      return 0
    fi
    # Non-empty: validate if a validator was provided.
    if [[ -z "${_validator}" ]] || "${_validator}" "${_v}"; then
      _override_set "${_nskey}" "${_v}"
      return 0
    fi
    # Invalid → show error + preserve typed value for correction.
    _tui_msgbox "${_prefix}${_n}" "$(_tui_msg "${_err_key}")"
    _cur="${_v}"
  done
}

_edit_section_environment() {
  _edit_list_section environment env_ \
    environment.title environment.menu environment.add environment.back \
    environment.entry.prompt _validate_env_kv err.invalid_env_kv
}

_edit_section_tmpfs() {
  _edit_list_section tmpfs tmpfs_ \
    tmpfs.title tmpfs.menu tmpfs.add tmpfs.back tmpfs.entry.prompt
}

_edit_section_ports() {
  # Hint if current network mode is not bridge (ports will be dropped).
  local _mode
  _mode="$(_override_get "network.mode" "host")"
  if [[ "${_mode}" != "bridge" ]]; then
    local _fmt _msg
    _fmt="$(_tui_msg ports.not_bridge)"
    # shellcheck disable=SC2059
    _msg="$(printf "${_fmt}" "${_mode}")"
    _tui_msgbox "$(_tui_msg ports.title)" "${_msg}"
  fi
  _edit_list_section network port_ \
    ports.title ports.menu ports.add ports.back ports.entry.prompt \
    _validate_port_mapping err.invalid_port_mapping
}

_edit_section_devices() {
  while :; do
    local _choice
    _choice="$(_tui_menu "$(_tui_msg devices.title)" \
      "$(_tui_msg devices.menu)" \
      device       "$(_tui_msg devices.edit_devices)" \
      cgroup_rule  "$(_tui_msg devices.edit_cgroup)" \
      back         "$(_tui_msg devices.back)")" || return 0
    case "${_choice}" in
      back|"") return 0 ;;
      device)
        _edit_list_section devices device_ \
          devices.title devices.menu devices.add_device devices.back \
          devices.device.prompt _validate_mount err.invalid_mount
        ;;
      cgroup_rule)
        _edit_list_section devices cgroup_rule_ \
          devices.cgroup.title devices.cgroup.menu devices.add_cgroup devices.back \
          devices.cgroup.prompt _validate_cgroup_rule err.invalid_cgroup_rule
        ;;
    esac
  done
}

_edit_section_additional_contexts() {
  _edit_list_section additional_contexts context_ \
    additional_contexts.title additional_contexts.menu \
    additional_contexts.add additional_contexts.back \
    additional_contexts.entry.prompt \
    _validate_additional_context err.invalid_additional_context
}

# ── Main menu ────────────────────────────────────────────────────────────

_render_main_menu() {
  # Footer button labels are NOT i18n'd — keep a stable English
  # "Enter / Cancel" row across all locales so users never see a mix
  # of English widget chrome and translated buttons, and so
  # screenshots / docs stay consistent.
  export TUI_OK_LABEL TUI_CANCEL_LABEL
  TUI_OK_LABEL="Enter"
  TUI_CANCEL_LABEL="Cancel"
  # Save & Exit lives in the menu body for both backends (#178).
  # whiptail has no `--extra-button` equivalent at all (newt limit),
  # and using dialog's `--extra-button` made the same repo render with
  # different button rows on dialog vs whiptail hosts — breaking shared
  # screenshots / docs. Standardizing on a synthetic `__save` entry
  # gives identical layout regardless of backend; the small extra
  # navigation step on dialog is acceptable for the consistency win.
  while :; do
    local _choice _rc
    _choice="$(_tui_menu "$(_tui_msg title)" "$(_tui_msg main.prompt)" \
      network     "$(_tui_msg main.network)" \
      deploy      "$(_tui_msg main.deploy)" \
      gui         "$(_tui_msg main.gui)" \
      volumes     "$(_tui_msg main.volumes)" \
      environment "$(_tui_msg main.environment)" \
      advanced    "$(_tui_msg main.advanced)" \
      __save      "$(_tui_msg main.save)")"
    _rc=$?
    case "${_rc}" in
      0)
        case "${_choice}" in
          network|deploy|gui|volumes|environment) "_edit_section_${_choice}" ;;
          advanced) _render_advanced_menu ;;
          __save)   TUI_OK_LABEL=""; TUI_CANCEL_LABEL=""; return 0 ;;
          "")       TUI_OK_LABEL=""; TUI_CANCEL_LABEL=""; return 1 ;;
        esac
        ;;
      *)  TUI_OK_LABEL=""; TUI_CANCEL_LABEL=""; return 1 ;;   # Cancel / Esc
    esac
  done
}

_render_advanced_menu() {
  while :; do
    local _choice
    _choice="$(_tui_menu "$(_tui_msg advanced.title)" "$(_tui_msg advanced.menu)" \
      image                "$(_tui_msg main.image)" \
      build                "$(_tui_msg main.build)" \
      devices              "$(_tui_msg main.devices)" \
      tmpfs                "$(_tui_msg main.tmpfs)" \
      security             "$(_tui_msg main.security)" \
      additional_contexts  "$(_tui_msg main.additional_contexts)" \
      reset                "$(_tui_msg advanced.reset)" \
      __back               "$(_tui_msg advanced.back)")" || break
    case "${_choice}" in
      image|build|devices|tmpfs|security|additional_contexts) "_edit_section_${_choice}" ;;
      reset)    _do_reset ;;
      __back|"") break ;;
    esac
  done
}

# _do_reset
#
# Restore the repo's setup.conf to the template baseline: remove the
# per-repo setup.conf, re-run setup.sh (which copies template + writes
# detected workspace into mount_1), then clear all TUI session state
# so the reloaded values are what the user sees on the next menu.
_do_reset() {
  _tui_yesno "$(_tui_msg reset.title)" "$(_tui_msg reset.confirm)" || return 0
  # Reset deletes the per-repo override (setup.conf). The next apply
  # re-bootstraps it from the template baseline + detected workspace.
  rm -f "${FILE_PATH}/setup.conf"
  "${_TUI_SCRIPT_DIR}/setup.sh" apply --base-path "${FILE_PATH}" --lang "${_LANG}" \
    >/dev/null 2>&1 || true
  _TUI_OVR_KEYS=()
  _TUI_OVR_VALUES=()
  _TUI_REMOVED=()
  _TUI_CURRENT=()
  _load_current "${FILE_PATH}/setup.conf" "${_TUI_TPL_DIR}/setup.conf"
  _tui_msgbox "$(_tui_msg reset.title)" "$(_tui_msg reset.done)"
}

# ── Commit & trigger setup.sh ────────────────────────────────────────────

_commit_and_setup() {
  local _repo_conf="${1}"
  local _tpl_conf="${2}"

  # Merge current baseline into overrides for keys the user did not touch
  # (so _write_setup_conf preserves untouched values via template).
  # Build final arrays directly from _TUI_OVR_* + _TUI_CURRENT.
  local -a _final_sections=() _final_keys=() _final_values=()
  local _k
  for _k in "${!_TUI_CURRENT[@]}"; do
    _final_keys+=("${_k}")
    _final_values+=("${_TUI_CURRENT[${_k}]}")
  done
  local i
  for (( i=0; i<${#_TUI_OVR_KEYS[@]}; i++ )); do
    _k="${_TUI_OVR_KEYS[i]}"
    local _found=0 j
    for (( j=0; j<${#_final_keys[@]}; j++ )); do
      if [[ "${_final_keys[j]}" == "${_k}" ]]; then
        _final_values[j]="${_TUI_OVR_VALUES[i]}"
        _found=1
        break
      fi
    done
    (( _found )) || { _final_keys+=("${_k}"); _final_values+=("${_TUI_OVR_VALUES[i]}"); }
  done

  # Write via template (per-repo setup.conf falls back to template's structure)
  local _template_src="${_tpl_conf}"
  [[ -f "${_repo_conf}" ]] && _template_src="${_repo_conf}"

  _write_setup_conf "${_repo_conf}" "${_template_src}" \
    _final_sections _final_keys _final_values \
    "${_TUI_REMOVED[*]:-}"
  _tui_clear
  # The `saved` message contains a %s placeholder that we feed _repo_conf
  # into. SC2059 warns about format-from-variable — acceptable here because
  # the message source is our own i18n table, not external input.
  local _saved_fmt
  _saved_fmt="$(_tui_msg saved)"
  # shellcheck disable=SC2059
  printf "[tui] ${_saved_fmt}\n" "${_repo_conf}"
  "${_TUI_SCRIPT_DIR}/setup.sh" apply --base-path "${FILE_PATH}" --lang "${_LANG}"
}

# ── main ─────────────────────────────────────────────────────────────────

# _warn_if_lang_rejected <bad_input>
#
# When _sanitize_lang had to fall back to "en" because --lang was an
# unknown value, open a TUI msgbox to tell the user. The stderr
# warning from _sanitize_lang is useless here since dialog/whiptail's
# curses rendering clears it before the user can read it.
#
# <bad_input> is the original string the user passed; empty = no-op.
_warn_if_lang_rejected() {
  local _bad="${1:-}"
  [[ -z "${_bad}" ]] && return 0
  # shellcheck disable=SC2059  # body is our own i18n template
  _tui_msgbox "$(_tui_msg lang.invalid.title)" \
    "$(printf "$(_tui_msg lang.invalid.body)" "${_bad}")"
}

main() {
  local _subcmd=""
  # Remember the raw --lang value if sanitize rejects it, so we can
  # surface the warning INSIDE the TUI (the stderr message from
  # _sanitize_lang gets hidden by curses once dialog takes over).
  local _bad_lang_input=""

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -h|--help) usage ;;
      --lang)
        _LANG="${2:?"--lang requires a value"}"
        local _lang_before="${_LANG}"
        # Silence sanitize's stderr — the TUI msgbox below replaces it.
        _sanitize_lang _LANG "tui" 2>/dev/null
        if [[ "${_LANG}" != "${_lang_before}" ]]; then
          _bad_lang_input="${_lang_before}"
        fi
        shift 2
        ;;
      image|build|network|deploy|gui|volumes|devices|resources|environment|tmpfs|ports|security)
        _subcmd="${1}"
        shift
        ;;
      *)
        printf "[tui] unknown argument: %s\n" "${1}" >&2
        usage
        ;;
    esac
  done

  _tui_init_lang

  if ! _backend_detect; then
    printf "[tui] %s\n" "$(_tui_msg err.no_backend)" >&2
    exit 2
  fi

  # Surface the --lang rejection before the main menu opens.
  _warn_if_lang_rejected "${_bad_lang_input}"

  # TUI's save target is the per-repo override (setup.conf). Loading
  # reads it on top of the template baseline so existing overrides
  # surface as the menu's initial values; new edits land in setup.conf.
  local _repo_conf="${FILE_PATH}/setup.conf"
  local _tpl_conf="${_TUI_TPL_DIR}/setup.conf"
  # First-run bootstrap: when no per-repo setup.conf exists yet, run
  # setup.sh apply so mount_1 detection seeds the file before the TUI
  # opens its menus.
  if [[ ! -f "${_repo_conf}" ]]; then
    "${_TUI_SCRIPT_DIR}/setup.sh" apply --base-path "${FILE_PATH}" --lang "${_LANG}" \
      >/dev/null 2>&1 || true
  fi
  _load_current "${_repo_conf}" "${_tpl_conf}"

  if [[ -n "${_subcmd}" ]]; then
    "_edit_section_${_subcmd}"
  else
    if ! _render_main_menu; then
      # Cancelled
      _tui_clear
      exit 0
    fi
  fi

  _commit_and_setup "${_repo_conf}" "${_tpl_conf}"
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
