#!/usr/bin/env bash
# view_isaac_bag.sh — play a recorded Isaac camera rosbag LOCALLY and view it
# in rviz2. No cross-host DDS: the bag is replayed on this machine's own DDS,
# so there is no large-UDP-fragment-over-a-router problem (the reason live
# cross-subnet streaming failed). Record side: see the server.
#
# Usage:
#   ./view_isaac_bag.sh [BAG_DIR]
#     BAG_DIR   rosbag2 directory (default: $HOME/isaac_cam_bag/cam)
#
# In rviz2: Add -> Image -> Topic /forklift/camera/color/image_raw, and set
# the Image display's Reliability Policy to "Best Effort".
set -euo pipefail

BAG="${1:-$HOME/isaac_cam_bag/cam}"
IMAGE="${IMAGE:-osrf/ros:humble-desktop}"

[ -d "${BAG}" ] || { echo "[bag] not a directory: ${BAG}"; exit 1; }
BAG_ABS="$(readlink -f "${BAG}")"

xhost +local: >/dev/null 2>&1 || echo "[bag] warning: xhost failed (no X server?)"

echo "[bag] playing ${BAG_ABS} (looped) + launching rviz2"
exec docker run --rm -it --net=host \
  -e ROS_DOMAIN_ID=0 -e RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
  -e DISPLAY="${DISPLAY:-:0}" -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "${BAG_ABS}:/bag:ro" \
  "${IMAGE}" \
  bash -c 'source /opt/ros/humble/setup.bash; ros2 bag play --loop /bag & rviz2'
