// Software SPI implementation for MAX86140/MAX86141 sensor
// Anhang Li (anhangli@umich.edu)
// December 2025
//
// Updated Feb 2026:
// - Fix LED_CONFIG double-write bug (combine settling + current-range in ONE write)
// - Keep PD_BIAS explicit
// - 3-slot LED sequence (Red, IR, Green) so FIFO produces 3 samples/cycle
// - Added register readback in max86140_init() to verify LED_SEQ writes
// - Added max86140_log_tag_histogram() for per-tag FIFO diagnostics
//
// Updated Apr 2026 — Proto2403 dual-chip MAX4783 mux support:
// - U10 (CSB1=P0.17): controller, GPIO_CTRL=0x04 (GPIO1=sample out, GPIO2=tristate/safe for XTAL)
// - U2  (CSB2=P0.27): target,     GPIO_CTRL=0x06 (GPIO1=trigger in, GPIO2=mux control)
//   U2 sequence: LEDC1=0x01(LED1/Red,Bank0), LEDC2=0x0B(LED5/IR,Bank1), LEDC3=0x0A(LED4/Green,Bank1)
//   → tag1=Red, tag2=IR, tag3=Green (unchanged from U10's perspective)
//
// Updated July 2026 — Rutendo Jakachira (rutendo_jakachira@brown.edu):
// - U10 PPG_CONFIG1=0x18: ADC range 8192nA, integration time 58.7µs                                [Rutendo Jakachira, rutendo_jakachira@brown.edu]
// - U10 PPG_CONFIG2=0x00: 25 SPS, no averaging                                                     [Rutendo Jakachira, rutendo_jakachira@brown.edu]
// - U10 LED drive: LED1=0x1E (Red, 14.53mA), LED2=0x3C (IR, 29.06mA), LED3=0x1E (Green, 14.53mA) [Rutendo Jakachira, rutendo_jakachira@brown.edu]
// - U10 6-slot sequencer: SEQ1=0x91, SEQ2=0xA2, SEQ3=0xB3 (full dual-PD bank scan)                [Rutendo Jakachira, rutendo_jakachira@brown.edu]
// - U2  LED_CONFIG=0xFF (readback 0xE6 due to MAX4783 mux on-resistance limiting ranges)           [Rutendo Jakachira, rutendo_jakachira@brown.edu]
// - U2  LED drive: LED1=0x3C (Red/62mA range), LED2=0x78 (Green/31mA range), LED3=0x78 (IR/62mA)  [Rutendo Jakachira, rutendo_jakachira@brown.edu]
// - U2  3-slot mux sequencer: SEQ1=0xB1, SEQ2=0x0A, SEQ3=0x00                                     [Rutendo Jakachira, rutendo_jakachira@brown.edu]
//   (Red drives LED4 package via GPIO2=LOW, Green+IR drive LED1 package via GPIO2=HIGH)

#include "max86140_spi.h"

#include <zephyr/types.h>
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>

LOG_MODULE_DECLARE(peripheral_uart, LOG_LEVEL_INF);

//--------------------------------------------
// Getting GPIO Spec from Devicetree (Proto2403 actual GPIO pins)
#define SCK_NODE  DT_NODELABEL(max_sclk)
#define SDI_NODE  DT_NODELABEL(max_sdi)
#define SDO_NODE  DT_NODELABEL(max_sdo)
#define CSB1_NODE DT_NODELABEL(max_csb1)
#define CSB2_NODE DT_NODELABEL(max_csb2)
static const struct gpio_dt_spec max_sclk = GPIO_DT_SPEC_GET(SCK_NODE,  gpios);
static const struct gpio_dt_spec max_sdi  = GPIO_DT_SPEC_GET(SDI_NODE,  gpios);
static const struct gpio_dt_spec max_sdo  = GPIO_DT_SPEC_GET(SDO_NODE,  gpios);
static const struct gpio_dt_spec max_csb1 = GPIO_DT_SPEC_GET(CSB1_NODE, gpios);
static const struct gpio_dt_spec max_csb2 = GPIO_DT_SPEC_GET(CSB2_NODE, gpios);

// GPIO control macros
// This method is still quite slow due to all the Zephyr bloat.
// Maximum toggle rate is just a few MHz.
// To make this go faster, consider writing directly to the GPIO registers,
// or use hardware SPI.
#define CSN_ON()     gpio_pin_set_dt(&max_csb1, 1)
#define CSN_OFF()    gpio_pin_set_dt(&max_csb1, 0)
#define CSN2_ON()    gpio_pin_set_dt(&max_csb2, 1)
#define CSN2_OFF()   gpio_pin_set_dt(&max_csb2, 0)
#define MOSI_ON()   gpio_pin_set_dt(&max_sdi, 1)
#define MOSI_OFF()  gpio_pin_set_dt(&max_sdi, 0)
#define SCK_ON()    gpio_pin_set_dt(&max_sclk, 1)
#define SCK_OFF()   gpio_pin_set_dt(&max_sclk, 0)
#define MISO_READ() gpio_pin_get_dt(&max_sdo)

// CSN Delay function
// k_sleep is a bit slow, using assembly NOP allows more precise timing control
static inline void _SPI_DELAY(const uint32_t cycles)
{
    for (int i = 0; i < (int)cycles; i++) {
        __asm__ volatile("nop");
    }
}

