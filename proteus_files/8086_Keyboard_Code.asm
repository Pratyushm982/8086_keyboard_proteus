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

    ; --- MODIFIED: Keymap expanded for 7x6 (42 keys) ---
    KEYMAP DB 'A','B','C','D','E','F','G','H','I','J','K','L','M', \
            'N','O','P','Q','R','S','T','U','V','W','X','Y','Z', \
            '0','1','2','3','4','5','6','7','8','9', \
            08h, 0Dh, ' ', 0Ch, 01h, 02h ; Row 6: BS, ENTER, SPACE, CLR, LEFT, RIGHT
    ; Key 36 (6,0) = 08h (Backspace)
    ; Key 37 (6,1) = 0Dh (Enter)
    ; Key 38 (6,2) = 20h (Space)
    ; Key 39 (6,3) = 0Ch (Clear Screen)
    ; Key 40 (6,4) = 01h (Cursor Left)
    ; Key 41 (6,5) = 02h (Cursor Right)

    ; masks used to avoid MASM immediate/byte quirks
    MASK_HIGH DB 0F0h
    MASK_LOW  DB 0Fh
    MASK_E_SET DB 20h 
    MASK_RS_SET DB 10h
    
    ; temporary single-byte for safe masking
    TMP_MASK DB 0

    Q_SIZE      EQU 16
    KEY_QUEUE DB Q_SIZE DUP(0)
    Q_HEAD      DB 0
    Q_TAIL      DB 0
    CURSOR_POS DB 0
    GREET_MSG  DB 'START', 0  
    IS_FIRST_KEY DB 1 ; 1=yes, 0=no
    
    ; 32-byte buffer to hold the screen contents
    SCREEN_BUFFER DB 32 DUP(' ') 
    
DATA    ENDS

STAK    SEGMENT PARA STACK 'STACK'
        DW 64 DUP(?) ; (Increased stack size)
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

    MOV DX, CONTROL8255
    MOV AL, 092h
    OUT DX, AL

    CALL LCD_INIT
    CALL PRINT_GREETING     ; <-- Print 'START'

    MOV AL, 013h
    OUT COMMAND8259, AL
    IN  AL, COMMAND8259
    MOV AL, 08h
    OUT DATA8259, AL
    IN  AL, DATA8259
    MOV AL, 01h
    OUT DATA8259, AL
    IN  AL, DATA8259
    MOV AL, 0FEh
    OUT DATA8259, AL
    STI

    ; --- IVT Setup (Needs ES=0) ---
    XOR AX, AX
    MOV ES, AX
    MOV WORD PTR ES:[8], OFFSET DUMMY_NMI
    MOV WORD PTR ES:[10], CS
    MOV WORD PTR ES:[8*4], OFFSET KEY_ISR
    MOV WORD PTR ES:[8*4+2], CS

    ; --- FIX: Restore ES to point to DATA segment ---
    MOV AX, DS
    MOV ES, AX

MAIN_LOOP:
    CALL PROCESS_QUEUE
    JMP MAIN_LOOP
START ENDP

; ==============================================
;  Keyboard ISR (MODIFIED FOR 7 ROWS)
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
    CMP BL, 7 ; (Check for 7 rows)
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

    ; key_index = row*6 + col
    MOV AL, [LATEST_ROW_DETECTED]
    MOV BL, 6
    MUL BL                  ; AX = row * 6
    ADD AL, [LATEST_COL_DETECTED] ; AL = (row*6)+col

    CMP AL, 41 ; (Check for 42 keys)
    JA  EXIT_ISR

    ; --- lookup KEYMAP[key_index] into AL ---
    LEA SI, KEYMAP          ; SI = base address of KEYMAP
    MOV BL, AL              ; BL = key_index (0..41)
    XOR BH, BH              ; Clear BH to use BX as index
    MOV AL, BYTE PTR [SI + BX]  ; AL = ascii char

    CMP AL, 0 ; (Ignore 00h keys)
    JE  EXIT_ISR

    ; push into circular queue if not full
    MOV DL, [Q_TAIL]        ; DL = tail
    MOV DH, DL
    INC DL
    CMP DL, Q_SIZE
    JB  NEXT_OK_ISR
    MOV DL, 0
NEXT_OK_ISR:
    CMP DL, [Q_HEAD]
    JE  QUEUE_FULL_ISR

    ; store AL into KEY_QUEUE[tail]
    LEA SI, KEY_QUEUE
    MOV BL, DH              ; BL = old tail
    XOR BH, BH
    ADD SI, BX
    MOV BYTE PTR [SI], AL
    MOV [Q_TAIL], DL

QUEUE_FULL_ISR:
EXIT_ISR:
    MOV AL, 020h
    OUT COMMAND8259, AL

    POP SI
    POP DX
    POP CX
    POP BX
    POP AX
    IRET
