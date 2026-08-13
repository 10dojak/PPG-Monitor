/*
 * Copyright (c) 2018 Nordic Semiconductor ASA
 *
 * SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
 */

/** @file
 *  @brief Nordic UART Bridge Service (NUS) sample
 */

/*
 * Updated July 2026 — Rutendo Jakachira (rutendo_jakachira@brown.edu):
 * - Added al_transmit_data(): streams MAX86141 FIFO samples over BLE NUS          [Rutendo Jakachira, rutendo_jakachira@brown.edu]
 *     Format: "tag value slotIdx\r\n"
 *     tag     = MAX86141 FIFO tag bits [23:19] (identifies LED+PD combination)
 *     value   = 19-bit ADC optical count
 *     slotIdx = batch position (0-11 = U10, 128-139 = U2)
 * - Added al_transmit_accel(): streams LSM6DSOTR IMU data over BLE NUS            [Rutendo Jakachira, rutendo_jakachira@brown.edu]
 *     Format: "0 encoded_value slotIdx\r\n"
 *     slotIdx = 200 (X), 201 (Y), 202 (Z)
 *     encoded = accel_cm_s2 + 20000 (offset to keep unsigned)
 * - Main loop transmits last 12 U10 + last 12 U2 samples per 200ms cycle          [Rutendo Jakachira, rutendo_jakachira@brown.edu]
 * - IMU polled at ~26 Hz, transmitted once per 200ms loop                         [Rutendo Jakachira, rutendo_jakachira@brown.edu]
 */
#include <uart_async_adapter.h>

#include <zephyr/types.h>
#include <zephyr/kernel.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/usb/usb_device.h>

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <soc.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/hci.h>

#include <bluetooth/services/nus.h>

#include <dk_buttons_and_leds.h>

#include <zephyr/settings/settings.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zephyr/logging/log.h>

#include "lsmd.h"
#include "max86140_spi.h"

#define LOG_MODULE_NAME peripheral_uart
LOG_MODULE_REGISTER(LOG_MODULE_NAME);

#define STACKSIZE CONFIG_BT_NUS_THREAD_STACK_SIZE
#define PRIORITY 7

#define DEVICE_NAME CONFIG_BT_DEVICE_NAME
#define DEVICE_NAME_LEN	(sizeof(DEVICE_NAME) - 1)

#define RUN_STATUS_LED DK_LED1
#define RUN_LED_BLINK_INTERVAL 50

#define CON_STATUS_LED DK_LED2

#define KEY_PASSKEY_ACCEPT DK_BTN1_MSK
#define KEY_PASSKEY_REJECT DK_BTN2_MSK

#define UART_BUF_SIZE CONFIG_BT_NUS_UART_BUFFER_SIZE
#define UART_WAIT_FOR_BUF_DELAY K_MSEC(50)
#define UART_WAIT_FOR_RX CONFIG_BT_NUS_UART_RX_WAIT_TIME

static K_SEM_DEFINE(ble_init_ok, 0, 1);

static struct bt_conn *current_conn;
static struct bt_conn *auth_conn;
static struct k_work adv_work;

static const struct device *uart = DEVICE_DT_GET(DT_CHOSEN(nordic_nus_uart));
static struct k_work_delayable uart_work;

struct uart_data_t {
	void *fifo_reserved;
	uint8_t data[UART_BUF_SIZE];
	uint16_t len;
};

static K_FIFO_DEFINE(fifo_uart_tx_data);
static K_FIFO_DEFINE(fifo_uart_rx_data);

/* Transmit one axis of acceleration over BLE NUS.
 * slot_idx: 200=X, 201=Y, 202=Z.
 * Value is accel in cm/s² offset by +20000 to keep it unsigned:
 *   encoded = (val1*100 + val2/10000) + 20000
 * Receiver undoes: accel_cm_s2 = value - 20000  */
static void al_transmit_accel(int32_t accel_cm_s2, uint8_t slot_idx)
{
	uint32_t encoded = (uint32_t)(accel_cm_s2 + 20000);
	struct uart_data_t *buf = k_malloc(sizeof(*buf));
	if (buf) {
		buf->len = snprintf(buf->data, sizeof(buf->data),
				    "0 %u %u\r\n", encoded, (uint32_t)slot_idx);
		if (buf->len > 0 && buf->len < sizeof(buf->data)) {
			k_fifo_put(&fifo_uart_rx_data, buf);
		} else {
			k_free(buf);
		}
	}
}