// Initialize GPIOs for MAX86140 Software SPI (Proto2403 pins)
// SCK must idle LOW (Mode 0, CPOL=0) so that CSN_OFF with SCK=0 selects Mode 0
// and the very first SCK_ON() in the bit-bang loop creates a true rising edge
// for bit 23 (address MSB).  If SCK idles HIGH (Mode 3) the first SCK_ON() is
// a no-op and all bits shift by one, corrupting every transaction.
void max86140_spi_init(void)
{
    gpio_pin_configure_dt(&max_csb1, GPIO_OUTPUT_HIGH);   // CSB1 deselected (U10)
    gpio_pin_configure_dt(&max_csb2, GPIO_OUTPUT_HIGH);   // CSB2 deselected (U2)
    gpio_pin_configure_dt(&max_sdi,  GPIO_OUTPUT_LOW);    // MOSI idle low
    gpio_pin_configure_dt(&max_sclk, GPIO_OUTPUT_LOW);    // SCK idle LOW = Mode 0
    gpio_pin_configure_dt(&max_sdo,  GPIO_INPUT | GPIO_PULL_DOWN);
}

#define SPI_DELAY_CYCLES 50

// Software SPI Single Byte Read
uint8_t max86140_spi_read(uint8_t reg_addr)
{
    // Sampled on the Rising Edge
    // N'    23 22 21 20 19 18 17 16 15 14 13 12 11 10 09 08 07 06 05 04 03 02 01 00
    // SCLK  01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24
    // TX    A7 A6 A5 A4 A3 A2 A1 A0  1 XX XX XX XX XX XX XX XX XX XX XX XX XX XX XX
    // RX                               XX XX XX XX XX XX XX D7 D6 D5 D4 D3 D2 D1 D0
    uint32_t dq;
    uint8_t data_in = 0;

    dq = 0U | ((uint32_t)(reg_addr & 0xFF) << 16) | (1U << 15); // Address and Read command

    CSN_OFF();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    for (int i = 0; i < 24; i++) {
        if (dq & 0x800000U) {
            MOSI_ON();
        } else {
            MOSI_OFF();
        }

        SCK_ON();

        // Read MISO on rising edge (last 8 clocks)
        if (i >= 16) {
            data_in = (uint8_t)((data_in << 1) | (MISO_READ() & 0x01));
        }

        SCK_OFF();
        dq <<= 1;
    }

    _SPI_DELAY(SPI_DELAY_CYCLES);
    CSN_ON();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    return data_in;
}

// Software SPI Single Byte Write
void max86140_spi_write(uint8_t reg_addr, uint8_t data)
{
    // Sampled on the Rising Edge
    // N'    23 22 21 20 19 18 17 16 15 14 13 12 11 10 09 08 07 06 05 04 03 02 01 00
    // SCLK  01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24
    // TX    A7 A6 A5 A4 A3 A2 A1 A0  0 XX XX XX XX XX XX XX D7 D6 D5 D4 D3 D2 D1 D0
    uint32_t dq = 0U | ((uint32_t)(reg_addr & 0xFF) << 16) | (uint32_t)data;

    CSN_OFF();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    for (int i = 0; i < 24; i++) {
        if (dq & 0x800000U) {
            MOSI_ON();
        } else {
            MOSI_OFF();
        }

        SCK_ON();
        SCK_OFF();

        dq <<= 1;
    }

    _SPI_DELAY(SPI_DELAY_CYCLES);
    CSN_ON();
    _SPI_DELAY(SPI_DELAY_CYCLES);
}

// Software SPI Burst Read from FIFO
// databuf needs to be pre-allocated with enough space
// Maximum size of the fifo is 128 words
uint32_t* max86140_spi_read_burst(uint32_t* databuf, uint8_t reg_addr, uint8_t length)
{
    // First send 16-bit read command (addr + R/W) then read N*24 bits
    int word_index = 0;
    uint32_t data_in = 0;

    // Send Read Command
    uint16_t dq = 0U | ((uint16_t)(reg_addr & 0xFF) << 8) | (1U << 7);

    CSN_OFF();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    for (int i = 0; i < 16; i++) {
        if (dq & 0x8000U) {
            MOSI_ON();
        } else {
            MOSI_OFF();
        }
        SCK_ON();
        SCK_OFF();
        dq <<= 1;
    }

    // Burst Read Data Words (24 bits per word)
    for (int word = 0; word < length; word++) {
        data_in = 0;
        for (int sclk_index = 0; sclk_index < 24; sclk_index++) {
            SCK_ON();
            data_in = (data_in << 1) | (uint32_t)(MISO_READ() & 0x01);
            SCK_OFF();
        }
        databuf[word_index++] = data_in;
    }

    _SPI_DELAY(SPI_DELAY_CYCLES);
    CSN_ON();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    return databuf;
}
// --------------------------------------------

static inline void _max86140_set_bits(uint8_t reg, uint8_t mask)
{
    uint8_t v = max86140_spi_read(reg);
    max86140_spi_write(reg, (uint8_t)(v | mask));
}

static inline void _max86140_clr_bits(uint8_t reg, uint8_t mask)
{
    uint8_t v = max86140_spi_read(reg);
    max86140_spi_write(reg, (uint8_t)(v & (uint8_t)~mask));
}

