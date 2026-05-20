# Standalone scripts smoke

集成 smoke 测试 `isaac_ws/src/script/*_standalone.py`。每支 script 在透过 `./exec.sh -t standalone /isaac-sim/python.sh <script>` 跑起来后,必须在 timeout 内打印出对应的 "ready marker" 字串。Runner 启动 script、轮询 stdout 找 marker,看到就收掉,回报每个 case 是 PASS / FAIL。

**[English](../../../script/test/README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**

## 用法

```bash
# 完整 matrix(~6-10 min)
./isaac_ws/src/script/test/standalone_smoke.sh

# 单一 case(改 script 时快速 iterate)
./isaac_ws/src/script/test/standalone_smoke.sh --only cmd_vel

# CI / strict 模式:SKIP 视为 FAIL
./isaac_ws/src/script/test/standalone_smoke.sh --strict
```

前置条件:

- `./run.sh -t standalone -d` 跑得起来(container 没起时 smoke 会自动带起)
- OpenBase 相关 case:USD 必须存在于 `isaac_ws/src/OpenBase/openbase_free.usda`,透过以下产生:

  ```bash
  cd isaac_ws/src/docker
  ./exec.sh -t standalone /isaac-sim/python.sh \
      /home/yunchien/work/src/script/import_urdf.py \
      /home/yunchien/work/src/OpenBase/ROS/open_base/urdf/description.urdf \
      /home/yunchien/work/src/OpenBase/openbase_free.usda
  ```

  没 USD 的话 OpenBase case 会 SKIP(`--strict` 下会 FAIL)。

## Cases

| Script | Marker phrase | Timeout | USD? |
|--------|---------------|--------:|:----:|
| `ros2_test_pub_standalone.py` | `standalone publishing` | 150s | no |
| `ros2_test_sub_standalone.py` | `standalone subscribed to` | 150s | no |
| `cmd_vel_planar_standalone.py` | `standalone subscribed` | 180s | yes |
| `move_openbase_planar_standalone.py` | `[tick` | 180s | yes |

Marker 用 regex 比对在收到的 stdout+stderr 串上。每支 standalone script 都会在核心 setup 完成(rclpy subscriber 活、或第一次 `[tick]`)时恰好打印一次该 tag 行。

## Exit codes

| Code | 意义 |
|-----:|------|
| 0 | 全部 PASS(SKIP 容许,除非 `--strict`)|
| 1 | 至少 1 个 FAIL |
| 2 | Pre-flight 失败(docker dir 不在 / standalone container 起不来)|

## 失败除错

FAIL 时 runner 会把该 script 的 stdout+stderr 最后 20 行打印到 stderr。常见模式:

- `ModuleNotFoundError: No module named 'rclpy'` — `enable_extension("isaacsim.ros2.bridge")` 没调用,或在 `import rclpy` 之后才调用
- `AttributeError: 'NoneType' object has no attribute 'GetPrimAtPath'` — `ctx.open_stage()` 返回了,但 OPENED-spin loop 没等到 stage 填好
- `Failed to open: <USD path>` — USD 不在或不可读;检查 host-side 路径
- 跑到 timeout 都没看到 marker — kit 起来但 script 主 loop 没走到 print;检查 marker 行以上是否有 exception

## 为什么用 integration 不用 unit

Standalone scripts 会起 kit + livestream + rclpy subscriber。纯 Python unit test 无法取代「script 真的有走到 ROS subscriber loop,USD 载入完,bridge alive」这件事。Marker 字串就是契约 — script 打印得出来,等于 SimulationApp init、ROS 2 bridge extension load、rclpy import、node 建立、USD load + OPENED transition 全成立。

## 为什么放这个目录,不放 isaac_ws/src/docker/test/

`isaac_ws/src/docker/test/` 属于 docker repo(`ycpss91255-docker/isaac`),测的是 container image / wrapper,不是跑在 container 内的 script。Standalone scripts 住在 `isaac_ws/src/script/`(本 repo `ycpss91255/isaac`);smoke 跟着它们放一起,搬家也跟着走。
