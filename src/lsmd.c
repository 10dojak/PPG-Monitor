#include "lsmd.h"

#include <errno.h>

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/logging/log.h>

LOG_MODULE_DECLARE(peripheral_uart, LOG_LEVEL_INF);

// The LSM6DSOTR IMU is on the I2C bus, and its address is determined by the SA0 pin. 
// The Zephyr device tree node for the sensor is labeled "lsm6dsotr", and we use that to get the device instance. 
// wonder if we could use the alias instead????
#define LSMD_NODE DT_NODELABEL(lsm6dsotr)

#define LSMD_TAP_CFG0_REG        0x56 // The TAP_CFG0 register is used to configure the tap detection and wake-up features of the LSM6DSOTR IMU. In this code, we are particularly interested in enabling the wake-up detection feature by setting the appropriate bits in this register.
#define LSMD_TAP_CFG2_REG        0x58 // The TAP_CFG2 register is used to configure the tap detection and wake-up features of the LSM6DSOTR IMU. In this code, we are particularly interested in enabling the wake-up detection feature by setting the appropriate bits in this register.
#define LSMD_WAKE_UP_SRC_REG     0x1B // The WAKE_UP_SRC register is used to indicate the source of the wake-up event.
#define LSMD_WAKE_UP_THS_REG     0x5B // The WAKE_UP_THS register is used to set the threshold for wake-up detection.
#define LSMD_WAKE_UP_DUR_REG     0x5C // The WAKE_UP_DUR register is used to set the duration for wake-up detection.
#define LSMD_MD1_CFG_REG         0x5E // The MD1_CFG register is used to configure the interrupt lines.

#define LSMD_WAKE_INT_ENABLE_BIT BIT(7) // The LSMD_WAKE_INT_ENABLE_BIT is used to enable the wake-up interrupt in the TAP_CFG2 register. When this bit is set, the IMU will generate an interrupt when a wake-up event is detected.
#define LSMD_WAKE_SLOPE_FDS_BIT  BIT(4) // The LSMD_WAKE_SLOPE_FDS_BIT is used to configure the slope filter for wake-up detection. This bit is set in the TAP_CFG0 register to enable the slope filter, which helps to reduce false wake-up events caused by noise or small movements.
#define LSMD_WAKE_ROUTE_INT1_BIT BIT(5) // The LSMD_WAKE_ROUTE_INT1_BIT is used to route the wake-up interrupt to INT1.

#define LSMD_WAKE_THRESHOLD_VAL  0x02 // The LSMD_WAKE_THRESHOLD_VAL is used to set the threshold for wake-up detection.
#define LSMD_WAKE_DURATION_VAL   BIT(5) // The LSMD_WAKE_DURATION_VAL is used to set the duration for wake-up detection.

/* Board-specific SA0(P0.22) control. Driving this LOW forces the IMU onto I2C address 0x6A
 * must happen before we ask Zephyr for the sensor device instance. */
static const struct gpio_dt_spec imu_sa0 =
	GPIO_DT_SPEC_GET(DT_NODELABEL(imu_sa0), gpios);
static const struct i2c_dt_spec imu_i2c = I2C_DT_SPEC_GET(LSMD_NODE);

// The Zephyr device instance for the LSM6DSOTR IMU. This is NULL until lsmd_init() is called and succeeds. */	
static const struct device *lsmd_dev;

static bool wakeup_latched;// This boolean variable is used to track whether a wake-up event has been latched. It is set to true when a wake-up event is detected and remains true until the event is cleared. This prevents multiple wake-up events from being reported for the same motion burst.

/* Convert Zephyr's fixed-point sensor_value into integer cm/s^2 so the BLE transport
 * can reuse the existing unsigned integer packet format. */
static int32_t sensor_value_to_cm_s2(const struct sensor_value *value)
{
	return value->val1 * 100 + value->val2 / 10000;
}

/* Zephyr reports gyroscope channels in rad/s. Convert that fixed-point form into
 * integer mrad/s so we can stream it over BLE without floating-point formatting. */
static int32_t sensor_value_to_mrad_s(const struct sensor_value *value)
{
	return value->val1 * 1000 + value->val2 / 1000;
}

/* Convert one fetched accel sample from Zephyr sensor_value triples into the integer
 * representation used by the application layer. */
void lsmd_accel_to_cm_s2(const struct lsmd_accel_sample *raw,
			 struct lsmd_accel_cm_s2 *sample)
{
	if (raw == NULL || sample == NULL) {
		return;
	}

	sample->x = sensor_value_to_cm_s2(&raw->x);
	sample->y = sensor_value_to_cm_s2(&raw->y);
	sample->z = sensor_value_to_cm_s2(&raw->z);
}

void lsmd_gyro_to_mrad_s(const struct lsmd_gyro_sample *raw,
			 struct lsmd_gyro_mrad_s *sample)
{
	if (raw == NULL || sample == NULL) {
		return;
	}