// --------------------------------------------
// U2 (secondary MAX86141) SPI helpers via CSB2
// Shared bus (SCLK/MOSI/MISO), separate chip-select CSB2=P0.27.
// Only one CS may be asserted at a time; both are deselected between calls.
// --------------------------------------------
static void _spi_write_u2(uint8_t reg_addr, uint8_t data)
{
    uint32_t dq = 0U | ((uint32_t)(reg_addr & 0xFF) << 16) | (uint32_t)data;

    CSN2_OFF();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    for (int i = 0; i < 24; i++) {
        if (dq & 0x800000U) {
            MOSI_ON();
        } else {
            MOSI_OFF();
        }
        SCK_ON();
        SCK_OFF();
        dq <<= 1;
    }

    _SPI_DELAY(SPI_DELAY_CYCLES);
    CSN2_ON();
    _SPI_DELAY(SPI_DELAY_CYCLES);
}

static uint8_t _spi_read_u2(uint8_t reg_addr)
{
    uint32_t dq;
    uint8_t data_in = 0;

    dq = 0U | ((uint32_t)(reg_addr & 0xFF) << 16) | (1U << 15);

    CSN2_OFF();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    for (int i = 0; i < 24; i++) {
        if (dq & 0x800000U) {
            MOSI_ON();
        } else {
            MOSI_OFF();
        }
        SCK_ON();
        if (i >= 16) {
            data_in = (uint8_t)((data_in << 1) | (MISO_READ() & 0x01));
        }
        SCK_OFF();
        dq <<= 1;
    }

    _SPI_DELAY(SPI_DELAY_CYCLES);
    CSN2_ON();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    return data_in;
}

// --------------------------------------------
// MAX86140 Register Definitions
// --------------------------------------------
// Status
#define MAX8614X_REG_INT_STATUS_1      0x00
#define MAX8614X_REG_INT_STATUS_2      0x01
#define MAX8614X_REG_INT_ENABLE_1      0x02
// FIFO
#define MAX8614X_REG_FIFO_WR_PTR       0x04
#define MAX8614X_REG_FIFO_RD_PTR       0x05
#define MAX8614X_REG_OVF_COUNTER       0x06
#define MAX8614X_REG_FIFO_DATA_COUNT   0x07
#define MAX8614X_REG_FIFO_DATA         0x08
#define MAX8614X_REG_FIFO_CFG1         0x09
#define MAX8614X_REG_FIFO_CFG2         0x0A
// System Control
#define MAX8614X_REG_MODE_CONFIG       0x0D
// PPG Configuration
#define MAX8614X_REG_PPG_SYNC_CTRL     0x10
#define MAX8614X_REG_PPG_CONFIG1       0x11
#define MAX8614X_REG_PPG_CONFIG2       0x12
#define MAX8614X_REG_LED_CONFIG        0x13
#define MAX8614X_REG_PD_BIAS           0x15
// PPG Picket Fence Detect and Replace
#define MAX8614X_REG_PICKET_FENCE      0x16
// LED Sequence Control
#define MAX8614X_REG_LED_SEQ1          0x20
#define MAX8614X_REG_LED_SEQ2          0x21
#define MAX8614X_REG_LED_SEQ3          0x22
// LED Pulse Amplitude
#define MAX8614X_REG_LED1_PA           0x23
#define MAX8614X_REG_LED2_PA           0x24
#define MAX8614X_REG_LED3_PA           0x25
#define MAX8614X_REG_LED4_PA           0x26
#define MAX8614X_REG_LED5_PA           0x27
#define MAX8614X_REG_LED6_PA           0x28
#define MAX8614X_REG_LED_PILOT_PA      0x29
#define MAX8614X_REG_LED_RANGE1        0x2A
#define MAX8614X_REG_LED_RANGE2        0x2B
// PPG1_HI_RES_DAC
#define MAX8614X_REG_S1_HRDAC1         0x2C
#define MAX8614X_REG_S2_HRDAC1         0x2D
#define MAX8614X_REG_S3_HRDAC1         0x2E
#define MAX8614X_REG_S4_HRDAC1         0x2F
#define MAX8614X_REG_S5_HRDAC1         0x30
#define MAX8614X_REG_S6_HRDAC1         0x31
// PPG2_HI_RES_DAC
#define MAX8614X_REG_S1_HRDAC2         0x32
#define MAX8614X_REG_S2_HRDAC2         0x33
#define MAX8614X_REG_S3_HRDAC2         0x34
#define MAX8614X_REG_S4_HRDAC2         0x35
#define MAX8614X_REG_S5_HRDAC2         0x36
#define MAX8614X_REG_S6_HRDAC2         0x37
// Die Temperature
#define MAX8614X_REG_TEMP_CONFIG       0x40
#define MAX8614X_REG_TEMP_INTEGER      0x41
#define MAX8614X_REG_TEMP_FRACTION     0x42
// SHA256
#define MAX8614X_REG_SHA256_CMD        0xF0
#define MAX8614X_REG_SHA256_CONFIG     0xF1
// Memory
#define MAX8614X_REG_MEM_CONTROL       0xF2
#define MAX8614X_REG_MEM_INDEX         0xF3
#define MAX8614X_REG_MEM_DATA          0xF4
// Part ID
#define MAX8614X_REG_PART_ID           0xFF

// Bit masks and configurations
// MODE_CONFIG (0x0D)
#define MAX8614X_MODE_LP_MODE          (1 << 2)
#define MAX8614X_MODE_SHDN             (1 << 1)
#define MAX8614X_MODE_RESET            (1 << 0)

