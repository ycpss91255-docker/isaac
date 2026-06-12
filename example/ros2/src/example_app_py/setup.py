# Copyright 2026 cyc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Package setup for the example_app_py ament_python template."""

from setuptools import find_packages, setup

package_name = "example_app_py"

setup(
    name=package_name,
    version="0.1.0",
    packages=find_packages(exclude=["test"]),
    data_files=[
        (
            "share/ament_index/resource_index/packages",
            ["resource/" + package_name],
        ),
        ("share/" + package_name, ["package.xml"]),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="cyc",
    maintainer_email="ycpss91255@gmail.com",
    description=(
        "App-side ament_python template for the base-repo ROS 2 example: a "
        "camera subscriber and a /cmd_vel publisher."
    ),
    license="Apache-2.0",
    tests_require=["pytest"],
    entry_points={
        "console_scripts": [
            "camera_subscriber = example_app_py.camera_subscriber:main",
            "cmd_vel_publisher = example_app_py.cmd_vel_publisher:main",
        ],
    },
)