/* Transmit one axis of gyro data over BLE NUS.
 * slot_idx: 210=X, 211=Y, 212=Z.
 * Value is angular rate in mrad/s offset by +50000 so negative rates fit in the
 * existing unsigned text packet format. */
static void al_transmit_gyro(int32_t gyro_mrad_s, uint8_t slot_idx)
{
	uint32_t encoded = (uint32_t)(gyro_mrad_s + 50000);
	struct uart_data_t *buf = k_malloc(sizeof(*buf));
	if (buf) {
		buf->len = snprintf(buf->data, sizeof(buf->data),
				    "0 %u %u\r\n", encoded, (uint32_t)slot_idx);
		if (buf->len > 0 && buf->len < sizeof(buf->data)) {
			k_fifo_put(&fifo_uart_rx_data, buf);
		} else {
			k_free(buf);
		}
	}
}

/* Transmit a wake-up event from the IMU.
 * slot_idx 220 identifies the wake-up channel, and the value is a 3-bit mask:
 * bit0=X, bit1=Y, bit2=Z. */
static void al_transmit_wakeup(uint8_t axis_mask)
{
	struct uart_data_t *buf = k_malloc(sizeof(*buf));
	if (buf) {
		buf->len = snprintf(buf->data, sizeof(buf->data),
				    "0 %u 220\r\n", (uint32_t)axis_mask);
		if (buf->len > 0 && buf->len < sizeof(buf->data)) {
			k_fifo_put(&fifo_uart_rx_data, buf);
		} else {
			k_free(buf);
		}
	}
}


static const struct bt_data ad[] = {
	BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
	BT_DATA(BT_DATA_NAME_COMPLETE, DEVICE_NAME, DEVICE_NAME_LEN),
};

static const struct bt_data sd[] = {
	BT_DATA_BYTES(BT_DATA_UUID128_ALL, BT_UUID_NUS_VAL),
};

#ifdef CONFIG_UART_ASYNC_ADAPTER
UART_ASYNC_ADAPTER_INST_DEFINE(async_adapter);
#else
#define async_adapter NULL
#endif

static void uart_cb(const struct device *dev, struct uart_event *evt, void *user_data)
{
	ARG_UNUSED(dev);

	static size_t aborted_len;
	struct uart_data_t *buf;
	static uint8_t *aborted_buf;
	static bool disable_req;

	switch (evt->type) {
	case UART_TX_DONE:
		LOG_DBG("UART_TX_DONE");
		if ((evt->data.tx.len == 0) ||
		    (!evt->data.tx.buf)) {
			return;
		}

		if (aborted_buf) {
			buf = CONTAINER_OF(aborted_buf, struct uart_data_t,
					   data[0]);
			aborted_buf = NULL;
			aborted_len = 0;
		} else {
			buf = CONTAINER_OF(evt->data.tx.buf, struct uart_data_t,
					   data[0]);
		}

		k_free(buf);

		buf = k_fifo_get(&fifo_uart_tx_data, K_NO_WAIT);
		if (!buf) {
			return;
		}

		if (uart_tx(uart, buf->data, buf->len, SYS_FOREVER_MS)) {
			LOG_WRN("Failed to send data over UART");
		}

		break;

	case UART_RX_RDY:
		LOG_DBG("UART_RX_RDY");
		buf = CONTAINER_OF(evt->data.rx.buf, struct uart_data_t, data[0]);
		buf->len += evt->data.rx.len;

		if (disable_req) {
			return;
		}

		if ((evt->data.rx.buf[buf->len - 1] == '\n') ||
		    (evt->data.rx.buf[buf->len - 1] == '\r')) {
			disable_req = true;
			uart_rx_disable(uart);
		}

		break;

	case UART_RX_DISABLED:
		LOG_DBG("UART_RX_DISABLED");
		disable_req = false;

		buf = k_malloc(sizeof(*buf));
		if (buf) {
			buf->len = 0;
		} else {
			LOG_WRN("Not able to allocate UART receive buffer");
			k_work_reschedule(&uart_work, UART_WAIT_FOR_BUF_DELAY);
			return;
		}

		uart_rx_enable(uart, buf->data, sizeof(buf->data),
			       UART_WAIT_FOR_RX);

		break;

	case UART_RX_BUF_REQUEST:
		LOG_DBG("UART_RX_BUF_REQUEST");
		buf = k_malloc(sizeof(*buf));
		if (buf) {
			buf->len = 0;
			uart_rx_buf_rsp(uart, buf->data, sizeof(buf->data));
		} else {
			LOG_WRN("Not able to allocate UART receive buffer");
		}

		break;

	case UART_RX_BUF_RELEASED:
		LOG_DBG("UART_RX_BUF_RELEASED");
		buf = CONTAINER_OF(evt->data.rx_buf.buf, struct uart_data_t,
				   data[0]);

		if (buf->len > 0) {
			k_fifo_put(&fifo_uart_rx_data, buf);
		} else {
			k_free(buf);
		}

		break;

	case UART_TX_ABORTED:
		LOG_DBG("UART_TX_ABORTED");
		if (!aborted_buf) {
			aborted_buf = (uint8_t *)evt->data.tx.buf;
		}

		aborted_len += evt->data.tx.len;
		buf = CONTAINER_OF((void *)aborted_buf, struct uart_data_t,
				   data);

		uart_tx(uart, &buf->data[aborted_len],
			buf->len - aborted_len, SYS_FOREVER_MS);

		break;

	default:
		break;
	}
}

