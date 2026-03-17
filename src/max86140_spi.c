// Software SPI implementation for MAX86140 sensor
// Anhang Li (anhangli@umich.edu)
// December 2025

#include "max86140_spi.h"

#include <zephyr/types.h>
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>

// Getting GPIO Spec from Devicetree (arduino-header-r3 compatible notation)
#define A0_NODE DT_NODELABEL(a0)
#define A1_NODE DT_NODELABEL(a1)
#define A2_NODE DT_NODELABEL(a2)
#define A3_NODE DT_NODELABEL(a3)
#define A4_NODE DT_NODELABEL(a4)
static const struct gpio_dt_spec a0 = GPIO_DT_SPEC_GET(A0_NODE, gpios);
static const struct gpio_dt_spec a1 = GPIO_DT_SPEC_GET(A1_NODE, gpios);
static const struct gpio_dt_spec a2 = GPIO_DT_SPEC_GET(A2_NODE, gpios);
static const struct gpio_dt_spec a3 = GPIO_DT_SPEC_GET(A3_NODE, gpios);
static const struct gpio_dt_spec a4 = GPIO_DT_SPEC_GET(A4_NODE, gpios);

// GPIO control macros
// This method is still quite slow due to all the Zephyr bloat.
// Maximum toggle rate is just a few MHz.
// To make this go faster, consider writing directly to the GPIO registers, 
// or use hardware SPI.

//              J1  Header
// ACC_INT_N    1   
// CSOPT_N      3   A2
// MISO         5   A3
// SCK          7   A1
// MOSI         9   A4

#define CSN_ON()    gpio_pin_set_dt(&a2, 1)
#define CSN_OFF()   gpio_pin_set_dt(&a2, 0)
#define MOSI_ON()   gpio_pin_set_dt(&a4, 1)
#define MOSI_OFF()  gpio_pin_set_dt(&a4, 0)
#define SCK_ON()    gpio_pin_set_dt(&a1, 1)
#define SCK_OFF()   gpio_pin_set_dt(&a1, 0)
#define MISO_READ() gpio_pin_get_dt(&a3)

// CSN Delay function
// k_sleep is a bit slow, using assembly NOP allows more precise timing control
inline static void _SPI_DELAY(const uint32_t cycles){
    // k_sleep(K_USEC(1));
    for (int i=0; i<cycles; i++) {__asm__ volatile("nop");};
}

// Initialize GPIOs for MAX86140 Software SPI
void    max86140_spi_init (void){
    gpio_pin_configure_dt(&a1, GPIO_OUTPUT_HIGH);
    gpio_pin_configure_dt(&a2, GPIO_OUTPUT_HIGH);
    gpio_pin_configure_dt(&a4, GPIO_OUTPUT_HIGH);
    gpio_pin_configure_dt(&a3, GPIO_INPUT | GPIO_PULL_DOWN);

}
#define SPI_DELAY_CYCLES 50
// Software SPI Single Byte Read
uint8_t max86140_spi_read (uint8_t reg_addr){
    // Sampled on the Rising Edge
    // N'    23 22 21 20 19 18 17 16 15 14 13 12 11 10 09 08 07 06 05 04 03 02 01 00
    // SCLK  01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24
    // TX    A7 A6 A5 A4 A3 A2 A1 A0  1 XX XX XX XX XX XX XX XX XX XX XX XX XX XX XX 
    // RX                               XX XX XX XX XX XX XX D7 D6 D5 D4 D3 D2 D1 D0
    uint32_t dq;
    uint8_t  data_in = 0;
    dq = 0 | ((reg_addr & 0xFF) << 16 ) | (0x1 << 15); // Address and Read command
    CSN_OFF();
    _SPI_DELAY(SPI_DELAY_CYCLES);
    for (int i=0; i<24; i++){
        if (dq & 0x800000){
            MOSI_ON();
        } else {
            MOSI_OFF();
        }
        SCK_ON();
        // Read MISO on rising edge
        if (i >= 16){
            data_in = (data_in << 1) | (MISO_READ() & 0x01);
        }
        SCK_OFF();
        dq = dq << 1;
    }
    _SPI_DELAY(SPI_DELAY_CYCLES);
    CSN_ON();
    _SPI_DELAY(SPI_DELAY_CYCLES);
    return data_in;
}
// Software SPI Single Byte Write
void    max86140_spi_write(uint8_t reg_addr, uint8_t data){
    // Sampled on the Rising Edge
    // N'    23 22 21 20 19 18 17 16 15 14 13 12 11 10 09 08 07 06 05 04 03 02 01 00
    // SCLK  01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24
    // TX    A7 A6 A5 A4 A3 A2 A1 A0  0 XX XX XX XX XX XX XX D7 D6 D5 D4 D3 D2 D1 D0 
    uint32_t dq;
    dq = 0 | ((reg_addr & 0xFF) << 16) | (data); 
    CSN_OFF();
    _SPI_DELAY(SPI_DELAY_CYCLES);
    for (int i=0; i<24; i++){
        if (dq & 0x800000){
            MOSI_ON();
        } else {
            MOSI_OFF();
        }
        SCK_ON();
        SCK_OFF();
        dq = dq << 1;
    }
    _SPI_DELAY(SPI_DELAY_CYCLES);
    CSN_ON();
    _SPI_DELAY(SPI_DELAY_CYCLES);
}

