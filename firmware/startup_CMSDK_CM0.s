                PRESERVE8
                THUMB

                AREA    RESET, DATA, READONLY
                EXPORT  __Vectors
                IMPORT  uart0_irq_handler

; P1: single 16KB BRAM (code+data). Stack top = 0x00004000 (RW region is
; 0x00003000-0x00003FFF). The official 0x20000000 points at unmapped space.
__Vectors        DCD     0x00004000                ; Top of Stack
                DCD     Reset_Handler             ; Reset Handler
                DCD     0			              ; NMI Handler
                DCD     0				          ; Hard Fault Handler
                DCD     0                         ; Reserved
                DCD     0                         ; Reserved
                DCD     0                         ; Reserved
                DCD     0                         ; Reserved
                DCD     0                         ; Reserved
                DCD     0                         ; Reserved
                DCD     0                         ; Reserved
                DCD     0			              ; SVCall Handler
                DCD     0                         ; Reserved
                DCD     0                         ; Reserved
                DCD     0            			  ; PendSV Handler
                DCD     0          				  ; SysTick Handler
                DCD     uart0_irq_handler         ; IRQ0 Handler (AHB UART)

                AREA    |.text|, CODE, READONLY

                IMPORT  __main

; Reset Handler: jump to C library startup (zero ZI, then call main)

Reset_Handler   PROC
                GLOBAL  Reset_Handler
				ENTRY
                B       __main
					ENDP

                END
