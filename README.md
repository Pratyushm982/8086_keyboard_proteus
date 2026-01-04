# 8086 Interrupt-Driven Keypad & LCD Terminal

## Table of Contents
1.  [Project Overview](#1-project-overview)
2.  [Hardware Architecture](#2-hardware-architecture)
    * [8255 PPI Interface](#21-8255-ppi-parallel-io-interface)
    * [7x6 Matrix Keypad](#22-7x6-matrix-keypad)
    * [16x2 LCD Display](#23-16x2-lcd-display)
3.  [Design Logic: Addressing & Banking](#3-design-logic-addressing--banking)
    * [Why Addresses 40, 42, 44?](#why-addresses-40-42-44-instead-of-40-41-42)
4.  [Device Configuration](#4-device-configuration)
    * [8255 Control Word](#41-8255-control-word-92h)
    * [8259 PIC Configuration](#42-8259-pic-configuration)
5.  [Software Architecture](#5-software-architecture)
6.  [Operation Flow](#6-operation-flow)
7.  [Source Code](#7-source-code)

---

## 1. Project Overview
This system implements a fully functional character entry terminal using an **8086 Microprocessor**. It interfaces a custom **7x6 Matrix Keypad** and a **16x2 LCD Display** to allow users to type, edit, and view text.

Unlike simple polling systems, this project utilizes an **Interrupt-Driven Architecture** via the **8259 PIC**. The CPU remains free to process data or idle until a key is physically pressed, ensuring high efficiency and zero missed keystrokes.

**Key Features:**
* **7x6 Matrix Support:** Handles 42 distinct keys including A-Z, 0-9, and special control keys.
* **Special Functions:** Supports **Backspace**, **Enter**, **Clear Screen**, and **Cursor Navigation** (Left/Right).
* **Circular Buffer:** Implements a software queue to decouple high-speed ISR execution from display rendering.
* **4-Bit LCD Mode:** Optimized wiring using nibble-swapping logic to save I/O pins.

---

## 2. Hardware Architecture



### 2.1 8255 PPI (Parallel I/O Interface)
The 8255 serves as the bridge between the CPU and the peripherals.
* **Base Address:** `0040h`
* **Port A (Input):** Connected to the **7 Row Lines** of the keypad.
* **Port B (Input):** Connected to the **6 Column Lines** of the keypad.
* **Port C (Output):** Connected to the **LCD Control & Data** lines.

### 2.2 7x6 Matrix Keypad


The keypad uses a cross-point switch matrix.
* **Rows 0-6:** Wired to Port A (PA0-PA6).
* **Cols 0-5:** Wired to Port B (PB0-PB5).
* **IRQ Logic:** An external OR-gate array monitors all row/column lines. If **any** key is pressed, it triggers a logic High signal to the 8259 IRQ0 pin.

### 2.3 16x2 LCD Display


The LCD is driven in **4-Bit Mode** to conserve 8255 pins.
* **Data (D4-D7):** Connected to Port C (PC0-PC3).
* **RS (Register Select):** Connected to Port C (PC4).
* **E (Enable):** Connected to Port C (PC5).

---

## 3. Design Logic: Addressing & Banking

### Why Addresses `40, 42, 44` instead of `40, 41, 42`?
A critical design choice was skipping odd addresses.

**The Technical Issue:**
The 8086 has a 16-bit data bus split into two 8-bit banks:
1.  **Lower Bank (D0-D7):** Active on **Even Addresses** (A0=0).
2.  **Upper Bank (D8-D15):** Active on **Odd Addresses** (A0=1).

**The Mismatch:**
Our peripherals (8255/8259) are **8-bit devices** wired physically to the **Lower Data Bus (D0-D7)**.
* If we accessed an **Odd Address** (e.g., `41h`), the CPU would activate the Upper Bank (D8-D15). Since our chip is wired to D0-D7, the CPU would miss the device entirely.
* By using only **Even Addresses** (`40h, 42h, 44h`), we force the CPU to always use the Lower Bank (D0-D7), ensuring correct communication.

**Address Folding:**
To support this in hardware, the address lines are shifted: `CPU A1` connects to `Chip A0`, and `CPU A2` connects to `Chip A1`.

---

## 4. Device Configuration

### 4.1 8255 Control Word: `92h`
**Value:** `1001 0010` (Binary)
* **Mode:** **Mode 0** (Basic I/O).
* **Port A (Input):** To read Keypad Rows.
* **Port B (Input):** To read Keypad Columns.
* **Port C (Output):** To drive LCD signals.

### 4.2 8259 PIC Configuration
* **Triggering (ICW1 = `13h`):** **Edge Triggered**. Ensures a single keypress generates only one interrupt.
* **Vector Mapping (ICW2 = `08h`):** Maps IRQ0 to **INT 08h** to avoid conflicts with Intel reserved interrupts.
* **Masking (OCW1 = `FEh`):** Only **IRQ0** is enabled; all other lines are masked to prevent noise.

---

## 5. Software Architecture

### 5.1 Interrupt Service Routine (ISR)
The `KEY_ISR` is the highest-priority task.
1.  **Reads Ports:** Captures the state of Port A (Rows) and Port B (Cols).
2.  **Decodes:** Calculates `Index = (Row * 6) + Col`.
3.  **Translates:** Uses a lookup table (`KEYMAP`) to convert the index into an ASCII character.
4.  **Queues:** Pushes the character into a circular buffer and returns immediately.

### 5.2 Main Loop
The `MAIN_LOOP` continuously checks the software queue.
* **Printable Keys:** Writes the character to the `SCREEN_BUFFER` and updates the LCD.
* **Special Keys:** Handles logic for Backspace, Enter, and Clear Screen.

---

## 6. Operation Flow

1.  **Standby:** CPU loops in `MAIN_LOOP`.
2.  **Action:** User presses 'A'. Keypad hardware sends a pulse to **8259 IRQ0**.
3.  **Interrupt:** 8259 asserts `INTR`. CPU pauses and jumps to `KEY_ISR`.
4.  **Capture:** ISR reads Port A & B, identifies 'A', pushes it to Queue, and returns (`IRET`).
5.  **Display:** Main loop wakes up, detects data in Queue, pops 'A', and sends it to the LCD.

---

## 7. Source Code

```assembly
; ==============================================
;  7x6 Keyboard -> A-Z, 0-9, BS, ENT, SP, CLR, <, >
;  ISR pushes ASCII to queue
;  Main loop processes keys
; ==============================================

CODE    SEGMENT PARA 'CODE'
        ASSUME CS:CODE, DS:DATA, SS:STAK

DATA    SEGMENT PARA 'DATA'
    LATEST_ROW_DETECTED DB ?
    LATEST_COL_DETECTED DB ?
    PORTAREAD  DB ?
    PORTBREAD  DB ?

    ; --- Keymap for 7x6 (42 keys) ---
    KEYMAP DB 'A','B','C','D','E','F','G','H','I','J','K','L','M', \
             'N','O','P','Q','R','S','T','U','V','W','X','Y','Z', \
             '0','1','2','3','4','5','6','7','8','9', \
             08h, 0Dh, ' ', 0Ch, 01h, 02h ; Row 6: BS, ENTER, SPACE, CLR, LEFT, RIGHT

    ; Masks
    MASK_HIGH   DB 0F0h
    MASK_LOW    DB 0Fh
    MASK_E_SET  DB 20h 
    MASK_RS_SET DB 10h
    
    ; Queue & Buffer
    Q_SIZE      EQU 16
    KEY_QUEUE   DB Q_SIZE DUP(0)
    Q_HEAD      DB 0
    Q_TAIL      DB 0
    
    CURSOR_POS  DB 0
    GREET_MSG   DB 'START', 0  
    IS_FIRST_KEY DB 1
    
    ; 32-byte buffer to hold screen contents
    SCREEN_BUFFER DB 32 DUP(' ') 
    
DATA    ENDS

STAK    SEGMENT PARA STACK 'STACK'
        DW 64 DUP(?) 
STAK    ENDS

PORTA       EQU 0040h
PORTB       EQU 0042h
PORTC       EQU 0044h
CONTROL8255 EQU 0046h
COMMAND8259 EQU 0020h
DATA8259    EQU 0022h

; ==============================================
START PROC
; ==============================================
    MOV AX, DATA
    MOV DS, AX

    ; Init 8255: Port A/B Input, Port C Output
    MOV DX, CONTROL8255
    MOV AL, 092h
    OUT DX, AL

    CALL LCD_INIT
    CALL PRINT_GREETING

    ; Init 8259
    MOV AL, 013h
    OUT COMMAND8259, AL
    IN  AL, COMMAND8259
    MOV AL, 08h
    OUT DATA8259, AL
    IN  AL, DATA8259
    MOV AL, 01h
    OUT DATA8259, AL
    IN  AL, DATA8259
    MOV AL, 0FEh  ; Unmask IRQ0 only
    OUT DATA8259, AL
    STI

    ; Setup IVT (Using ES temporary switch)
    XOR AX, AX
    MOV ES, AX
    MOV WORD PTR ES:[8], OFFSET DUMMY_NMI
    MOV WORD PTR ES:[10], CS
    MOV WORD PTR ES:[8*4], OFFSET KEY_ISR
    MOV WORD PTR ES:[8*4+2], CS

    MOV AX, DS
    MOV ES, AX

MAIN_LOOP:
    CALL PROCESS_QUEUE
    JMP MAIN_LOOP
START ENDP

; ==============================================
;  Keyboard ISR (7x6 Matrix)
; ==============================================
KEY_ISR PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI

    MOV DX, PORTA
    IN  AL, DX
    MOV [PORTAREAD], AL

    XOR BX, BX
FIND_ROW:
    TEST AL, 1
    JZ  FOUND_ROW
    INC BL
    SHR AL, 1
    CMP BL, 7
    JB  FIND_ROW
    JMP EXIT_ISR

FOUND_ROW:
    MOV [LATEST_ROW_DETECTED], BL
    MOV DX, PORTB
    IN  AL, DX
    MOV [PORTBREAD], AL

    XOR BX, BX
FIND_COL:
    TEST AL, 1
    JZ  FOUND_COL_OK
    INC BL
    SHR AL, 1
    CMP BL, 6
    JB  FIND_COL
    JMP EXIT_ISR

FOUND_COL_OK:
    MOV [LATEST_COL_DETECTED], BL

    ; Calculate Index = (Row * 6) + Col
    MOV AL, [LATEST_ROW_DETECTED]
    MOV BL, 6
    MUL BL                  
    ADD AL, [LATEST_COL_DETECTED] 

    CMP AL, 41 
    JA  EXIT_ISR

    LEA SI, KEYMAP          
    MOV BL, AL              
    XOR BH, BH              
    MOV AL, BYTE PTR [SI + BX] 

    CMP AL, 0 
    JE  EXIT_ISR

    ; Add to Circular Queue
    MOV DL, [Q_TAIL]        
    MOV DH, DL
    INC DL
    CMP DL, Q_SIZE
    JB  NEXT_OK_ISR
    MOV DL, 0
NEXT_OK_ISR:
    CMP DL, [Q_HEAD]
    JE  QUEUE_FULL_ISR

    LEA SI, KEY_QUEUE
    MOV BL, DH              
    XOR BH, BH
    ADD SI, BX
    MOV BYTE PTR [SI], AL
    MOV [Q_TAIL], DL

QUEUE_FULL_ISR:
EXIT_ISR:
    MOV AL, 020h ; EOI
    OUT COMMAND8259, AL

    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    IRET
KEY_ISR ENDP

; ==============================================
;  Process Queue (Logic Handler)
; ==============================================
PROCESS_QUEUE PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH DX
    PUSH SI
    PUSH DI

NEXT_KEY:
    MOV AL, [Q_HEAD]
    MOV BL, [Q_TAIL]
    CMP AL, BL
    JE  NO_KEYS

    LEA SI, KEY_QUEUE
    MOV BL, AL            
    XOR BH, BH
    ADD SI, BX
    MOV DL, BYTE PTR [SI]   

    INC AL
    CMP AL, Q_SIZE
    JB  HEAD_OK
    MOV AL, 0
HEAD_OK:
    MOV [Q_HEAD], AL

    ; Check First Key
    MOV CL, [IS_FIRST_KEY]
    CMP CL, 0
    JE  NOT_FIRST_KEY_MAIN 
    
    MOV BYTE PTR [IS_FIRST_KEY], 0 
    MOV AL, 001h
    CALL LCD_CMD            
    LEA DI, SCREEN_BUFFER
    MOV AL, ' '
    MOV CX, 32
    REP STOSB
    MOV BYTE PTR [CURSOR_POS], 0 

NOT_FIRST_KEY_MAIN:
    ; Special Key Handling
    CMP DL, 08h  
    JE  HANDLE_BACKSPACE
    CMP DL, 0Dh  
    JE  HANDLE_ENTER
    CMP DL, 0Ch  
    JE  HANDLE_CLEAR
    CMP DL, 01h  
    JE  HANDLE_CURSOR_LEFT
    CMP DL, 02h  
    JE  HANDLE_CURSOR_RIGHT
    
    JMP HANDLE_PRINTABLE

HANDLE_BACKSPACE:
    MOV CL, [CURSOR_POS]
    CMP CL, 0
    JE  KEY_PROCESSED        
    DEC CL                  
    MOV [CURSOR_POS], CL
    LEA SI, SCREEN_BUFFER
    XOR CH, CH              
    ADD SI, CX
    MOV BYTE PTR [SI], ' '
    MOV AL, CL
    CALL SET_HW_CURSOR
    MOV AL, ' '
    CALL LCD_DATA
    MOV AL, CL
    CALL SET_HW_CURSOR
    JMP KEY_PROCESSED       
    
HANDLE_ENTER:
    MOV CL, [CURSOR_POS]
    CMP CL, 16
    JAE ENTER_ON_L2         
ENTER_ON_L1:
    MOV CH, 16              
    JMP ENTER_FILL_LOOP
ENTER_ON_L2:
    MOV CH, 32              
ENTER_FILL_LOOP:
    MOV CL, [CURSOR_POS]
    CMP CL, CH              
    JE  KEY_PROCESSED       
    MOV DL, ' '
    
    MOV CL, [CURSOR_POS]
    CMP CL, 32
    JNE NO_SCROLL_ENTER
    CALL UPDATE_BUFFER_AND_SCROLL 
    CALL LCD_REDRAW_ALL
    JMP ENTER_FILL_LOOP            
NO_SCROLL_ENTER:
    CALL UPDATE_BUFFER_AND_SCROLL 
    MOV AL, [CURSOR_POS]
    DEC AL
    CALL SET_HW_CURSOR
    MOV AL, DL
    CALL LCD_DATA
    MOV AL, [CURSOR_POS]
    CMP AL, 32
    JE ENTER_FILL_LOOP
    CALL SET_HW_CURSOR
    JMP ENTER_FILL_LOOP            

HANDLE_CLEAR:
    MOV AL, 001h
    CALL LCD_CMD            
    LEA DI, SCREEN_BUFFER
    MOV AL, ' '
    MOV CX, 32
    REP STOSB
    MOV BYTE PTR [CURSOR_POS], 0 
    JMP KEY_PROCESSED       

HANDLE_CURSOR_LEFT:
    MOV CL, [CURSOR_POS]
    CMP CL, 0
    JE  KEY_PROCESSED        
    DEC CL                  
    MOV [CURSOR_POS], CL
    MOV AL, CL              
    CALL SET_HW_CURSOR      
    JMP KEY_PROCESSED       

HANDLE_CURSOR_RIGHT:
    MOV CL, [CURSOR_POS]
    CMP CL, 32
    JE  KEY_PROCESSED        
    INC CL                  
    MOV [CURSOR_POS], CL
    MOV AL, CL              
    CALL SET_HW_CURSOR      
    JMP KEY_PROCESSED       

HANDLE_PRINTABLE:
    MOV CL, [CURSOR_POS]
    CMP CL, 32
    JNE NO_SCROLL_REDRAW
    CALL UPDATE_BUFFER_AND_SCROLL 
    CALL LCD_REDRAW_ALL            
    JMP KEY_PROCESSED
    
NO_SCROLL_REDRAW:
    CALL UPDATE_BUFFER_AND_SCROLL 
    MOV AL, [CURSOR_POS]
    DEC AL                      
    CALL SET_HW_CURSOR          
    MOV AL, DL                  
    CALL LCD_DATA               
    MOV AL, [CURSOR_POS]
    CMP AL, 32
    JE KEY_PROCESSED
    CALL SET_HW_CURSOR
    
KEY_PROCESSED:
    JMP NEXT_KEY                

NO_KEYS:
    POP DI
    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    RET
PROCESS_QUEUE ENDP

; ==============================================
;  Delay Helpers
; ==============================================
DELAY_SHORT PROC NEAR
    PUSH CX
    MOV CX, 50
D1_LOOP:
    NOP
    NOP
    LOOP D1_LOOP
    POP CX
    RET
DELAY_SHORT ENDP

DELAY_2MS PROC NEAR
    PUSH CX
    MOV CX, 2000
D2_LOOP:
    NOP
    LOOP D2_LOOP
    POP CX
    RET
DELAY_2MS ENDP

DELAY_20MS PROC NEAR
    PUSH CX
    MOV CX, 20000
D3_LOOP:
    NOP
    LOOP D3_LOOP
    POP CX
    RET
DELAY_20MS ENDP

; ==============================================
;  LCD Routines
; ==============================================
LCD_PULSE_E PROC NEAR
    PUSH CX 
    PUSH DX
    MOV DX, PORTC
    OUT DX, AL
    MOV CL, BYTE PTR [MASK_E_SET]
    OR  AL, CL
    OUT DX, AL
    CALL DELAY_SHORT
    MOV CL, BYTE PTR [MASK_E_SET]
    XOR AL, CL
    OUT DX, AL
    CALL DELAY_SHORT
    POP DX
    POP CX
    RET
LCD_PULSE_E ENDP

LCD_WRITE PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX 
    PUSH DX
    MOV DL, AL
    MOV AL, DL
    MOV CL, BYTE PTR [MASK_HIGH]
    AND AL, CL
    MOV CL, 4
    SHR AL, CL
    CMP BH, 0
    JE  HW_NO_RS
    MOV CL, BYTE PTR [MASK_RS_SET]
    OR  AL, CL
HW_NO_RS:
    CALL LCD_PULSE_E
    MOV AL, DL
    MOV CL, BYTE PTR [MASK_LOW]
    AND AL, CL
    CMP BH, 0
    JE  LW_NO_RS
    MOV CL, BYTE PTR [MASK_RS_SET]
    OR  AL, CL
LW_NO_RS:
    CALL LCD_PULSE_E
    POP DX
    POP CX  
    POP BX
    POP AX
    RET
LCD_WRITE ENDP

LCD_CMD PROC NEAR
    PUSH AX
    PUSH BX
    MOV BH, 0
    CALL LCD_WRITE
    CALL DELAY_2MS
    POP BX
    POP AX
    RET
LCD_CMD ENDP

LCD_DATA PROC NEAR
    PUSH AX
    PUSH BX
    MOV BH, 1
    CALL LCD_WRITE
    CALL DELAY_SHORT
    POP BX
    POP AX
    RET
LCD_DATA ENDP

LCD_INIT PROC NEAR
    PUSH AX
    CALL DELAY_20MS
    MOV AL, 033h 
    MOV BH, 0
    CALL LCD_WRITE
    MOV AL, 032h
    MOV BH, 0
    CALL LCD_WRITE
    MOV AL, 028h  
    CALL LCD_CMD
    MOV AL, 00Ch  
    CALL LCD_CMD
    MOV AL, 006h  
    CALL LCD_CMD
    MOV AL, 001h  
    CALL LCD_CMD
    POP AX
    RET
LCD_INIT ENDP

; ==============================================
;  Buffer/Scroll Logic
; ==============================================
UPDATE_BUFFER_AND_SCROLL PROC NEAR
    PUSH AX
    PUSH CX
    PUSH SI
    PUSH DI
    MOV CL, [CURSOR_POS]
    CMP CL, 32  
    JNE NO_SCROLL
    LEA SI, SCREEN_BUFFER + 16 
    LEA DI, SCREEN_BUFFER      
    MOV CX, 16
    REP MOVSB
    LEA DI, SCREEN_BUFFER + 16 
    MOV AL, ' '
    MOV CX, 16
    REP STOSB
    MOV CL, 16
NO_SCROLL:
    LEA SI, SCREEN_BUFFER
    XOR CH, CH  
    ADD SI, CX
    MOV BYTE PTR [SI], DL 
    INC CL
    MOV [CURSOR_POS], CL
    POP DI
    POP SI
    POP CX
    POP AX
    RET
UPDATE_BUFFER_AND_SCROLL ENDP

LCD_REDRAW_ALL PROC NEAR
    PUSH AX
    PUSH BX
    PUSH CX
    PUSH SI
    MOV AL, 02h
    CALL LCD_CMD
    LEA SI, SCREEN_BUFFER
    MOV CX, 16
L1_LOOP:
    MOV AL, [SI]
    CALL LCD_DATA
    INC SI
    LOOP L1_LOOP
    MOV AL, 0C0h
    CALL LCD_CMD
    MOV CX, 16
L2_LOOP:
    MOV AL, [SI]
    CALL LCD_DATA
    INC SI
    LOOP L2_LOOP
    MOV AL, [CURSOR_POS] 
    CALL SET_HW_CURSOR
    POP SI
    POP CX
    POP BX
    POP AX
    RET
LCD_REDRAW_ALL ENDP

SET_HW_CURSOR PROC NEAR
    PUSH AX
    PUSH BX
    MOV BH, AL
    CMP AL, 16
    JNB CUR_ON_L2_B
CUR_ON_L1_B:
    ADD AL, 80h
    CALL LCD_CMD
    JMP CUR_DONE_B
CUR_ON_L2_B:
    SUB AL, 16
    ADD AL, 0C0h
    CALL LCD_CMD
CUR_DONE_B:
    MOV AL, BH
    POP BX
    POP AX
    RET
SET_HW_CURSOR ENDP

PRINT_GREETING PROC NEAR
    PUSH AX
    PUSH SI
    PUSH DX
    LEA SI, GREET_MSG
PRINT_LOOP:
    MOV AL, BYTE PTR [SI]
    CMP AL, 0
    JE  PRINT_DONE
    MOV DL, AL
    CALL UPDATE_BUFFER_AND_SCROLL
    INC SI
    JMP PRINT_LOOP
PRINT_DONE:
    CALL LCD_REDRAW_ALL
    POP DX
    POP SI
    POP AX
    RET
PRINT_GREETING ENDP

DUMMY_NMI PROC NEAR
    IRET
DUMMY_NMI ENDP

CODE ENDS
END START