KEY_ISR ENDP

; ==============================================
;  Process Queue (HEAVILY MODIFIED FOR SPECIAL KEYS)
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

    ; SI = address of KEY_QUEUE + head
    LEA SI, KEY_QUEUE
    MOV BL, AL            ; BL = head index (0..15)
    XOR BH, BH
    ADD SI, BX
    MOV DL, BYTE PTR [SI]   ; DL = char

    ; advance head
    INC AL
    CMP AL, Q_SIZE
    JB  HEAD_OK
    MOV AL, 0
HEAD_OK:
    MOV [Q_HEAD], AL

    ; --- "FIRST KEY" LOGIC ---
    MOV CL, [IS_FIRST_KEY]
    CMP CL, 0
    JE  NOT_FIRST_KEY_MAIN 
    
    MOV BYTE PTR [IS_FIRST_KEY], 0 ; Clear the flag
    MOV AL, 001h
    CALL LCD_CMD            ; Clear screen
    LEA DI, SCREEN_BUFFER
    MOV AL, ' '
    MOV CX, 32
    REP STOSB
    MOV BYTE PTR [CURSOR_POS], 0 ; NOW reset cursor

NOT_FIRST_KEY_MAIN:
    ; --- DL still contains the char ---
    
    ; --- NEW: Branching logic for special keys ---
    CMP DL, 08h  ; Is it Backspace?
    JE  HANDLE_BACKSPACE
    
    CMP DL, 0Dh  ; Is it Enter?
    JE  HANDLE_ENTER
    
    ; --- NEW ---
    CMP DL, 0Ch  ; Is it Clear?
    JE  HANDLE_CLEAR
    
    CMP DL, 01h  ; Is it Cursor Left?
    JE  HANDLE_CURSOR_LEFT
    
    CMP DL, 02h  ; Is it Cursor Right?
    JE  HANDLE_CURSOR_RIGHT
    ; --- END NEW ---
    
    ; --- If not special, it's a printable char (like A, 1, or SPACE) ---
    JMP HANDLE_PRINTABLE

    ; ------------------------------------------------
    ; --- Path 1: Handle Backspace ---
    ; ------------------------------------------------
HANDLE_BACKSPACE:
    MOV CL, [CURSOR_POS]
    CMP CL, 0
    JE  KEY_PROCESSED       ; At pos 0, do nothing
    
    DEC CL                  ; Move cursor back
    MOV [CURSOR_POS], CL
    
    ; Write ' ' to buffer at new (decremented) position
    LEA SI, SCREEN_BUFFER
    XOR CH, CH              ; CX = CL
    ADD SI, CX
    MOV BYTE PTR [SI], ' '
    
    ; Set HW cursor to that pos
    MOV AL, CL
    CALL SET_HW_CURSOR
    
    ; Write ' ' to the actual LCD
    MOV AL, ' '
    CALL LCD_DATA
    
    ; Set HW cursor back again (so it blinks in the right place)
    MOV AL, CL
    CALL SET_HW_CURSOR
    
    JMP KEY_PROCESSED       ; Done
    
    ; ------------------------------------------------
    ; --- Path 2: Handle Enter ---
    ; ------------------------------------------------
HANDLE_ENTER:
    MOV CL, [CURSOR_POS]
    CMP CL, 16
    JAE ENTER_ON_L2         ; On line 2
    
ENTER_ON_L1:
    MOV CH, 16              ; Target is end of line 1
    JMP ENTER_FILL_LOOP
    
ENTER_ON_L2:
    MOV CH, 32              ; Target is end of line 2
    ; (Fall through to loop)

ENTER_FILL_LOOP:
    MOV CL, [CURSOR_POS]
    CMP CL, CH              ; Are we at the target (16 or 32)?
    JE  KEY_PROCESSED       ; Yes, all done.
    
    ; No, so "press" a space (DL = 20h)
    MOV DL, ' '
    
    ; --- This is the same logic as HANDLE_PRINTABLE ---
    ; --- We re-use it to add spaces one by one ---
    MOV CL, [CURSOR_POS]
    CMP CL, 32
    JNE NO_SCROLL_ENTER
    
    ; Scroll will happen
    CALL UPDATE_BUFFER_AND_SCROLL ; (DL is ' ')
    CALL LCD_REDRAW_ALL
    JMP ENTER_FILL_LOOP           ; Check again
    
NO_SCROLL_ENTER:
    ; Normal space print
    CALL UPDATE_BUFFER_AND_SCROLL ; (DL is ' ')
    MOV AL, [CURSOR_POS]
    DEC AL
    CALL SET_HW_CURSOR
    MOV AL, DL
    CALL LCD_DATA
    MOV AL, [CURSOR_POS]
    CMP AL, 32
    JE ENTER_FILL_LOOP
    CALL SET_HW_CURSOR
    
    JMP ENTER_FILL_LOOP           ; Check again

    ; ------------------------------------------------
    ; --- NEW Path: Handle Clear Screen ---
    ; ------------------------------------------------