// Software SPI Burst Read from FIFO
// The databuf need to be pre-allocated with enough space
// Maximum size of the fifo is 128 words
uint32_t* max86140_spi_read_burst (uint32_t* databuf, uint8_t reg_addr, uint8_t length){
    // N'    23 22 21 20 19 18 17 16 15 14 13 12 11 10 09 08
    // SCLK  01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 
    // TX    A7 A6 A5 A4 A3 A2 A1 A0  0 XX XX XX XX XX XX XX
    // reg 0
    // SCLK  17  18  19  20  21  22  23  24  25  26  27  28  29  30  31  32  33  34  35  36  37  38  39  40
    // RX    D23 D22 D21 D20 D19 D18 D17 D16 D15 D14 D13 D12 D11 D10 D9  D8  D7  D6  D5  D4  D3  D2  D1  D0
    // ...
    // reg (len-1)
    // SCLK  (len-1)*24+17 ~ (len)*24+16
    // RX    D23 ... D0
    int word_index = 0;
    int sclk_index = 0;
    uint32_t data_in = 0;
    // Send Read Command
    uint16_t dq = 0 | ((reg_addr & 0xFF) << 8 ) | (0x1 << 7); // Address and Read command
    CSN_OFF();
    _SPI_DELAY(SPI_DELAY_CYCLES);
    for (int i=0; i<16; i++){
        if (dq & 0x8000){
            MOSI_ON();
        } else {    
            MOSI_OFF();
        }
        SCK_ON();
        SCK_OFF();
        dq = dq << 1;
    }
    // Burst Read Data Words
    for (int word=0; word<length; word++){
        data_in = 0;
        for (sclk_index=0; sclk_index<24; sclk_index++){
            SCK_ON();
            // Read MISO on rising edge
            // Received data is in the following format:
            // 23 22 21 20 19 18  17  16  15  14  13  12  11  10  09 08 07 06 05 04 03 02 01 00
            // T4 T3 T2 T1 T0 O18 O17 O16 O15 O14 O13 O12 O11 O10 O9 O8 O7 O6 O5 O4 O3 O2 O1 O0
            // T is time mark
            // O is optical readout
            data_in = (data_in << 1) | (MISO_READ() & 0x01);
            SCK_OFF();
        }
        databuf[word_index++] = data_in;
    }
    // Finishing off
    _SPI_DELAY(SPI_DELAY_CYCLES);
    CSN_ON();
    _SPI_DELAY(SPI_DELAY_CYCLES);
    return databuf;
}

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
#define MAX8614X_REG_S1_HRDAC1      0x2C
#define MAX8614X_REG_S2_HRDAC1      0x2D
#define MAX8614X_REG_S3_HRDAC1      0x2E
#define MAX8614X_REG_S4_HRDAC1      0x2F
#define MAX8614X_REG_S5_HRDAC1      0x30
#define MAX8614X_REG_S6_HRDAC1      0x31
// PPG2_HI_RES_DAC
#define MAX8614X_REG_S1_HRDAC2      0x32
#define MAX8614X_REG_S2_HRDAC2      0x33
#define MAX8614X_REG_S3_HRDAC2      0x34
#define MAX8614X_REG_S4_HRDAC2      0x35
#define MAX8614X_REG_S5_HRDAC2      0x36
#define MAX8614X_REG_S6_HRDAC2      0x37
// Die Temperature
#define MAX8614X_REG_TEMP_CONFIG    0x40
#define MAX8614X_REG_TEMP_INTEGER   0x41
#define MAX8614X_REG_TEMP_FRACTION  0x42
// SHA256
#define MAX8614X_REG_SHA256_CMD     0xF0
#define MAX8614X_REG_SHA256_CONFIG  0xF1
// Memory
#define MAX8614X_REG_MEM_CONTROL    0xF2
#define MAX8614X_REG_MEM_INDEX      0xF3
#define MAX8614X_REG_MEM_DATA       0xF4
// Part ID
#define MAX8614X_REG_PART_ID        0xFF