static void uart_work_handler(struct k_work *item)
{
	struct uart_data_t *buf;

	buf = k_malloc(sizeof(*buf));
	if (buf) {
		buf->len = 0;
	} else {
		LOG_WRN("Not able to allocate UART receive buffer");
		k_work_reschedule(&uart_work, UART_WAIT_FOR_BUF_DELAY);
		return;
	}

	uart_rx_enable(uart, buf->data, sizeof(buf->data), UART_WAIT_FOR_RX);
}

static bool uart_test_async_api(const struct device *dev)
{
	const struct uart_driver_api *api =
			(const struct uart_driver_api *)dev->api;

	return (api->callback_set != NULL);
}

static int uart_init(void)
{
	int err;
	int pos;
	struct uart_data_t *rx;
	struct uart_data_t *tx;

	if (!device_is_ready(uart)) {
		return -ENODEV;
	}

	if (IS_ENABLED(CONFIG_USB_DEVICE_STACK)) {
		err = usb_enable(NULL);
		if (err && (err != -EALREADY)) {
			LOG_ERR("Failed to enable USB");
			return err;
		}
	}

	rx = k_malloc(sizeof(*rx));
	if (rx) {
		rx->len = 0;
	} else {
		return -ENOMEM;
	}

	k_work_init_delayable(&uart_work, uart_work_handler);


	if (IS_ENABLED(CONFIG_UART_ASYNC_ADAPTER) && !uart_test_async_api(uart)) {
		/* Implement API adapter */
		uart_async_adapter_init(async_adapter, uart);
		uart = async_adapter;
	}

	err = uart_callback_set(uart, uart_cb, NULL);
	if (err) {
		k_free(rx);
		LOG_ERR("Cannot initialize UART callback");
		return err;
	}

	if (IS_ENABLED(CONFIG_UART_LINE_CTRL)) {
		LOG_INF("Wait for DTR");
		while (true) {
			uint32_t dtr = 0;

			uart_line_ctrl_get(uart, UART_LINE_CTRL_DTR, &dtr);
			if (dtr) {
				break;
			}
			/* Give CPU resources to low priority threads. */
			k_sleep(K_MSEC(100));
		}
		LOG_INF("DTR set");
		err = uart_line_ctrl_set(uart, UART_LINE_CTRL_DCD, 1);
		if (err) {
			LOG_WRN("Failed to set DCD, ret code %d", err);
		}
		err = uart_line_ctrl_set(uart, UART_LINE_CTRL_DSR, 1);
		if (err) {
			LOG_WRN("Failed to set DSR, ret code %d", err);
		}
	}

	tx = k_malloc(sizeof(*tx));

	if (tx) {
		pos = snprintf(tx->data, sizeof(tx->data),
			       "Starting Nordic UART service sample\r\n");

		if ((pos < 0) || (pos >= sizeof(tx->data))) {
			k_free(rx);
			k_free(tx);
			LOG_ERR("snprintf returned %d", pos);
			return -ENOMEM;
		}

		tx->len = pos;
	} else {
		k_free(rx);
		return -ENOMEM;
	}

	err = uart_tx(uart, tx->data, tx->len, SYS_FOREVER_MS);
	if (err) {
		k_free(rx);
		k_free(tx);
		LOG_ERR("Cannot display welcome message (err: %d)", err);
		return err;
	}

	err = uart_rx_enable(uart, rx->data, sizeof(rx->data), UART_WAIT_FOR_RX);
	if (err) {
		LOG_ERR("Cannot enable uart reception (err: %d)", err);
		/* Free the rx buffer only because the tx buffer will be handled in the callback */
		k_free(rx);
	}

	return err;
}