	sample->x = sensor_value_to_mrad_s(&raw->x);
	sample->y = sensor_value_to_mrad_s(&raw->y);
	sample->z = sensor_value_to_mrad_s(&raw->z);
}

// Return true if the IMU device instance is valid and ready to be used. 
// This is a simple check to see if lsmd_init() has been called and succeeded.
bool lsmd_is_ready(void)
{
	return lsmd_dev != NULL;
}

/* Wake-up detection uses direct register writes because the Zephyr LSM6DSO
 * wrapper does not expose a dedicated wake-up trigger API. We enable the
 * interrupt engine, select the slope filter, apply a modest threshold, and
 * route the wake-up event to INT1 even though we currently poll the status
 * register in firmware instead of attaching a GPIO interrupt handler. */
static int lsmd_enable_wakeup_detect(void)
{
	int err;

	err = i2c_reg_update_byte_dt(&imu_i2c, LSMD_TAP_CFG0_REG,
				      LSMD_WAKE_SLOPE_FDS_BIT,
				      LSMD_WAKE_SLOPE_FDS_BIT);
	if (err) {
		return err;
	}

	err = i2c_reg_update_byte_dt(&imu_i2c, LSMD_TAP_CFG2_REG,
				      LSMD_WAKE_INT_ENABLE_BIT,
				      LSMD_WAKE_INT_ENABLE_BIT);
	if (err) {
		return err;
	}

	err = i2c_reg_write_byte_dt(&imu_i2c, LSMD_WAKE_UP_THS_REG,
				     LSMD_WAKE_THRESHOLD_VAL);
	if (err) {
		return err;
	}

	err = i2c_reg_write_byte_dt(&imu_i2c, LSMD_WAKE_UP_DUR_REG,
				     LSMD_WAKE_DURATION_VAL);
	if (err) {
		return err;
	}

	return i2c_reg_update_byte_dt(&imu_i2c, LSMD_MD1_CFG_REG,
				       LSMD_WAKE_ROUTE_INT1_BIT,
				       LSMD_WAKE_ROUTE_INT1_BIT);
}

/* Bring up the IMU path for this board:
 * 1. Force SA0 low so the device responds at 0x6A.
 * 2. Resolve the devicetree sensor instance.
 * 3. Verify Zephyr successfully initialized the sensor driver. */
int lsmd_init(void)
{
	int err;

	err = gpio_pin_configure_dt(&imu_sa0, GPIO_OUTPUT_LOW); // Drive SA0 low to select I2C address 0x6A
	if (err) {
		LOG_ERR("Failed to drive IMU SA0 low (err %d)", err);
		lsmd_dev = NULL;
		return err;
	}

	lsmd_dev = DEVICE_DT_GET(LSMD_NODE);// Get the device instance for the LSM6DSOTR IMU from the device tree using the node label "lsm6dsotr"
	// Check if the device instance is ready. If not, log an error and return -ENODEV.
	if (!device_is_ready(lsmd_dev)) {
		LOG_ERR("LSM6DSOTR not ready -- check I2C (SCL=P0.24 SDA=P0.16 addr=0x6A)");
		lsmd_dev = NULL;
		return -ENODEV;
	}

	err = lsmd_enable_wakeup_detect();
	if (err) {
		LOG_ERR("LSM6DSOTR wake-up config failed (err %d)", err);
		lsmd_dev = NULL;
		return err;
	}

	wakeup_latched = false;
	LOG_INF("LSM6DSOTR ready -- accel ±2g @ 26 Hz, gyro active, wake-up detect enabled");
	return 0;
}

/* Internal helper that fetches one fresh IMU sample, then optionally copies the
 * accel and gyro channels requested by the caller. This keeps accel+gyro reads
 * synchronized and avoids fetching the sensor twice in the main loop. */
static int lsmd_read_channels(struct lsmd_accel_sample *accel,
			      struct lsmd_gyro_sample *gyro)
{
	int err;

	if (accel == NULL && gyro == NULL) {
		return -EINVAL;
	}

	if (lsmd_dev == NULL) {
		return -ENODEV;
	}
	// Fetch one new sample from the sensor. This updates the internal state of the sensor driver with the latest readings.
	err = sensor_sample_fetch(lsmd_dev);
	if (err) {
		return err;
	}
	// If the caller requested accel data, read the X, Y, and Z channels into the provided struct.
	if (accel != NULL) {
		err = sensor_channel_get(lsmd_dev, SENSOR_CHAN_ACCEL_X, &accel->x);
		if (err) {
			return err;
		}

		err = sensor_channel_get(lsmd_dev, SENSOR_CHAN_ACCEL_Y, &accel->y);
		if (err) {
			return err;
		}

		err = sensor_channel_get(lsmd_dev, SENSOR_CHAN_ACCEL_Z, &accel->z);
		if (err) {
			return err;
		}
	}
	// If the caller requested gyro data, read the X, Y, and Z channels into the provided struct.
	if (gyro != NULL) {
		err = sensor_channel_get(lsmd_dev, SENSOR_CHAN_GYRO_X, &gyro->x);
		if (err) {
			return err;
		}

		err = sensor_channel_get(lsmd_dev, SENSOR_CHAN_GYRO_Y, &gyro->y);
		if (err) {
			return err;
		}

		err = sensor_channel_get(lsmd_dev, SENSOR_CHAN_GYRO_Z, &gyro->z);
		if (err) {
			return err;
		}
	}