// FIFO Config bits
#define MAX8614X_FIFO_A_FULL_INT_EN    (1 << 7)
#define MAX8614X_FIFO_ROLL_OVER_EN     (1 << 1)

// PPG_CONFIG2 (0x12)
#define MAX8614X_PPG_SR_200SPS         (0x04 << 3)

// LED_CONFIG (0x13)
// NOTE: your original code treated these as separate registers; they are fields in ONE register.
#define MAX8614X_LED_SETTLING_12US     (0x3 << 6)
#define MAX8614X_LED_RANGE_124MA       (0x3)

// LED drive current example
#define MAX8614X_LED_CURRENT_15mA      (0x20)

// INT_STATUS_1 bits
#define MAX8614X_INT1_A_FULL           (1 << 7)
#define MAX8614X_INT1_DATA_RDY         (1 << 6)

// FIFO_CFG2 bits (0x0A)
#define MAX8614X_FIFO_FLUSH            (1 << 6)   // FLUSH_FIFO (self-clearing)
#define MAX8614X_FIFO_STAT_CLR         (1 << 5)   // FIFO_STAT_CLR

// Keep this visible to functions below (avoid "macro inside function" pitfalls)
#define MAX8614X_FIFO_A_FULL           0x10
#define MAX8614X_FIFO_SAMPLES          (128 - MAX8614X_FIFO_A_FULL)