static void adv_work_handler(struct k_work *work)
{
	int err = bt_le_adv_start(BT_LE_ADV_PARAM(BT_LE_ADV_OPT_CONN,
					BT_GAP_ADV_FAST_INT_MIN_2,
					BT_GAP_ADV_FAST_INT_MAX_2, NULL),
				  ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));

	if (err) {
		LOG_ERR("Advertising failed to start (err %d)", err);
		return;
	}

	LOG_INF("Advertising successfully started");
}

static void advertising_start(void)
{
	k_work_submit(&adv_work);
}

static void connected(struct bt_conn *conn, uint8_t err)
{
	char addr[BT_ADDR_LE_STR_LEN];

	if (err) {
		LOG_ERR("Connection failed, err 0x%02x %s", err, bt_hci_err_to_str(err));
		return;
	}

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));
	LOG_INF("Connected %s", addr);

	current_conn = bt_conn_ref(conn);

	dk_set_led_on(CON_STATUS_LED);
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
	char addr[BT_ADDR_LE_STR_LEN];

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

	LOG_INF("Disconnected: %s, reason 0x%02x %s", addr, reason, bt_hci_err_to_str(reason));

	if (auth_conn) {
		bt_conn_unref(auth_conn);
		auth_conn = NULL;
	}

	if (current_conn) {
		bt_conn_unref(current_conn);
		current_conn = NULL;
		dk_set_led_off(CON_STATUS_LED);
	}
}

static void recycled_cb(void)
{
	LOG_INF("Connection object available from previous conn. Disconnect is complete!");
	advertising_start();
}

#ifdef CONFIG_BT_NUS_SECURITY_ENABLED
static void security_changed(struct bt_conn *conn, bt_security_t level,
			     enum bt_security_err err)
{
	char addr[BT_ADDR_LE_STR_LEN];

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

	if (!err) {
		LOG_INF("Security changed: %s level %u", addr, level);
	} else {
		LOG_WRN("Security failed: %s level %u err %d %s", addr, level, err,
			bt_security_err_to_str(err));
	}
}
#endif

BT_CONN_CB_DEFINE(conn_callbacks) = {
	.connected        = connected,
	.disconnected     = disconnected,
	.recycled         = recycled_cb,
#ifdef CONFIG_BT_NUS_SECURITY_ENABLED
	.security_changed = security_changed,
#endif
};

#if defined(CONFIG_BT_NUS_SECURITY_ENABLED)
static void auth_passkey_display(struct bt_conn *conn, unsigned int passkey)
{
	char addr[BT_ADDR_LE_STR_LEN];

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

	LOG_INF("Passkey for %s: %06u", addr, passkey);
}

static void auth_passkey_confirm(struct bt_conn *conn, unsigned int passkey)
{
	char addr[BT_ADDR_LE_STR_LEN];

	auth_conn = bt_conn_ref(conn);

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

	LOG_INF("Passkey for %s: %06u", addr, passkey);

	if (IS_ENABLED(CONFIG_SOC_SERIES_NRF54HX) || IS_ENABLED(CONFIG_SOC_SERIES_NRF54LX)) {
		LOG_INF("Press Button 0 to confirm, Button 1 to reject.");
	} else {
		LOG_INF("Press Button 1 to confirm, Button 2 to reject.");
	}
}