HANDLE_CLEAR:
    MOV AL, 001h
    CALL LCD_CMD            ; Clear physical LCD

    ; Clear our screen buffer
    LEA DI, SCREEN_BUFFER
    MOV AL, ' '
    MOV CX, 32
    REP STOSB
    
    MOV BYTE PTR [CURSOR_POS], 0 ; Reset cursor
    JMP KEY_PROCESSED       ; Done

    ; ------------------------------------------------
    ; --- NEW Path: Handle Cursor Left ---
    ; ------------------------------------------------
HANDLE_CURSOR_LEFT:
    MOV CL, [CURSOR_POS]
    CMP CL, 0
    JE  KEY_PROCESSED       ; At pos 0, do nothing
    
    DEC CL                  ; Move cursor back
    MOV [CURSOR_POS], CL
    
    MOV AL, CL              ; AL = new position
    CALL SET_HW_CURSOR      ; Set physical cursor
    JMP KEY_PROCESSED       ; Done

    ; ------------------------------------------------
    ; --- NEW Path: Handle Cursor Right ---
    ; ------------------------------------------------
HANDLE_CURSOR_RIGHT:
    MOV CL, [CURSOR_POS]
    CMP CL, 32
    JE  KEY_PROCESSED       ; At end of buffer, do nothing
    
    INC CL                  ; Move cursor forward
    MOV [CURSOR_POS], CL

    MOV AL, CL              ; AL = new position
    CALL SET_HW_CURSOR      ; Set physical cursor
    JMP KEY_PROCESSED       ; Done

    ; ------------------------------------------------
    ; --- Path 4: Handle Normal Printable Key ---
    ; ------------------------------------------------
HANDLE_PRINTABLE:
    ; (This is the logic from the previous version)
    MOV CL, [CURSOR_POS]
    CMP CL, 32
    JNE NO_SCROLL_REDRAW
    
    ; --- YES, SCROLLING ---
    CALL UPDATE_BUFFER_AND_SCROLL ; (char in DL)
    CALL LCD_REDRAW_ALL           ; Redraw all (slow)
    JMP KEY_PROCESSED
    
NO_SCROLL_REDRAW:
    ; --- NORMAL KEY PRESS ---
    CALL UPDATE_BUFFER_AND_SCROLL ; (char in DL)
    
    MOV AL, [CURSOR_POS]
    DEC AL                      ; Get pos we just wrote to (0-31)
    CALL SET_HW_CURSOR          ; Set HW cursor to that pos
    
    MOV AL, DL                  ; Get char again
    CALL LCD_DATA               ; Write it
    
    MOV AL, [CURSOR_POS]
    CMP AL, 32
    JE KEY_PROCESSED
    CALL SET_HW_CURSOR
    
    ; --- All paths end here ---
KEY_PROCESSED:
    JMP NEXT_KEY                ; Look for next key in queue

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
;  Delay Helpers (No Change)
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
;  LCD Low-Level Routines (No Change)
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
    MOV AL, 028h  ; 4-bit, 2-line, 5x7
    CALL LCD_CMD
    MOV AL, 00Ch  ; Display on, cursor off, blink off
    CALL LCD_CMD
    MOV AL, 006h  ; Entry mode: increment, no shift
    CALL LCD_CMD
    MOV AL, 001h  ; Clear display
    CALL LCD_CMD
    POP AX
    RET
LCD_INIT ENDP

; ==============================================
;  BUFFER/SCROLLING FUNCTIONS (No Change)
; ==============================================
UPDATE_BUFFER_AND_SCROLL PROC NEAR
    PUSH AX
    PUSH CX
    PUSH SI
    PUSH DI
    MOV CL, [CURSOR_POS]
    CMP CL, 32  ; Is buffer full?
    JNE NO_SCROLL
    LEA SI, SCREEN_BUFFER + 16 ; Source: Line 2
    LEA DI, SCREEN_BUFFER      ; Dest: Line 1
    MOV CX, 16
    REP MOVSB
    LEA DI, SCREEN_BUFFER + 16 ; Dest: Line 2
    MOV AL, ' '
    MOV CX, 16
    REP STOSB
    MOV CL, 16
NO_SCROLL:
    LEA SI, SCREEN_BUFFER
    XOR CH, CH  ; Clear CH so CX = CL
    ADD SI, CX
    MOV BYTE PTR [SI], DL ; Put char in buffer
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
    MOV AL, [CURSOR_POS] ; (FIX from last time)
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

; ==============================================
;  Print Greeting String (No Change)
; ==============================================
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

; ==============================================
DUMMY_NMI PROC NEAR
    IRET
DUMMY_NMI ENDP

CODE ENDS
END START