void max86140_init(void)
{
    // Reset
    max86140_spi_write(MAX8614X_REG_MODE_CONFIG, MAX8614X_MODE_RESET);
    k_sleep(K_MSEC(1));

    // Clear Interrupts
    (void)max86140_spi_read(MAX8614X_REG_INT_STATUS_1);
    (void)max86140_spi_read(MAX8614X_REG_INT_STATUS_2);

    // Enter Shutdown mode to configure
    max86140_spi_write(MAX8614X_REG_MODE_CONFIG, MAX8614X_MODE_SHDN);

    // -------------------------------
    // PPG Analog Configuration
    // -------------------------------
    // PPG_CONFIG1: [7]=ALC_DIS(0), [6:4]=PPG_ADC_RGE(001=8192nA), [3:2]=PPG_TINT(10=58.7us), [1:0]=0
    // Master (U10/PD1): ADC full-scale = 8192 nA per firmware spec
    max86140_spi_write(MAX8614X_REG_PPG_CONFIG1, 0x18);

    // PPG_CONFIG2: bits[7:3]=PPG_SR(00000=25SPS), bits[2:0]=SMP_AVG(000=1x no averaging)
    // 0x03 was wrong — SMP_AVG=011=8x giving only 3.125 SPS output instead of 25 SPS
    max86140_spi_write(MAX8614X_REG_PPG_CONFIG2, 0x00);

    // LED_CONFIG: combine fields in ONE write (fix)
    max86140_spi_write(MAX8614X_REG_LED_CONFIG,
                       (uint8_t)(MAX8614X_LED_SETTLING_12US | MAX8614X_LED_RANGE_124MA));

    // Photodiode Bias: both PD1 and PD2 active per firmware spec
    // PPG1(PD1)=8192nA, PPG2(PD2)=8192nA — tags 01-03 and 07-09 expected in FIFO
    max86140_spi_write(MAX8614X_REG_PD_BIAS, 0x11); // Bias PD1 + PD2

    // LED currents per firmware spec (124/256 * N mA):
    max86140_spi_write(MAX8614X_REG_LED1_PA, 0x1E); // 14.53 mA (Red,   LED1_DRV = 30)
    max86140_spi_write(MAX8614X_REG_LED2_PA, 0x3C); // 29.06 mA (IR,    LED2_DRV = 60)
    max86140_spi_write(MAX8614X_REG_LED3_PA, 0x1E); // 14.53 mA (Green, LED3_DRV = 30)

    // -------------------------------
    // FIFO Configuration
    // -------------------------------
    // FIFO almost full threshold
    max86140_spi_write(MAX8614X_REG_FIFO_CFG1, MAX8614X_FIFO_A_FULL);

    // Optional: enable roll over / interrupts if you want them later
    // _max86140_set_bits(MAX8614X_REG_FIFO_CFG2, MAX8614X_FIFO_ROLL_OVER_EN);
    // _max86140_set_bits(MAX8614X_REG_INT_ENABLE_1, MAX8614X_FIFO_A_FULL_INT_EN);

    // -------------------------------
    // LED Sequence Configuration — 6-slot, 2-bank full scan
    // -------------------------------
    // Each LEDC nibble: bit3=GPIO2(bank), bits[2:0]=LED driver (1=LED1,2=LED2,3=LED3)
    // Bank0 (GPIO2=LOW,  bit3=0): mux routes LED driver to Bank0 physical LEDs
    // Bank1 (GPIO2=HIGH, bit3=1): mux routes LED driver to Bank1 physical LEDs
    //
    // 6-slot sequence (SEQ register nibble: bits[7:4]=even slot, bits[3:0]=odd slot):
    //   Slot1: LEDC=0x01 → LED1/Bank0  (tag01 PPG1, tag07 PPG2)
    //   Slot2: LEDC=0x09 → LED1/Bank1  (tag02 PPG1, tag08 PPG2)
    //   Slot3: LEDC=0x02 → LED2/Bank0  (tag03 PPG1, tag09 PPG2)
    //   Slot4: LEDC=0x0A → LED2/Bank1  (tag04 PPG1, tag10 PPG2)
    //   Slot5: LEDC=0x03 → LED3/Bank0  (tag05 PPG1, tag11 PPG2)
    //   Slot6: LEDC=0x0B → LED3/Bank1  (tag06 PPG1, tag12 PPG2)
    //
    // 12 FIFO samples per cycle (6 slots × 2 PDs), 25 SPS → 300 samples/sec from U10
    max86140_spi_write(MAX8614X_REG_LED_SEQ1, 0x91); // {LEDC2=0x9(LED1/B1), LEDC1=0x1(LED1/B0)}
    max86140_spi_write(MAX8614X_REG_LED_SEQ2, 0xA2); // {LEDC4=0xA(LED2/B1), LEDC3=0x2(LED2/B0)}
    max86140_spi_write(MAX8614X_REG_LED_SEQ3, 0xB3); // {LEDC6=0xB(LED3/B1), LEDC5=0x3(LED3/B0)}

    // -------------------------------
    // GPIO Sync Control — U10 controller/output mode
    // 0x04: GPIO1 = conversion-start OUTPUT → drives U2 via J15 0-ohm jumper
    //        GPIO2 = tristate (U10 LEDC codes never assert LED4/5/6, so GPIO2
    //                          stays safe for the RTC crystal on that pin)
    // NOTE: U10 still samples freely at 25 SPS on its own clock. The GPIO1
    //       pulse just tells U2 when each integration window starts.
    // -------------------------------
    max86140_spi_write(MAX8614X_REG_PPG_SYNC_CTRL, 0x04);

    // ---- Readback verify ----
    uint8_t rb_seq1 = max86140_spi_read(MAX8614X_REG_LED_SEQ1);
    uint8_t rb_seq2 = max86140_spi_read(MAX8614X_REG_LED_SEQ2);
    uint8_t rb_seq3 = max86140_spi_read(MAX8614X_REG_LED_SEQ3);
    uint8_t rb_cfg1 = max86140_spi_read(MAX8614X_REG_PPG_CONFIG1);
    uint8_t rb_cfg2 = max86140_spi_read(MAX8614X_REG_PPG_CONFIG2);
    uint8_t rb_led1 = max86140_spi_read(MAX8614X_REG_LED1_PA);
    uint8_t rb_led2 = max86140_spi_read(MAX8614X_REG_LED2_PA);
    uint8_t rb_led3 = max86140_spi_read(MAX8614X_REG_LED3_PA);
    uint8_t rb_sync = max86140_spi_read(MAX8614X_REG_PPG_SYNC_CTRL);
    uint8_t rb_bias = max86140_spi_read(MAX8614X_REG_PD_BIAS);
    LOG_INF("U10 LED_SEQ1=0x%02x(exp 0x91)  SEQ2=0x%02x(exp 0xA2)  SEQ3=0x%02x(exp 0xB3)",
            rb_seq1, rb_seq2, rb_seq3);
    LOG_INF("U10 PPG_CFG1=0x%02x(exp 0x18)  PPG_CFG2=0x%02x  LED1_PA=0x%02x  LED2_PA=0x%02x  LED3_PA=0x%02x",
            rb_cfg1, rb_cfg2, rb_led1, rb_led2, rb_led3);
    LOG_INF("U10 PPG_SYNC_CTRL=0x%02x(exp 0x04)  PD_BIAS=0x%02x(exp 0x11)", rb_sync, rb_bias);
    if (rb_seq1 != 0x91 || rb_seq2 != 0xA2 || rb_seq3 != 0xB3) {
        LOG_ERR("U10 LED_SEQ mismatch — SPI write may have failed!");
    }
    if (rb_cfg1 != 0x18) {
        LOG_ERR("U10 PPG_CONFIG1 mismatch — expected 0x18, got 0x%02x", rb_cfg1);
    }
    if (rb_sync != 0x04) {
        LOG_ERR("U10 PPG_SYNC_CTRL mismatch — expected 0x04, got 0x%02x", rb_sync);
    }

    // Start Sampling (exit shutdown)
    max86140_spi_write(MAX8614X_REG_MODE_CONFIG, 0x00);
}

// --------------------------------------------
// U2 (secondary MAX86141) initialization
//
// U2 is the MAX4783 mux controller chip.  Its GPIO2 pin is connected to the
// mux select line (J16 pulls HIGH = Bank 1 by default).
//
// GPIO_CTRL = 0x06  (mode 0110 = TARGET):
//   GPIO1 = exposure trigger INPUT  (receives U10 sample pulse via J15)
//   GPIO2 = open-drain mux output:
//           LOW  during LED1/2/3 slots (LEDC values 0x01-0x09) → Bank 0
//           HIGH (released) during LED4/5/6 slots (0x0A-0x0C) → Bank 1
//
// U2 LED sequence (split-sequence trick):
//   LEDC1 = 0x01 (LED1, normal)     → GPIO2=LOW  → Bank 0 → Red LED active
//   LEDC2 = 0x0B (LED5, ext-mux)    → GPIO2=HIGH → Bank 1 → IR  LED active
//   LEDC3 = 0x0A (LED4, ext-mux)    → GPIO2=HIGH → Bank 1 → Green LED active
//
// U10 FIFO tags are unchanged: tag1=PPG1-LEDC1(Red), tag2=PPG1-LEDC2(IR),
//   tag3=PPG1-LEDC3(Green) — monitor HTML needs no changes.
//
// U2 FIFO is ignored (we only read U10's FIFO via burst read on CSB1).
// --------------------------------------------

