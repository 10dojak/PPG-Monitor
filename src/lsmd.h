#ifndef LSMD_H_
#define LSMD_H_

#include <stdbool.h>
#include <stdint.h>

#include <zephyr/drivers/sensor.h>

// this header file defines the interface for interacting with the LSM6DSOTR IMU sensor, 
// including data structures for accelerometer samples and function prototypes for 
// initializing the sensor, checking its readiness, reading raw acceleration data, 
// and converting that data into a specific format (cm/s²) for further processing or transmission.

struct lsmd_accel_sample {
	struct sensor_value x;
	struct sensor_value y;
	struct sensor_value z;
};

struct lsmd_accel_cm_s2 {
	int32_t x;
	int32_t y;
	int32_t z;
};

struct lsmd_gyro_sample {
	struct sensor_value x;
	struct sensor_value y;
	struct sensor_value z;
};

struct lsmd_gyro_mrad_s {
	int32_t x;
	int32_t y;
	int32_t z;
};

/* this struct stores information about a wake-up event detected by the LSM6DSOTR IMU. 
 * It contains a boolean flag indicating whether a wake-up event is currently active, 
 * as well as three boolean flags indicating which axes (X, Y, Z) triggered the wake-up event. 
 * This struct is used to communicate wake-up events from the IMU to the application layer. */
struct lsmd_wakeup_event {
	bool active;
	bool x;
	bool y;
	bool z;
};


int lsmd_init(void);
bool lsmd_is_ready(void);
int lsmd_read_accel_gyro(struct lsmd_accel_sample *accel,
			 struct lsmd_gyro_sample *gyro);
int lsmd_read_accel(struct lsmd_accel_sample *sample);// function to read the raw acceleration data from the LSM6DSOTR IMU and populate the lsmd_accel_sample struct with the values
int lsmd_read_accel_cm_s2(struct lsmd_accel_cm_s2 *sample);// function to read the acceleration data from the LSM6DSOTR IMU and populate the lsmd_accel_cm_s2 struct with the values in cm/s²
void lsmd_accel_to_cm_s2(const struct lsmd_accel_sample *raw,
				 struct lsmd_accel_cm_s2 *sample);// function to convert the raw acceleration data from the lsmd_accel_sample struct to the lsmd_accel_cm_s2 struct in cm/s²
int lsmd_read_gyro(struct lsmd_gyro_sample *sample);
int lsmd_read_gyro_mrad_s(struct lsmd_gyro_mrad_s *sample);
void lsmd_gyro_to_mrad_s(const struct lsmd_gyro_sample *raw,
			 struct lsmd_gyro_mrad_s *sample);
int lsmd_poll_wakeup_event(struct lsmd_wakeup_event *event);

#endif /* LSMD_H_ */
