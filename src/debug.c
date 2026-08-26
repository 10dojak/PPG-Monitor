#include <zephyr/drivers/i2c.h>

#define LSM6DSO_WHO_AM_I_REG 0x0F

static void debug_imu_i2c(void)
{
    const struct device *i2c_dev =
        DEVICE_DT_GET(DT_NODELABEL(i2c0));

    uint8_t whoami = 0;
    int err;

    if (!device_is_ready(i2c_dev)) {
        LOG_ERR("I2C0 controller itself is not ready");
        return;
    }

    LOG_INF("I2C0 controller ready");

    /* Try address 0x6A */
    err = i2c_reg_read_byte(
        i2c_dev,
        0x6A,
        LSM6DSO_WHO_AM_I_REG,
        &whoami
    );

    if (err == 0) {
        LOG_INF("Device found at 0x6A, WHO_AM_I = 0x%02X", whoami);
    } else {
        LOG_ERR("No response at 0x6A (err %d)", err);
    }

    /* Try address 0x6B */
    whoami = 0;

    err = i2c_reg_read_byte(
        i2c_dev,
        0x6B,
        LSM6DSO_WHO_AM_I_REG,
        &whoami
    );

    if (err == 0) {
        LOG_INF("Device found at 0x6B, WHO_AM_I = 0x%02X", whoami);
    } else {
        LOG_ERR("No response at 0x6B (err %d)", err);
    }
}