// Bit masks and configurations
// MODE_CONFIG (0x0D)
#define MAX8614X_MODE_LP_MODE          (1 << 2)
#define MAX8614X_MODE_SHDN             (1 << 1)
#define MAX8614X_MODE_RESET            (1 << 0)
// FIFO Config
#define MAX8614X_FIFO_A_FULL_INT_EN    (1 << 7)
#define MAX8614X_FIFO_ROLL_OVER_EN     (1 << 1)
// PPG_CONFIG1 (0x11)
#define MAX8614X_PPG_ADC_RGE_16UA      (0x2 << 2)
#define MAX8614X_PPG_TINT_117US        (0x3)
// PPG_CONFIG2 (0x12)
#define MAX8614X_PPG_SR_25SPS          (0x00 << 3)
#define MAX8614X_PPG_SR_200SPS         (0x04 << 3)
// LED CONFIG
#define MAX8614X_LED_SETTLING_12US     (0x3 << 6)
// LED current range
#define MAX8614X_LED_RANGE_124MA       0x3
// LED drive current example
#define MAX8614X_LED_CURRENT_15mA      0x20

// INT_STATUS_1 bits
#define MAX8614X_INT1_A_FULL         (1 << 7)
#define MAX8614X_INT1_DATA_RDY       (1 << 6)
// FIFO_CFG2 bits (0x0A)
#define MAX8614X_FIFO_FLUSH          (1 << 6)   // FLUSH_FIFO (self-clearing)
#define MAX8614X_FIFO_STAT_CLR       (1 << 5)   // FIFO_STAT_CLR

void max86140_init (void) {
    // Initialization sequence for MAX86140
    // For testing purposes only
    max86140_spi_write(MAX8614X_REG_MODE_CONFIG, MAX8614X_MODE_RESET);
    k_sleep(K_MSEC(1));
    // Clear Interrupts
    max86140_spi_read(MAX8614X_REG_INT_STATUS_1);
    max86140_spi_read(MAX8614X_REG_INT_STATUS_2);
    // Enter Shutdown mode to configure
    max86140_spi_write(MAX8614X_REG_MODE_CONFIG, MAX8614X_MODE_SHDN);
    // -------------------------------
    // PPG Analog Configuration
    // -------------------------------
    // ADC Range = 16 uA, Integration Time = 117.3 us
    max86140_spi_write(MAX8614X_REG_PPG_CONFIG1, 0b00001111);
    // Sample Rate = 25 SPS
    max86140_spi_write(MAX8614X_REG_PPG_CONFIG2, MAX8614X_PPG_SR_200SPS);
    // LED Settling Time = 12 us
    max86140_spi_write(MAX8614X_REG_LED_CONFIG, MAX8614X_LED_SETTLING_12US);
    // Photodiode Bias = 0~65 pF
    max86140_spi_write(MAX8614X_REG_PD_BIAS, 0x01);
    // LED Current Range = 124 mA, LED1 = 15 mA, LED2 = 15 mA
    max86140_spi_write(MAX8614X_REG_LED_CONFIG, MAX8614X_LED_RANGE_124MA);
    max86140_spi_write(MAX8614X_REG_LED1_PA, MAX8614X_LED_CURRENT_15mA);
    max86140_spi_write(MAX8614X_REG_LED2_PA, MAX8614X_LED_CURRENT_15mA);
    // -------------------------------
    // FIFO Configuration
    // -------------------------------
    // FIFO almost full threshold
    #define MAX8614X_FIFO_A_FULL 0x10
    max86140_spi_write(MAX8614X_REG_FIFO_CFG1, MAX8614X_FIFO_A_FULL);
    // Enable FIFO roll over
    // max86140_spi_write(MAX8614X_REG_FIFO_CFG2, MAX8614X_FIFO_ROLL_OVER_EN);
    // Enable FIFO interrupt
    // _max86140_set_bits(MAX8614X_REG_INT_ENABLE_1, MAX8614X_FIFO_A_FULL_INT_EN);
    // -------------------------------
    // LED Sequence Configuration
    // -------------------------------
    // LED1 -> LED2 -> off
    max86140_spi_write(MAX8614X_REG_LED_SEQ1, 0x12);
    max86140_spi_write(MAX8614X_REG_LED_SEQ2, 0x00);
    max86140_spi_write(MAX8614X_REG_LED_SEQ3, 0x00);
    // Start Sampling
    max86140_spi_write(MAX8614X_REG_MODE_CONFIG, 0x00);
}

