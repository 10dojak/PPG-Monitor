// Software SPI implementation for MAX86140 sensor
// Anhang Li (anhangli@umich.edu)
// December 2025
//
// Updated July 2026 — Rutendo Jakachira (rutendo_jakachira@brown.edu):
// - Configured U10 ADC range (8192nA), integration time (58.7µs), LED drive currents and 6-slot sequencer  [Rutendo Jakachira, rutendo_jakachira@brown.edu]
// - Configured U2 LED drive currents and 3-slot mux sequencer for MAX4783 dual-package routing             [Rutendo Jakachira, rutendo_jakachira@brown.edu]

#ifndef _MAX86140_SPI_H_
#define _MAX86140_SPI_H_

#include <stdint.h>

// Software SPI — U10 (CSB1)
void      max86140_spi_init (void);
uint8_t   max86140_spi_read (uint8_t reg_addr);
void      max86140_spi_write(uint8_t reg_addr, uint8_t data);
uint32_t* max86140_spi_read_burst (uint32_t* databuf, uint8_t reg_addr, uint8_t length);
void      max86140_init (void);
uint32_t* max86140_device_data_read(uint32_t* dataBuf);
uint32_t  max86140_read_fifo_sample24(void);
void      max86140_single_sample_poll_and_store(void);
uint8_t   max86140_get_part_id(void);
uint8_t   max86140_read_part_id(void);
uint8_t   max86140_check_full(void);
uint8_t   max86140_get_fifo_data_count(void);
uint32_t* max86140_exhaust_fifo(uint32_t* dataBuf, uint8_t* sample_count_ptr);
void      max86140_log_tag_histogram(const uint32_t *buf, uint8_t count);

// U2 (CSB2) — secondary MAX86141 with MAX4783 mux control
void      max86141_u2_init(void);
uint32_t* max86141_u2_exhaust_fifo(uint32_t* dataBuf, uint8_t* sample_count_ptr);

#endif // _MAX86140_SPI_H_