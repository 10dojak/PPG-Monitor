#!/bin/sh
# Verified 23 Sep 2026. NCS v3.2.4 — not 2.9.x, despite the old README.
export PATH="/opt/nordic/ncs/toolchains/185bb0e3b6/bin:$PATH"
export ZEPHYR_BASE="/opt/nordic/ncs/v3.2.4/zephyr"
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export ZEPHYR_SDK_INSTALL_DIR="/opt/nordic/ncs/toolchains/185bb0e3b6/opt/zephyr-sdk"
west -z "$ZEPHYR_BASE" "$@"