static void auth_cancel(struct bt_conn *conn)
{
	char addr[BT_ADDR_LE_STR_LEN];

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

	LOG_INF("Pairing cancelled: %s", addr);
}

static void pairing_complete(struct bt_conn *conn, bool bonded)
{
	char addr[BT_ADDR_LE_STR_LEN];

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

	LOG_INF("Pairing completed: %s, bonded: %d", addr, bonded);
}

static void pairing_failed(struct bt_conn *conn, enum bt_security_err reason)
{
	char addr[BT_ADDR_LE_STR_LEN];

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, sizeof(addr));

	LOG_INF("Pairing failed conn: %s, reason %d %s", addr, reason,
		bt_security_err_to_str(reason));
}

static struct bt_conn_auth_cb conn_auth_callbacks = {
	.passkey_display = auth_passkey_display,
	.passkey_confirm = auth_passkey_confirm,
	.cancel = auth_cancel,
};

static struct bt_conn_auth_info_cb conn_auth_info_callbacks = {
	.pairing_complete = pairing_complete,
	.pairing_failed = pairing_failed
};
#else
static struct bt_conn_auth_cb conn_auth_callbacks;
static struct bt_conn_auth_info_cb conn_auth_info_callbacks;
#endif

static void bt_receive_cb(struct bt_conn *conn, const uint8_t *const data,
			  uint16_t len)
{
	int err;
	char addr[BT_ADDR_LE_STR_LEN] = {0};

	bt_addr_le_to_str(bt_conn_get_dst(conn), addr, ARRAY_SIZE(addr));

	LOG_INF("Received data from: %s", addr);

	for (uint16_t pos = 0; pos != len;) {
		struct uart_data_t *tx = k_malloc(sizeof(*tx));

		if (!tx) {
			LOG_WRN("Not able to allocate UART send data buffer");
			return;
		}

		/* Keep the last byte of TX buffer for potential LF char. */
		size_t tx_data_size = sizeof(tx->data) - 1;

		if ((len - pos) > tx_data_size) {
			tx->len = tx_data_size;
		} else {
			tx->len = (len - pos);
		}

		memcpy(tx->data, &data[pos], tx->len);

		pos += tx->len;

		/* Append the LF character when the CR character triggered
		 * transmission from the peer.
		 */
		if ((pos == len) && (data[len - 1] == '\r')) {
			tx->data[tx->len] = '\n';
			tx->len++;
		}

		err = uart_tx(uart, tx->data, tx->len, SYS_FOREVER_MS);
		if (err) {
			k_fifo_put(&fifo_uart_tx_data, tx);
		}
	}
}

static struct bt_nus_cb nus_cb = {
	.received = bt_receive_cb,
};

/* bt_ready callback not used — bt_enable(NULL) blocks until ready */

void error(void)
{
	dk_set_leds_state(DK_ALL_LEDS_MSK, DK_NO_LEDS_MSK);

	while (true) {
		/* Spin for ever */
		k_sleep(K_MSEC(1000));
	}
}

#ifdef CONFIG_BT_NUS_SECURITY_ENABLED
static void num_comp_reply(bool accept)
{
	if (accept) {
		bt_conn_auth_passkey_confirm(auth_conn);
		LOG_INF("Numeric Match, conn %p", (void *)auth_conn);
	} else {
		bt_conn_auth_cancel(auth_conn);
		LOG_INF("Numeric Reject, conn %p", (void *)auth_conn);
	}

	bt_conn_unref(auth_conn);
	auth_conn = NULL;
}

void button_changed(uint32_t button_state, uint32_t has_changed)
{
	uint32_t buttons = button_state & has_changed;

	if (auth_conn) {
		if (buttons & KEY_PASSKEY_ACCEPT) {
			num_comp_reply(true);
		}

		if (buttons & KEY_PASSKEY_REJECT) {
			num_comp_reply(false);
		}
	}
}
#endif /* CONFIG_BT_NUS_SECURITY_ENABLED */

