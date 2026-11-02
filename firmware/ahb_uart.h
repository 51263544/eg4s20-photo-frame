#ifndef AHB_UART_H
#define AHB_UART_H

#include <stdint.h>

#define UART_BASE      0x40000700UL

#define UART_DATA      (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_STATUS    (*(volatile uint32_t *)(UART_BASE + 0x04))
#define UART_BAUD      (*(volatile uint32_t *)(UART_BASE + 0x08))
#define UART_CTRL      (*(volatile uint32_t *)(UART_BASE + 0x0C))
#define UART_FIFO_CLR  (*(volatile uint32_t *)(UART_BASE + 0x10))

/* STATUS bits */
#define ST_RX_AVAIL    (1u << 0)
#define ST_TX_FULL     (1u << 1)
#define ST_TX_EMPTY    (1u << 2)
#define ST_RX_OVERRUN  (1u << 4)

/* CTRL bits */
#define CR_RX_IRQ_EN   (1u << 0)
#define CR_TX_IRQ_EN   (1u << 1)

/* baud = 25MHz / div (D-006); 115200 -> 217, 9600 -> 2604 */
#define UART_BAUD_115200  217u
#define UART_BAUD_9600    2604u

static inline void uart_init(uint32_t div)
{
    UART_FIFO_CLR = 1u;
    UART_BAUD = div;
    UART_CTRL = 0u;              /* polling mode */
}

static inline int uart_putc(int c)
{
    if (UART_STATUS & ST_TX_FULL)
        return -1;
    UART_DATA = (uint32_t)(c & 0xFF);
    return (int)(c & 0xFF);
}

static inline int uart_getc(void)
{
    if (!(UART_STATUS & ST_RX_AVAIL))
        return -1;
    return (int)(UART_DATA & 0xFF);
}

static inline void uart_putc_blocking(int c)
{
    while (UART_STATUS & ST_TX_FULL)
        ;
    UART_DATA = (uint32_t)(c & 0xFF);
}

static inline void uart_puts(const char *s)
{
    while (*s)
        uart_putc_blocking(*s++);
}

#endif /* AHB_UART_H */
