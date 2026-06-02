#!/usr/bin/env bash
# view_isaac_camera.sh — live-view Isaac forklift D455 RGB-D topics from a
# remote PC over a Fast DDS TCP transport.
#
# Why TCP: across the subnet, large raw images (3MB) fragment into ~2000 UDP
# packets and lose whole frames (one dropped fragment = dropped frame), so
# plain UDP DDS delivered image_raw only intermittently. TCP is reliable (no
# fragment loss) so frames arrive consistently. The server runs a TCP DDS
# listener on 42100 (fastdds_tcp_server.xml); this client connects to it.
#
# Note: raw image over TCP is bandwidth-bound (~3-4 Hz here, the cross-subnet
# link caps throughput). For smooth fps use compressed image transport.
#
# Loads coresam_d455.rviz so color + depth show immediately (both Best Effort;
# depth has Normalize Range off, Min=0/Max=8 because Isaac depth is 32FC1 with
# ~half the pixels = inf for open space, which breaks auto-normalize).
#
# Usage:   ./view_isaac_camera.sh [SERVER_IP] [TCP_PORT]
#   SERVER_IP   Isaac server IP (default 10.2.23.83)
#   TCP_PORT    server DDS TCP listening port (default 42100)
# Env:  RVIZ_CFG=<path>  IMAGE=<image>
set -euo pipefail

SERVER_IP="${1:-10.2.23.83}"
TCP_PORT="${2:-42100}"
IMAGE="${IMAGE:-osrf/ros:humble-desktop}"
RVIZ_CFG="${RVIZ_CFG:-$HOME/coresam_d455.rviz}"
PROFILE="/tmp/fastdds_tcp_client.xml"

echo "[view] TCP DDS -> ${SERVER_IP}:${TCP_PORT}  rviz_cfg=${RVIZ_CFG}"
xhost +local: >/dev/null 2>&1 || echo "[view] warning: xhost failed (no X server?)"

# Fast DDS TCPv4 client profile (connects to the server's TCP listener).
cat > "${PROFILE}" <<XML
<?xml version="1.0" encoding="UTF-8" ?>
<profiles xmlns="http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles">
  <transport_descriptors>
    <transport_descriptor>
      <transport_id>tcp_client</transport_id>
      <type>TCPv4</type>
      <calculate_crc>false</calculate_crc>
      <check_crc>false</check_crc>
      <enable_tcp_nodelay>true</enable_tcp_nodelay>
    </transport_descriptor>
  </transport_descriptors>
  <participant profile_name="default_xml_profile" is_default_profile="true">
    <rtps>
      <userTransports><transport_id>tcp_client</transport_id></userTransports>
      <useBuiltinTransports>false</useBuiltinTransports>
      <builtin>
        <initialPeersList>
          <locator><tcpv4>
            <address>${SERVER_IP}</address>
            <physical_port>${TCP_PORT}</physical_port>
          </tcpv4></locator>
        </initialPeersList>
      </builtin>
    </rtps>
  </participant>
</profiles>
XML

cfg_mount=()
launch="rviz2"
if [[ -f "${RVIZ_CFG}" ]]; then
  cfg_mount=(-v "$(readlink -f "${RVIZ_CFG}"):/cfg.rviz:ro")
  launch="rviz2 -d /cfg.rviz"
else
  echo "[view] ${RVIZ_CFG} not found -> plain rviz2 (Add Image, set Best Effort)"
fi

exec docker run --rm -it --net=host \
  -e ROS_DOMAIN_ID=0 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -v "${PROFILE}:/fastdds.xml:ro" -e FASTRTPS_DEFAULT_PROFILES_FILE=/fastdds.xml \
  -e DISPLAY="${DISPLAY:-:0}" -v /tmp/.X11-unix:/tmp/.X11-unix \
  "${cfg_mount[@]}" \
  "${IMAGE}" \
  bash -lc "source /opt/ros/humble/setup.bash; echo '--- topics (TCP discovery ~5-10s) ---'; sleep 6; ros2 topic list; echo '--- rviz2 ---'; ${launch}"