static void configure_gpio(void)
{
	int err;

#ifdef CONFIG_BT_NUS_SECURITY_ENABLED
	err = dk_buttons_init(button_changed);
	if (err) {
		LOG_ERR("Cannot init buttons (err: %d)", err);
	}
#endif /* CONFIG_BT_NUS_SECURITY_ENABLED */

	err = dk_leds_init();
	if (err) {
		LOG_ERR("Cannot init LEDs (err: %d)", err);
	}
}

static inline uint32_t now_ms(void)
{
	return k_uptime_get_32();
}

// Transmit a single piece of numerical data over BLE UART
// 32-bit maximum
void al_transmit_data(uint32_t data, uint8_t fifo_count){
	uint8_t t = data >> 19;		 // 5-bit Tag at [23:19]
	uint32_t o = data & 0x7FFFF; // 19-bit Optical Data
	// Create and send a test message over BLE UART
	struct uart_data_t *test_buf = k_malloc(sizeof(*test_buf));
	if (test_buf) {
		test_buf->len = snprintf(test_buf->data, sizeof(test_buf->data),
									"%u %u %u\r\n", t, o, fifo_count);
		if (test_buf->len > 0 && test_buf->len < sizeof(test_buf->data)) {
			k_fifo_put(&fifo_uart_rx_data, test_buf);
		} else {
			k_free(test_buf);
		}
	}
}