	return 0;
}
// Fetch one new accel+gyro sample from the sensor and read X/Y/Z into two separate structs.
int lsmd_read_accel_gyro(struct lsmd_accel_sample *accel,
			 struct lsmd_gyro_sample *gyro)
{
	return lsmd_read_channels(accel, gyro);
}

/* Fetch one new accel sample from the sensor and read X/Y/Z into a single struct.
 */
int lsmd_read_accel(struct lsmd_accel_sample *sample)
{
	if (sample == NULL) {
		return -EINVAL;
	}

	return lsmd_read_channels(sample, NULL);
}

/* Convenience wrapper for callers that only care about the integer transport format.
 * It reuses lsmd_read_accel() so there is one place responsible for sensor reads. */
int lsmd_read_accel_cm_s2(struct lsmd_accel_cm_s2 *sample)
{
	int err;
	struct lsmd_accel_sample raw;

	if (sample == NULL) {
		return -EINVAL;
	}

	err = lsmd_read_accel(&raw);
	if (err) {
		return err;
	}

	lsmd_accel_to_cm_s2(&raw, sample);

	return 0;
}
// Fetch one new gyro sample from the sensor and read X/Y/Z into a single struct.
int lsmd_read_gyro(struct lsmd_gyro_sample *sample)
{
	if (sample == NULL) {
		return -EINVAL;
	}

	return lsmd_read_channels(NULL, sample);
}
// Convenience wrapper for callers that only care about the integer transport format.
int lsmd_read_gyro_mrad_s(struct lsmd_gyro_mrad_s *sample)
{
	int err;
	struct lsmd_gyro_sample raw;

	if (sample == NULL) {
		return -EINVAL;
	}

	err = lsmd_read_gyro(&raw);
	if (err) {
		return err;
	}

	lsmd_gyro_to_mrad_s(&raw, sample);

	return 0;
}

/* WAKE_UP_SRC exposes both the event flag and which axes crossed the threshold.
 * We return only the rising edge of wu_ia so the app sees one wake-up event per
 * motion burst instead of logging/transmitting the same event every loop. */
int lsmd_poll_wakeup_event(struct lsmd_wakeup_event *event)
{
	int err;
	uint8_t src;// 8 bit variable to hold the value read from the WAKE_UP_SRC register of the LSM6DSOTR IMU. This register contains information about the wake-up event, including which axes triggered the event and whether a wake-up event is currently active.
	bool active;

	if (event == NULL) {// Check if the event pointer is NULL. If it is, return -EINVAL to indicate an invalid argument.
		return -EINVAL;
	}

	if (lsmd_dev == NULL) {
		return -ENODEV;
	}

	// Read the WAKE_UP_SRC register from the IMU over I2C. This register contains information about the wake-up event, including which axes triggered the event.
	// the i2c_reg_read_byte_dt() function reads a single byte from the specified register of the I2C device. If the read operation fails, it returns an error code.
	// the function is defined in the Zephyr I2C driver API and is used to communicate with I2C devices in a convenient way.
	// If the read operation is successful, the value of the WAKE_UP_SRC register is stored in the variable src.
	err = i2c_reg_read_byte_dt(&imu_i2c, LSMD_WAKE_UP_SRC_REG, &src);
	if (err) {
		return err;
	}

	active = (src & BIT(3)) != 0;// Check if the wake-up event is active by examining the 4th bit (BIT(3))-WU_IA- of the src variable. If this bit is set, it indicates that a wake-up event has occurred.
	
	// return true only on the rising edge of the wake-up event, so we don't report the same event multiple times during a single motion burst.
	event->active = active && !wakeup_latched;
	
	event->x = (src & BIT(2)) != 0;// Check if the X-axis triggered the wake-up event by examining the 3rd bit (BIT(2)) of the src variable. If this bit is set, it indicates that the X-axis crossed the threshold for wake-up detection.
	event->y = (src & BIT(1)) != 0;// Check if the Y-axis triggered the wake-up event by examining the 2nd bit (BIT(1)) of the src variable. If this bit is set, it indicates that the Y-axis crossed the threshold for wake-up detection.
	event->z = (src & BIT(0)) != 0;// Check if the Z-axis triggered the wake-up event by examining the 1st bit (BIT(0)) of the src variable. If this bit is set, it indicates that the Z-axis crossed the threshold for wake-up detection.

	wakeup_latched = active;// Update the wakeup_latched variable to reflect the current state of the wake-up event. If a wake-up event is active, this variable is set to true, preventing multiple wake-up events from being reported for the same motion burst.
	return 0;
}