/* LED sequence constants for U2 — 6-slot full bank scan (same as U10) */
#define MUX_LED_SEQ1   0x91u  /* LEDC1=0x1(LED1/Bank0), LEDC2=0x9(LED1/Bank1) */
#define MUX_LED_SEQ2   0xA2u  /* LEDC3=0x2(LED2/Bank0), LEDC4=0xA(LED2/Bank1) */
#define MUX_LED_SEQ3   0xB3u  /* LEDC5=0x3(LED3/Bank0), LEDC6=0xB(LED3/Bank1) */

void max86141_u2_init(void)
{
    // --- Reset U2 ---
    _spi_write_u2(MAX8614X_REG_MODE_CONFIG, MAX8614X_MODE_RESET);
    k_sleep(K_MSEC(1));

    // Clear U2 interrupts
    (void)_spi_read_u2(MAX8614X_REG_INT_STATUS_1);
    (void)_spi_read_u2(MAX8614X_REG_INT_STATUS_2);

    // Enter U2 Shutdown mode for configuration
    _spi_write_u2(MAX8614X_REG_MODE_CONFIG, MAX8614X_MODE_SHDN);

    // --- PPG Analog Config (match U10 settings) ---
    // PPG_CONFIG1: [7]=ALC_DIS(0), [6:4]=PPG_ADC_RGE(001=8192nA), [3:2]=PPG_TINT(10=58.7us), [1:0]=0
    // Match U10: same 8192 nA full-scale so counts are directly comparable across all 4 PDs
    _spi_write_u2(MAX8614X_REG_PPG_CONFIG1, 0x18);
    _spi_write_u2(MAX8614X_REG_PPG_CONFIG2, 0x00);   // 25 SPS, SMP_AVG=1x (no averaging)

    // LED_CONFIG: ALL channels must be set to 124mA range, not just LED1.
    // 0xFF = bits[7:6]=11(12µs settling) | bits[5:4]=11(LED3=124mA)
    //              | bits[3:2]=11(LED2=124mA)   | bits[1:0]=11(LED1=124mA)
    // Previously 0xC3 left LED2 and LED3 at 31mA default — IR and Green were
    // drawing current from the wrong range, producing ~7mA instead of the
    // intended 14–29mA.
    _spi_write_u2(MAX8614X_REG_LED_CONFIG, 0xFF);
    _spi_write_u2(MAX8614X_REG_PD_BIAS, 0x11);       // PD1+PD2 per spec (PD3+PD4 on U2)

    // --- LED Pulse Amplitudes for U2's 3 active channels ---
    // LEDC code bit-field: bit3=GPIO2 state, bits[2:0]=LED driver number.
    //   LEDC1=0x01 → LED1 driver, GPIO2=LOW  (Bank0) → Red   → current from LED1_PA
    //   LEDC2=0x0B → LED3 driver, GPIO2=HIGH (Bank1) → IR    → current from LED3_PA
    //   LEDC3=0x0A → LED2 driver, GPIO2=HIGH (Bank1) → Green → current from LED2_PA
    //
    // NOTE: LED_CONFIG writes 0xFF but readback is 0xe6 — actual ranges are:
    //   LED1_RGE = 62 mA  (not 124 mA)
    //   LED2_RGE = 31 mA  (not 124 mA)
    //   LED3_RGE = 62 mA  (not 124 mA)
    // PA values are scaled to deliver the target currents despite the lower ranges:
    //   PA = round(target_mA / actual_range_mA * 256)
    //   Red   14.53 mA: 14.53/62  * 256 = 60  → 0x3C
    //   Green 14.53 mA: 14.53/31  * 256 = 120 → 0x78
    //   IR    29.06 mA: 29.06/62  * 256 = 120 → 0x78
    _spi_write_u2(MAX8614X_REG_LED1_PA, 0x3C);   // 14.53 mA Red   (62mA range,  PA=60) — matches U10 LED1 current
    _spi_write_u2(MAX8614X_REG_LED2_PA, 0x78);   // 14.53 mA Green (31mA range,  PA=120)
    _spi_write_u2(MAX8614X_REG_LED3_PA, 0x78);   // 29.06 mA IR    (62mA range,  PA=120)

    // --- FIFO Config ---
    _spi_write_u2(MAX8614X_REG_FIFO_CFG1, MAX8614X_FIFO_A_FULL);

    // --- LED Sequence ---
    // Slot1: LEDC1=0x01(LED1)  → U2 GPIO2=LOW  → Bank 0 → Red
    // Slot2: LEDC2=0x0B(LED5)  → U2 GPIO2=HIGH → Bank 1 → IR
    // Slot3: LEDC3=0x0A(LED4)  → U2 GPIO2=HIGH → Bank 1 → Green
    _spi_write_u2(MAX8614X_REG_LED_SEQ1, MUX_LED_SEQ1); // 0x91: LED1/B0, LED1/B1
    _spi_write_u2(MAX8614X_REG_LED_SEQ2, MUX_LED_SEQ2); // 0xA2: LED2/B0, LED2/B1
    _spi_write_u2(MAX8614X_REG_LED_SEQ3, MUX_LED_SEQ3); // 0xB3: LED3/B0, LED3/B1

    // --- GPIO Sync Control — U2 mode ---
    // PRODUCTION (J15 populated):  0x06 = target mode
    //   GPIO1=exposure trigger INPUT (from U10 via J15 0-ohm jumper)
    //   GPIO2=LOW during LED1/2/3 LEDC slots, released HIGH via J16 during LED4/5/6 slots
    //
    // STANDALONE TEST (J15 absent): 0x01 = GPIO2-mux-only, no external sync required
    //   U2 runs on its own 25 SPS clock.  LEDC codes 0x0A/0x0B still switch GPIO2.
    //   U10 and U2 are unsynchronised but both fire — useful to verify LED path works.
    //   Change back to 0x06 once J15 is confirmed and sync is needed.
    // PPG_SYNC_CTRL for U2 in standalone mode:
    //   0x04 = same as U10 (self-clocked controller, GPIO1=sample-start output).
    //   Previously 0x01 but that left U2 FIFO empty — 0x04 is the known-good
    //   self-clocking value since it works for U10.
    //   Switch to 0x06 (target mode, requires J15) once external sync is confirmed.
#define U2_SYNC_STANDALONE  0x04u   /* self-clocked, GPIO1=sample-start out (same as U10) */
#define U2_SYNC_TARGET      0x06u   /* target mode — requires J15 */
    _spi_write_u2(MAX8614X_REG_PPG_SYNC_CTRL, U2_SYNC_STANDALONE);

    // --- Readback verify ---
    uint8_t rb_seq1  = _spi_read_u2(MAX8614X_REG_LED_SEQ1);
    uint8_t rb_seq2  = _spi_read_u2(MAX8614X_REG_LED_SEQ2);
    uint8_t rb_seq3  = _spi_read_u2(MAX8614X_REG_LED_SEQ3);
    uint8_t rb_sync  = _spi_read_u2(MAX8614X_REG_PPG_SYNC_CTRL);
    uint8_t rb_led1  = _spi_read_u2(MAX8614X_REG_LED1_PA);
    uint8_t rb_led2  = _spi_read_u2(MAX8614X_REG_LED2_PA);
    uint8_t rb_led3  = _spi_read_u2(MAX8614X_REG_LED3_PA);
    uint8_t rb_range = _spi_read_u2(MAX8614X_REG_LED_CONFIG);
    LOG_INF("U2 LED_SEQ1=0x%02x(exp 0x91)  SEQ2=0x%02x(exp 0xA2)  SEQ3=0x%02x(exp 0xB3)  SYNC=0x%02x",
            rb_seq1, rb_seq2, rb_seq3, rb_sync);
    LOG_INF("U2 LED1_PA=0x%02x(exp 0x3C/Red)  LED2_PA=0x%02x(exp 0x78/Green)  LED3_PA=0x%02x(exp 0x78/IR)",
            rb_led1, rb_led2, rb_led3);
    LOG_INF("U2 LED_CONFIG=0x%02x(exp 0xFF: all-124mA)", rb_range);
    if (rb_seq1 != MUX_LED_SEQ1 || rb_seq2 != MUX_LED_SEQ2 || rb_seq3 != MUX_LED_SEQ3) {
        LOG_ERR("U2 LED_SEQ mismatch — CSB2 SPI may have failed!");
    }
    if (rb_led1 < 0x30 || rb_led2 < 0x60 || rb_led3 < 0x60) {
        LOG_WRN("U2 LED PA lower than expected (LED1=0x%02x LED2=0x%02x LED3=0x%02x)"
                " — SPI write may have failed or LED_CONFIG range still wrong",
                rb_led1, rb_led2, rb_led3);
    }

    // --- Start U2 sampling (exit shutdown) ---
    _spi_write_u2(MAX8614X_REG_MODE_CONFIG, 0x00);

    // --- Post-start diagnostics ---
    // Confirm U2 actually exited shutdown and is accumulating FIFO samples.
    k_sleep(K_MSEC(50));
    uint8_t rb_mode = _spi_read_u2(MAX8614X_REG_MODE_CONFIG);
    uint8_t rb_pid  = _spi_read_u2(MAX8614X_REG_PART_ID);
    uint8_t rb_ovf  = _spi_read_u2(MAX8614X_REG_OVF_COUNTER);
    uint8_t rb_fcnt = _spi_read_u2(MAX8614X_REG_FIFO_DATA_COUNT);
    LOG_INF("U2 post-start: MODE=0x%02x(exp 0x00)  PartID=0x%02x(exp 0x24)  OVF=%u  FIFO_CNT=%u",
            rb_mode, rb_pid, rb_ovf, rb_fcnt);
    if (rb_mode & 0x02) {
        LOG_ERR("U2 still in SHUTDOWN after exit! FIFO will stay empty.");
    }
    if (rb_pid != 0x24 && rb_pid != 0x25) {
        LOG_ERR("U2 Part ID unexpected (0x%02x) — CSB2 SPI may be broken", rb_pid);
    }

    LOG_INF("U2 (MAX4783 mux controller) initialized and running");
}