#define MAX8614X_FIFO_SAMPLES (128-MAX8614X_FIFO_A_FULL)
uint32_t* max86140_device_data_read(uint32_t* dataBuf) {
    int i;
    uint8_t sample_count;
    sample_count = max86140_spi_read(MAX8614X_REG_FIFO_DATA_COUNT); // Should be equal to FIFO_SAMPLES
    // Start reading fifo
    max86140_spi_read_burst(dataBuf, MAX8614X_REG_FIFO_DATA, MAX8614X_FIFO_SAMPLES);
    return dataBuf;
}

// Read exactly ONE FIFO sample = 3 bytes.
// NOTE: Datasheet recommends "burst read three bytes" for an item; here we do
// three back-to-back reads of FIFO_DATA with no intervening register accesses.
uint32_t max86140_read_fifo_sample24(void) {
    uint8_t b0 = max86140_spi_read(MAX8614X_REG_FIFO_DATA);
    uint8_t b1 = max86140_spi_read(MAX8614X_REG_FIFO_DATA);
    uint8_t b2 = max86140_spi_read(MAX8614X_REG_FIFO_DATA);
    uint32_t raw24 = ((uint32_t)b0 << 16) |
                     ((uint32_t)b1 << 8) |
                     (uint32_t)b2;
    return raw24;
}

// Provide these in your platform layer
extern void delay_us(uint32_t us);
extern void store(uint16_t result);

// // Now written in main.c
// extern void al_transmit_data(uint32_t data);

// void max86140_single_sample_poll_and_store(void) {
//     // 1) Optional but recommended: clear sticky status and flush old FIFO data
//     // DATA_RDY clears on reading INT_STATUS_1 (0x00).
//     (void)max86140_spi_read(MAX8614X_REG_INT_STATUS_1);
//     // Flush FIFO to ensure we capture only the "new" sample we start now.
//     // FLUSH_FIFO is self-clearing.
//     _max86140_set_bits(MAX8614X_REG_FIFO_CFG2, MAX8614X_FIFO_FLUSH);
//     // 2) Start conversions: exit shutdown (SHDN=0)
//     // SHDN=1 is power-save; clearing it returns to normal sampling. :contentReference[oaicite:5]{index=5}
//     _max86140_clr_bits(MAX8614X_REG_MODE_CONFIG, MAX8614X_MODE_SHDN);

//     // 3) Wait for DATA_RDY (new FIFO data available)
//     // DATA_RDY is bit 6 in INT_STATUS_1. :contentReference[oaicite:6]{index=6}
//     // IMPORTANT: With BURST_EN=0, data appears at the PPG_SR cadence (continuous mode).
//     // If PPG_SR = 25sps, worst-case wait is ~40ms. If you truly need <=10ms, configure a faster PPG_SR.
//     uint32_t timeout_us = 60000; // 60ms guard
//     while (timeout_us--)
//     {
//         uint8_t st1 = max86140_spi_read(MAX8614X_REG_INT_STATUS_1);
//         if (st1 & MAX8614X_INT1_DATA_RDY) {
//             break;
//         }
//         k_sleep(K_USEC(1));
//     }
//     uint32_t raw24 = max86140_read_fifo_sample24();
//     al_transmit_data(raw24);
    
//     // Shutdown
//     _max86140_set_bits(MAX8614X_REG_MODE_CONFIG, MAX8614X_MODE_SHDN);
// }

uint8_t max86140_read_part_id(void) {
    return max86140_spi_read(MAX8614X_REG_PART_ID);
}

uint8_t max86140_check_full(void) {
    uint8_t st1 = max86140_spi_read(MAX8614X_REG_INT_STATUS_1);
    if (st1 & MAX8614X_INT1_A_FULL) {
        return 1;
    } else {
        return 0;
    }
}

uint8_t max86140_get_fifo_data_count(void) {
    return max86140_spi_read(MAX8614X_REG_FIFO_DATA_COUNT);
}

uint32_t* max86140_exhaust_fifo(uint32_t* dataBuf, uint8_t* sample_count_ptr) {
    uint8_t sample_count = max86140_spi_read(MAX8614X_REG_FIFO_DATA_COUNT);
    max86140_spi_read_burst(dataBuf, MAX8614X_REG_FIFO_DATA, sample_count);
    *sample_count_ptr = sample_count;
    return dataBuf;
}