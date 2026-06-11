# Cross-subnet ROS 2 RGB-D Viewing via Fast DDS TCP Transport

Viewing the sim D455 RGB-D topics from a remote workstation (`nb`, `10.2.32.57`) on a **different subnet** than the Isaac server (`10.2.23.83`) failed for the large image topics with the default ROS 2 transport. The failure chain, established by direct measurement:

- **Discovery**: default DDS uses multicast SPDP (`239.255.0.1:7400`), which does not route across subnets. Unicast `initialPeersList` pointed at the server fixes discovery.
- **Large data**: a raw image (1280x800 rgb8 ≈ 3 MB) fragments into ~2000 UDP datagrams; across the subnet boundary, losing any one fragment drops the whole frame. Measured: `camera_info` (single packet) arrived reliably at ~50 Hz, while `image_raw` arrived intermittently (~30 Hz once, 0 Hz other times). This is marginal UDP fragmentation / MTU loss, not a firewall (nb `ufw` was inactive).
- **rviz QoS**: the rviz Image display defaults to `Reliable`, which cannot match the camera's `Best Effort` publisher → "No Image" even when data is available.
- **Depth display**: Isaac depth is `32FC1` with ~52% of pixels `inf` (open space, no surface); rviz `Normalize Range` computes `max = inf` → everything maps to ~0 → all black.

**Decision**: For cross-subnet remote viewing of large image topics, use **Fast DDS TCP transport** — a TCP listener on the Isaac (publisher) side and a TCP client connector on the viewer side — instead of UDP. View with `Best Effort` QoS; for depth, turn `Normalize Range` off with fixed `Min=0 / Max=8`. This is a **development / debug-only** path: the downstream perception product returns compact RLE masks, not raw images, so raw-image cross-network streaming is never on the product data path.

## Considered Options

- **(a) UDP unicast `initialPeersList`** — fixes discovery across subnets, but large image fragments drop unreliably. Small topics work; images do not. Insufficient on its own.
- **(b) Fast DDS TCP transport** (**chosen**) — TCP is reliable and self-fragments/reassembles, so no whole-frame loss. Bandwidth-bound: raw 3 MB x 30 Hz = 90 MB/s exceeds the ~11 MB/s (~100 Mbit) cross-subnet link, so it throttles to ~3.8 Hz — choppy but lossless and live.
- **(c) VPN / overlay** (Tailscale / ZeroTier / WireGuard) — flattens both hosts onto one virtual segment so default DDS multicast revives; large UDP may still fragment depending on tunnel MTU. Best when many topics must cross or hosts are at different sites.
- **(d) rmw_zenoh / `zenoh-bridge-dds`** — purpose-built for WAN / NAT routing over TCP; heavier change (swap rmw). Right answer for multi-robot / cross-site, overkill for one viewer.
- **(e) `foxglove_bridge`** — ROS 2 to WebSocket (TCP); excellent for remote monitoring, but a viewer bridge, not general node-to-node transport.
- **(f) rosbag** — record on the server, copy the file, replay locally. Reliable but offline, not live.
- **(g) compressed `image_transport`** — republish JPEG (~100 KB/frame); 30 Hz x 100 KB = 3 MB/s fits the link easily → smooth. Orthogonal: layers on top of either UDP or TCP. The correct answer for *smooth* remote raw-image viewing.

## Why (b)

TCP keeps the standard ROS 2 / rviz workflow (no extra apps, no browser, no rmw swap), reliably delivers large data across the subnet today, and has minimal moving parts: two XML profiles plus one environment variable. Bandwidth-bound fps is acceptable for a development peek. Smooth viewing is deferred to compressed transport (g), which is only worth building if remote raw-image viewing becomes routine — and it should not, per the boundary below.

## Consequences

- Two profiles land with this ADR: `config/ros2/fastdds_tcp_server.xml` (listener, port 42100) and `config/ros2/fastdds_tcp_client.xml` (connector → `10.2.23.83:42100`). The driver is launched with `FASTRTPS_DEFAULT_PROFILES_FILE` pointing at the server profile.
- The driver becomes **TCP-only** (`useBuiltinTransports=false`): same-host UDP siblings can no longer discover it. Same-host tooling must use the TCP profile too, or run as a separate UDP session.
- `config/rviz/coresam_d455.rviz` pins `Best Effort` on both Image displays and `Normalize Range` off / `Min=0` / `Max=8` on depth. `script/view_isaac_camera.sh` wraps the client side (writes the client profile, loads the rviz config).
- **Architectural boundary reaffirmed**: raw-image streaming across the network is dev-only. The downstream perception product's output is a compact RLE mask, kept on the wire small by design. Do not architect the product around cross-network raw-image transport.
- Depth carries ~50% `inf` (open space); downstream `mask x depth -> 3D` must filter `inf`/`0`. D455 depth fidelity (clip to ~0.4-6 m, out-of-range -> 0 not inf) is tracked separately.

## References

- `ros2_cross_network.md` — full debug log + both-side code snippets (kept on the dev workstation).
- Workspace harness CLAUDE.md — the perception product returns RLE masks, not raw images.
- [Fast DDS transports (UDP/TCP/SHM)](https://fast-dds.docs.eprosima.com/en/latest/fastdds/transport/transport.html)
- ADR-0006 (per-sensor-type camera config; superseded by ADR-0017), ADR-0014 (sim-runtime stage taxonomy).

## Editorial note (2026-06-11)

Incidental application-specific prose in this ADR was replaced with generic wording as part of the base-repo convergence (ADR-0017, #128). Decision content is unchanged; the original wording is preserved in git history. Literal committed artifact paths (e.g. `config/rviz/coresam_d455.rviz`) are left untouched until the content migration (#136 / #137).