// Call this from the main loop every N iterations to log a tag histogram.
// buf[] and count are from the most recent max86140_exhaust_fifo() call.
void max86140_log_tag_histogram(const uint32_t *buf, uint8_t count)
{
    // Tags per Table 3 of MAX86141 datasheet (tag=0 does not exist):
    // tag1=PPG1-LEDC1, tag2=PPG1-LEDC2, tag3=PPG1-LEDC3 ...
    // tag7=PPG2-LEDC1, tag8=PPG2-LEDC2, tag9=PPG2-LEDC3 ...
    static const char * const tag_names[32] = {
        "none(invalid)",
        "PPG1-LEDC1(Red)", "PPG1-LEDC2(IR)",  "PPG1-LEDC3(Grn)",
        "PPG1-LEDC4",      "PPG1-LEDC5",      "PPG1-LEDC6",
        "PPG2-LEDC1(Red)", "PPG2-LEDC2(IR)",  "PPG2-LEDC3(Grn)",
        "PPG2-LEDC4",      "PPG2-LEDC5",      "PPG2-LEDC6",
        "PPF1-LEDC1",      "PPF1-LEDC2",      "PPF1-LEDC3",
        "res",             "res",              "res",
        "PPF2-LEDC1",      "PPF2-LEDC2",      "PPF2-LEDC3",
        "res",             "res",              "res",
        "PROX1",           "PROX2",
        "res",             "res",              "res",
        "INVALID",         "TIMESTAMP"
    };

    uint16_t hist[32] = {0};
    for (uint8_t i = 0; i < count; i++) {
        uint8_t t = (uint8_t)((buf[i] >> 19) & 0x1FU);
        hist[t]++;
    }

    LOG_INF("Tag histogram (total=%u):", count);
    for (int t = 0; t < 32; t++) {
        if (hist[t] > 0) {
            LOG_INF("  tag%02d (%s): %u", t, tag_names[t], hist[t]);
        }
    }
}