int main(void)
{
	int err = 0;

	configure_gpio();

	/* uart_init() intentionally skipped — Proto2403 has no physical UART.
	 * All host communication is via BLE NUS.  The async UART driver with
	 * RTS/CTS configured on floating pins can block or corrupt boot flow. */

	err = bt_enable(NULL);
	if (err) {
		LOG_ERR("bt_enable failed (err %d)", err);
		error();
	}
	LOG_INF("Bluetooth initialized");

	err = bt_nus_init(&nus_cb);
	if (err) {
		LOG_ERR("Failed to initialize NUS (err: %d)", err);
		return 0;
	}
	LOG_INF("NUS initialized");

	/* Advertise directly — avoid workqueue indirection that can silently fail */
	err = bt_le_adv_start(BT_LE_ADV_PARAM(BT_LE_ADV_OPT_CONN,
					BT_GAP_ADV_FAST_INT_MIN_2,
					BT_GAP_ADV_FAST_INT_MAX_2, NULL),
				ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
	if (err) {
		LOG_ERR("Advertising failed to start (err %d)", err);
	} else {
		LOG_INF("Advertising started as " CONFIG_BT_DEVICE_NAME);
	}

	/* Now signal ble_write_thread that NUS is ready */
	k_sem_give(&ble_init_ok);

	/* Enable Proto2403 power rails */
	static const struct gpio_dt_spec tps = GPIO_DT_SPEC_GET(DT_NODELABEL(tps_en), gpios);
	static const struct gpio_dt_spec mcp = GPIO_DT_SPEC_GET(DT_NODELABEL(mcp_en), gpios);
	gpio_pin_configure_dt(&tps, GPIO_OUTPUT_HIGH);
	gpio_pin_configure_dt(&mcp, GPIO_OUTPUT_HIGH);
	k_sleep(K_MSEC(50));
	LOG_INF("Power rails enabled");

	/* updated by kelvin: 2026-07-14
	 * 1. LSM6DSOTR IMU initialisation(previous initialisation was her in main.c but now moved to lsmd.c)
	 * 2. MAX86141 U10 (primary) sensor initialisation
	 * 3. MAX86141 U2 (mux controller) initialisation
	 * 4. Read Part ID to confirm SPI is actually talking to the sensor
	 * 5. Log tag histogram once at startup after the first FIFO fill (~1s)
	 */
	
	// LSM6DSOTR initialisation
	err = lsmd_init();
	if (err) {
		LOG_WRN("LSM6DSOTR init failed (err %d) -- continuing without IMU", err);
	}// in case the initialisation fails, we continue without the IMU and just use the MAX86141 sensors

	max86140_spi_init();
	LOG_INF("SPI init done");
	max86140_init();
	LOG_INF("U10 (primary) sensor init done");
	max86141_u2_init();
	LOG_INF("U2 (mux controller) init done - streaming PPG Red/IR/Green");

	/* Read Part ID to confirm SPI is actually talking to the sensor */
	uint8_t part_id = max86140_read_part_id();
	LOG_INF("MAX86141 Part ID: 0x%02x (expect 0x24)", part_id);

	static uint32_t fifo_data_buf[128];   /* U10 FIFO buffer */
	static uint32_t fifo_u2_buf[128];     /* U2  FIFO buffer */
	uint32_t loop = 0;

	/* Log tag histogram once at startup after the first FIFO fill (~1s) */
	k_sleep(K_MSEC(1000));
	{
		uint8_t sc = 0, sc2 = 0;
		max86140_exhaust_fifo(fifo_data_buf, &sc);
		max86141_u2_exhaust_fifo(fifo_u2_buf, &sc2);
		LOG_INF("=== Startup tag histogram — U10 (%u samples) ===", sc);
		max86140_log_tag_histogram(fifo_data_buf, sc);
		LOG_INF("=== Startup tag histogram — U2  (%u samples) ===", sc2);
		max86140_log_tag_histogram(fifo_u2_buf, sc2);
	}

	for (;;) {
		uint8_t sample_count = 0, sample_count_u2 = 0;
		max86140_exhaust_fifo(fifo_data_buf, &sample_count);
		max86141_u2_exhaust_fifo(fifo_u2_buf, &sample_count_u2);

		/* Every 5 loops (~1s) log FIFO summary */
		if ((loop % 5) == 0) {
			LOG_INF("U10 FIFO=%u  U2 FIFO=%u  conn=%s",
				sample_count, sample_count_u2,
				(current_conn != NULL) ? "yes" : "no");
			for (uint8_t i = 0; i < sample_count && i < 12; i++) {
				uint8_t  tag = (uint8_t)((fifo_data_buf[i] >> 19) & 0x1F);
				uint32_t val = fifo_data_buf[i] & 0x7FFFFu;
				LOG_INF("  U10 slot[%u] tag%02u val=%6u", i, tag, val);
			}
			for (uint8_t i = 0; i < sample_count_u2 && i < 12; i++) {
				uint8_t  tag = (uint8_t)((fifo_u2_buf[i] >> 19) & 0x1F);
				uint32_t val = fifo_u2_buf[i] & 0x7FFFFu;
				LOG_INF("  U2  slot[%u] tag%02u val=%6u", i, tag, val);
			}
		}

		/* Every 25 loops (~5s) dump full tag histograms */
		if ((loop % 25) == 0) {
			if (sample_count > 0) {
				LOG_INF("--- U10 histogram ---");
				max86140_log_tag_histogram(fifo_data_buf, sample_count);
			}
			if (sample_count_u2 > 0) {
				LOG_INF("--- U2 histogram ---");
				max86140_log_tag_histogram(fifo_u2_buf, sample_count_u2);
			}
		}

		loop++;

			/* ── LSM6DSOTR poll — fetch every loop (26 Hz IMU, 200ms loop → ~5 new) ── */
			if (lsmd_is_ready()) {
				struct lsmd_accel_sample accel_raw;
				struct lsmd_accel_cm_s2 accel_cm;
				struct lsmd_gyro_sample gyro_raw;
				struct lsmd_gyro_mrad_s gyro_mrad;
				struct lsmd_wakeup_event wake_evt;
				int rc = lsmd_read_accel_gyro(&accel_raw, &gyro_raw);

				if (rc == 0) {
					if ((loop % 5) == 0) {
						LOG_INF("IMU accel X=%d.%02d Y=%d.%02d Z=%d.%02d m/s²",
							accel_raw.x.val1, abs(accel_raw.x.val2) / 10000,
							accel_raw.y.val1, abs(accel_raw.y.val2) / 10000,
							accel_raw.z.val1, abs(accel_raw.z.val2) / 10000);
						LOG_INF("IMU gyro  X=%d.%02d Y=%d.%02d Z=%d.%02d rad/s",
							gyro_raw.x.val1, abs(gyro_raw.x.val2) / 10000,
							gyro_raw.y.val1, abs(gyro_raw.y.val2) / 10000,
							gyro_raw.z.val1, abs(gyro_raw.z.val2) / 10000);
					}

					if (current_conn != NULL) {
						lsmd_accel_to_cm_s2(&accel_raw, &accel_cm);
						lsmd_gyro_to_mrad_s(&gyro_raw, &gyro_mrad);
						al_transmit_accel(accel_cm.x, 200); /* slot 200 = X */
						al_transmit_accel(accel_cm.y, 201); /* slot 201 = Y */
						al_transmit_accel(accel_cm.z, 202); /* slot 202 = Z */
						al_transmit_gyro(gyro_mrad.x, 210); /* slot 210 = gyro X */
						al_transmit_gyro(gyro_mrad.y, 211); /* slot 211 = gyro Y */
						al_transmit_gyro(gyro_mrad.z, 212); /* slot 212 = gyro Z */
					}
				} else {
					LOG_WRN("IMU fetch failed (err %d)", rc);
				}

				/* Poll the IMU wake-up source after fetching accel/gyro so a motion
				 * burst can be logged and forwarded without a separate interrupt path. */
				rc = lsmd_poll_wakeup_event(&wake_evt);
				if (rc == 0 && wake_evt.active) {
					uint8_t axis_mask = (wake_evt.x ? BIT(0) : 0U) |
							 (wake_evt.y ? BIT(1) : 0U) |
							 (wake_evt.z ? BIT(2) : 0U);
					LOG_INF("IMU wake-up detected (x=%u y=%u z=%u)",
						wake_evt.x, wake_evt.y, wake_evt.z);
					if (current_conn != NULL) {
						al_transmit_wakeup(axis_mask);
					}
				} else if (rc != 0) {
					LOG_WRN("IMU wake-up poll failed (err %d)", rc);
				}
			}

		if (current_conn != NULL) {
			/* Transmit only the most recent complete cycle (12 slots) from U10.
			 * Sending all 60 accumulated samples floods the BLE NUS TX queue and
			 * causes bt_nus_send() to fail on every packet. One cycle = 12 samples. */
			uint8_t u10_start = (sample_count > 12) ? sample_count - 12 : 0;
			for (uint8_t i = u10_start; i < sample_count; i++)
				al_transmit_data(fifo_data_buf[i], (uint8_t)(i - u10_start));
			/* U2 similarly — indices 128..139 reserved for chip-1 data */
			uint8_t u2_start = (sample_count_u2 > 12) ? sample_count_u2 - 12 : 0;
			for (uint8_t i = u2_start; i < sample_count_u2; i++)
				al_transmit_data(fifo_u2_buf[i], (uint8_t)(128u + i - u2_start));
		}
		k_sleep(K_MSEC(200));
	}
}

void ble_write_thread(void)
{
	/* Don't go any further until BLE is initialized */
	k_sem_take(&ble_init_ok, K_FOREVER);
	struct uart_data_t nus_data = {
		.len = 0,
	};

	for (;;) {
		/* Wait indefinitely for data to be sent over bluetooth */
		struct uart_data_t *buf = k_fifo_get(&fifo_uart_rx_data,
						     K_FOREVER);

		int plen = MIN(sizeof(nus_data.data) - nus_data.len, buf->len);
		int loc = 0;

		while (plen > 0) {
			memcpy(&nus_data.data[nus_data.len], &buf->data[loc], plen);
			nus_data.len += plen;
			loc += plen;

			if (nus_data.len >= sizeof(nus_data.data) ||
			   (nus_data.data[nus_data.len - 1] == '\n') ||
			   (nus_data.data[nus_data.len - 1] == '\r')) {
				if (bt_nus_send(NULL, nus_data.data, nus_data.len)) {
					LOG_WRN("Failed to send data over BLE connection");
				}
				nus_data.len = 0;
			}

			plen = MIN(sizeof(nus_data.data), buf->len - loc);
		}

		k_free(buf);
	}
}

K_THREAD_DEFINE(ble_write_thread_id, STACKSIZE, ble_write_thread, NULL, NULL,
		NULL, PRIORITY, 0, 0);