uint32_t* max86140_device_data_read(uint32_t* dataBuf)
{
    // If you want to use sample_count dynamically, you can;
    // for now keep the original behavior (read fixed window).
    (void)max86140_spi_read(MAX8614X_REG_FIFO_DATA_COUNT);
    max86140_spi_read_burst(dataBuf, MAX8614X_REG_FIFO_DATA, MAX8614X_FIFO_SAMPLES);
    return dataBuf;
}

// Read exactly ONE FIFO sample = 3 bytes.
uint32_t max86140_read_fifo_sample24(void)
{
    uint8_t b0 = max86140_spi_read(MAX8614X_REG_FIFO_DATA);
    uint8_t b1 = max86140_spi_read(MAX8614X_REG_FIFO_DATA);
    uint8_t b2 = max86140_spi_read(MAX8614X_REG_FIFO_DATA);

    uint32_t raw24 = ((uint32_t)b0 << 16) |
                     ((uint32_t)b1 << 8) |
                     (uint32_t)b2;
    return raw24;
}

uint8_t max86140_read_part_id(void)
{
    return max86140_spi_read(MAX8614X_REG_PART_ID);
}

uint8_t max86140_check_full(void)
{
    uint8_t st1 = max86140_spi_read(MAX8614X_REG_INT_STATUS_1);
    return (st1 & MAX8614X_INT1_A_FULL) ? 1U : 0U;
}

uint8_t max86140_get_fifo_data_count(void)
{
    return max86140_spi_read(MAX8614X_REG_FIFO_DATA_COUNT);
}

// --------------------------------------------
// U2 FIFO burst read (uses CSB2)
// --------------------------------------------
static uint32_t* _spi_read_burst_u2(uint32_t* databuf, uint8_t length)
{
    int word_index = 0;
    uint32_t data_in = 0;

    uint16_t dq = 0U | ((uint16_t)(MAX8614X_REG_FIFO_DATA & 0xFF) << 8) | (1U << 7);

    CSN2_OFF();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    for (int i = 0; i < 16; i++) {
        if (dq & 0x8000U) {
            MOSI_ON();
        } else {
            MOSI_OFF();
        }
        SCK_ON();
        SCK_OFF();
        dq <<= 1;
    }

    for (int word = 0; word < length; word++) {
        data_in = 0;
        for (int sclk_index = 0; sclk_index < 24; sclk_index++) {
            SCK_ON();
            data_in = (data_in << 1) | (uint32_t)(MISO_READ() & 0x01);
            SCK_OFF();
        }
        databuf[word_index++] = data_in;
    }

    _SPI_DELAY(SPI_DELAY_CYCLES);
    CSN2_ON();
    _SPI_DELAY(SPI_DELAY_CYCLES);

    return databuf;
}

uint32_t* max86141_u2_exhaust_fifo(uint32_t* dataBuf, uint8_t* sample_count_ptr)
{
    uint8_t sample_count = _spi_read_u2(MAX8614X_REG_FIFO_DATA_COUNT);
    if (sample_count > 0) {
        _spi_read_burst_u2(dataBuf, sample_count);
    }
    *sample_count_ptr = sample_count;
    return dataBuf;
}

uint32_t* max86140_exhaust_fifo(uint32_t* dataBuf, uint8_t* sample_count_ptr)
{
    uint8_t sample_count = max86140_spi_read(MAX8614X_REG_FIFO_DATA_COUNT);
    max86140_spi_read_burst(dataBuf, MAX8614X_REG_FIFO_DATA, sample_count);
    *sample_count_ptr = sample_count;
    return dataBuf;
}