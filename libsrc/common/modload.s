;*****************************************************************************/
;*                                                                           */
;*                                   modload.s                               */
;*                                                                           */
;*                    o65 module loader for the cc65 library                 */
;*                                                                           */
;*                                                                           */
;*                                                                           */
;* (C) 2002      Ullrich von Bassewitz                                       */
;*               Wacholderweg 14                                             */
;*               D-70597 Stuttgart                                           */
;* EMail:        uz@musoftware.de                                            */
;*                                                                           */
;*                                                                           */
;* This software is provided 'as-is', without any expressed or implied       */
;* warranty.  In no event will the authors be held liable for any damages    */
;* arising from the use of this software.                                    */
;*                                                                           */
;* Permission is granted to anyone to use this software for any purpose,     */
;* including commercial applications, and to alter it and redistribute it    */
;* freely, subject to the following restrictions:                            */
;*                                                                           */
;* 1. The origin of this software must not be misrepresented; you must not   */
;*    claim that you wrote the original software. If you use this software   */
;*    in a product, an acknowledgment in the product documentation would be  */
;*    appreciated but is not required.                                       */
;* 2. Altered source versions must be plainly marked as such, and must not   */
;*    be misrepresented as being the original software.                      */
;* 3. This notice may not be removed or altered from any source              */
;*    distribution.                                                          */
;*                                                                           */
;*****************************************************************************/



        .include        "o65.inc"
        .include        "modload.inc"

        .import         pushax, pusha0, push0, push1, decax1
        .import         _malloc, _free, _memset
        .import         __ZP_START__    ; Linker generated
        .importzp       sp, ptr1, tmp1, regbank

        .macpack        generic

;------------------------------------------------------------------------------
; Variables stored in the register bank in the zero page. Placing the variables
; here will protect them when calling other C functions.

Module          = regbank+0             ; Pointer to module memory
Ctrl            = regbank+2             ; Pointer to mod_ctrl structure
TPtr            = regbank+4             ; Pointer to module data for relocation

;------------------------------------------------------------------------------
; Static module data

.bss

; Save areas and error recovery data
Stack:          .byte   0               ; Old stackpointer
RegBankSave:    .res    6               ; Save area for register bank

; The header of the o65 file. Since we don't need the first 8 bytes any
; longer, once we've checked them, we will overlay them with other data to
; save a few bytes.
Header:         .res    O65_HDR_SIZE    ; The o65 header

; Input
InputByte       = Header                ; Byte read from input

; Stuff needed for relocation. Since the ld65 linker uses a relocation base
; address of zero for all segments, the relocation values needed are actually
; the start addresses of the segments. Among other things this means that the
; relocation value for the text segment is the same as the start address as
; the whole module block.
TextReloc       = Module                ; Relocation value for code seg
DataReloc       = Header + 1            ; Relocation value for data seg
BssReloc        = Header + 3            ; Relocation value for bss seg

.data
Read:           jmp     $FFFF           ; Jump to read routine

.rodata
ExpectedHdr:    .byte   $01, $00        ; non C64 marker
                .byte   $6F, $36, $35   ; Magic ("o65")
                .byte   $00             ; Version
                .word   $0000           ; Mode word
ExpectedHdrSize = * - ExpectedHdr


;------------------------------------------------------------------------------
; PushCtrl: Push the address of the control structure onto the C stack.

.code
PushCtrl:
        lda     Ctrl
        ldx     Ctrl+1
        jmp     pushax

;------------------------------------------------------------------------------
; LoadCtrl: Load a word from the control structure into a/x. The offset of the
;           high byte is passed in Y.

.code
LoadCtrl:
        lda     (Ctrl),y
        tax
        dey
        lda     (Ctrl),y
        rts

;------------------------------------------------------------------------------
; RestoreRegBank: Restore the register bank contents from the save area. Will
;                 destroy A and X (the latter will be zero on return).

.code
RestoreRegBank:
        ldx     #6
@L1:    lda     RegBankSave-1,x
        sta     regbank-1,x
        dex
        bne     @L1
        rts

;------------------------------------------------------------------------------
; GetReloc: Return a relocation value based on the segment in A

.code
GetReloc:
        cmp     #O65_SEGID_TEXT
        bne     @L1
        lda     TextReloc
        ldx     TextReloc+1
        rts

@L1:    cmp     #O65_SEGID_DATA
        bne     @L2
        lda     DataReloc
        ldx     DataReloc+1
        rts

@L2:    cmp     #O65_SEGID_BSS
        bne     @L3
        lda     BssReloc
        ldx     BssReloc+1
        rts

@L3:    cmp     #O65_SEGID_ZP
        bne     FormatError
        lda     #<__ZP_START__
        ldx     #>__ZP_START__
        rts

;------------------------------------------------------------------------------
; FormatError: Bail out with an o65 format error

FormatError:
        lda     #MLOAD_ERR_FMT
;       bne     CleanupAndExit          ; Branch always

;------------------------------------------------------------------------------
; CleanupAndExit: Free any allocated resources, restore the stack and return
;                 to the caller.

.code
CleanupAndExit:

; Restore the stack so we may return to the caller from here

        ldx     Stack
        txs

; Save the error return code

        pha

; Check if we have to free the allocated block

        lda     Module
        ora     Module+1
        beq     @L1                     ; Jump if no memory allocated

        lda     Module
        ldx     Module+1
        jsr     _free                   ; Free the allocated block

; Restore the register bank

@L1:    jsr     RestoreRegBank

; Restore the  error code and return to the caller

        ldx     #$00                    ; Load the high byte
        pla
        rts

;------------------------------------------------------------------------------
; ReadByte: Read one byte with error checking into InputByte and A.
; ReadAndCheckError: Call read with the current C stack and check for errors.

.code
ReadByte:

; C->read (C, &B, 1)

        jsr     PushCtrl
        lda     #<InputByte
        ldx     #>InputByte
        jsr     pushax
        jsr     push1

; This is a second entry point used by the other calls to Read

ReadAndCheckError:
        jsr     Read

; Check the return code and bail out in case of problems

        tax
        beq     @L1                     ; Jump if ok
        lda     #MLOAD_ERR_READ
        bne     CleanupAndExit

; Done

@L1:    lda     InputByte               ; If called ReadByte, load the byte read
Done:   rts

;------------------------------------------------------------------------------
; RelocSeg: Relocate the segment pointed to by a/x

.code
RelocSeg:
        jsr     decax1                  ; Start value is segment-1
        sta     TPtr
        stx     TPtr+1

Loop:   jsr     ReadByte                ; Read byte from relocation table
        beq     Done                    ; Bail out if end of table reached

        cmp     #255                    ; Special offset?
        bne     @L1

; Increment offset by 254 and continue

        lda     TPtr
        add     #254
        sta     TPtr
        bcc     Loop
        inc     TPtr+1
        jmp     Loop

; Increment offset by A

@L1:    add     TPtr
        sta     TPtr
        bcc     @L2
        inc     TPtr+1

; Read the relocation byte, extract the segment id, fetch the corresponding
; relocation value and place it into ptr1

@L2:    jsr     ReadByte
        and     #O65_SEGID_MASK
        jsr     GetReloc
        sta     ptr1
        stx     ptr1+1

; Get the relocation byte again, this time extract the relocation type.

        lda     InputByte
        and     #O65_RTYPE_MASK

; Check for and handle the different relocation types.

        cmp     #O65_RTYPE_WORD
        beq     RelocWord
        cmp     #O65_RTYPE_HIGH
        beq     RelocHigh
        cmp     #O65_RTYPE_LOW
        bne     FormatError

; Relocate the low byte

RelocLow:
        ldy     #0
        clc
        lda     (TPtr),y
        adc     ptr1
        sta     (TPtr),y
        jmp     Loop

; Relocate a high byte

RelocHigh:
        jsr     ReadByte                ; Read low byte from relocation table
        ldy     #0
        clc
        adc     ptr1                    ; We just need the carry
AddHigh:lda     (TPtr),y
        adc     ptr1+1
        sta     (TPtr),y
        jmp     Loop                    ; Done, next entry

; Relocate a word

RelocWord:
        ldy     #0
        clc
        lda     (TPtr),y
        adc     ptr1
        sta     (TPtr),y
        iny
        bne     AddHigh                 ; Branch always (add high byte)

;------------------------------------------------------------------------------
; mod_load: Load and relocate an o65 module

.code
_mod_load:

; Save the register bank and clear the Module pointer

        pha
        ldy     #6
@L1:    lda     regbank-1,y
        sta     RegBankSave-1,y
        dey
        bne     @L1
        sty     Module
        sty     Module+1
        pla

; Save the passed parameter

        sta     Ctrl
        stx     Ctrl+1

; Save the stack pointer so we can bail out even from subroutines

        tsx
        stx     Stack

; Get the read function pointer from the control structure and place it into
; our call vector

        ldy     #MODCTRL_READ+1
        jsr     LoadCtrl
        sta     Read+1
        stx     Read+2

; Read the o65 header: C->read (C, &H, sizeof (H))

        jsr     PushCtrl
        lda     #<Header
        ldx     #>Header
        jsr     pushax
        lda     #O65_HDR_SIZE
        jsr     pusha0                  ; Always less than 256
        jsr     ReadAndCheckError       ; Bails out in case of errors

; We read the o65 header successfully. Validate it.

        ldy     #ExpectedHdrSize-1
@L3:    lda     Header,y
        cmp     ExpectedHdr,y
        beq     @L4
        lda     #MLOAD_ERR_HDR
        jmp     CleanupAndExit
@L4:    dey
        bpl     @L3

; Header is ok as far as we can say now. Read and skip all options. We may
; add a check here for the OS option later.

Opt:    jsr     ReadByte
        beq     OptDone                 ; Jump if done
        sta     TPtr                    ; Use TPtr as a counter
OneOpt: dec     TPtr
        beq     Opt                     ; Next option
        jsr     ReadByte                ; Skip one byte
        jmp     OneOpt
OptDone:

; Skipped all options. Calculate the size of text+data and of text+data+bss
; (the latter is the size of the memory block we need). We will store the
; total module size also into the control structure for evaluation by the
; caller

        lda     Header + O65_HDR_TLEN
        add     Header + O65_HDR_DLEN
        sta     TPtr
        lda     Header + O65_HDR_TLEN + 1
        adc     Header + O65_HDR_DLEN + 1
        sta     TPtr+1
        lda     TPtr
        add     Header + O65_HDR_BLEN
        pha                             ; Save low byte of total size
        ldy     #MODCTRL_MODULE_SIZE
        sta     (Ctrl),y
        lda     TPtr+1
        adc     Header + O65_HDR_BLEN + 1
        iny
        sta     (Ctrl),y
        tax
        pla                             ; Restore low byte of total size

; Total memory size is now in a/x. Allocate memory, check if we got it.

        jsr     _malloc
        sta     Module
        stx     Module+1
        ora     Module+1
        bne     GotMem

; Could not allocate memory

        lda     #MLOAD_ERR_MEM
        jmp     CleanupAndExit

; We got the memory block. Setup the pointers and sizes in the control
; structure. We will use internal knowlege about the layout of the structure
; here to save some code.

GotMem: lda     Module                  ; Ctrl->module = Module;
        ldy     #MODCTRL_MODULE
        sta     (Ctrl),y
        ldy     #MODCTRL_CODE           ; Ctrl->code = Module;
        sta     (Ctrl),y
        txa
        iny
        sta     (Ctrl),y                ; MODCTRL_CODE+1
        ldy     #MODCTRL_MODULE+1
        sta     (Ctrl),y

; The following loop will also copy some information that is not needed just
; to save some code.

        ldx     #O65_HDR_TLEN
        ldy     #MODCTRL_CODE_SIZE
CLoop:  lda     Header,x
        sta     (Ctrl),y
        inx
        iny
        cpy     #MODCTRL_SIZE
        bne     CLoop

; Missing in the control structure now: start of the data and bss segments.
; Since the linker relocates all segments to zero, these addresses are also
; the relocation values for the segments.

        ldy     #MODCTRL_DATA
        lda     Module
        add     Header + O65_HDR_TLEN
        sta     (Ctrl),y
        sta     DataReloc
        iny
        lda     Module + 1
        adc     Header + O65_HDR_TLEN + 1
        sta     (Ctrl),y
        sta     DataReloc + 1

        ldy     #MODCTRL_BSS
        lda     Module
        add     TPtr
        sta     (Ctrl),y
        sta     BssReloc
        iny
        lda     Module+1
        add     TPtr+1
        sta     (Ctrl),y
        sta     BssReloc + 1

; Control structure is complete now. Load code and data segment into memory.
; The sum of the sizes of code+data segment is still in TPtr.
; C->read (C, C->module, H.tlen + H.dlen)

        jsr     PushCtrl
        lda     Module
        ldx     Module+1
        jsr     pushax
        lda     TPtr
        ldx     TPtr+1
        jsr     pushax
        jsr     ReadAndCheckError       ; Bails out in case of errors

; We've got the code and data segments in memory. Next section contains
; undefined references which we don't support. So check if the count of
; undefined references is actually zero.

        jsr     ReadByte
        bne     Undef
        jsr     ReadByte
        beq     Reloc
Undef:  jmp     FormatError

; Number of undefined references was zero. Next sections are the relocation
; tables for code and data segment. Relocate the code segment

Reloc:  lda     Module
        ldx     Module + 1              ; Code segment address
        jsr     RelocSeg

; Relocate the data segment

        ldy     #MODCTRL_DATA + 1
        jsr     LoadCtrl                ; Get data segment address
        jsr     RelocSeg

; Clear the bss segment

        ldy     #MODCTRL_BSS + 1
        jsr     LoadCtrl                ; Load bss segment address
        jsr     pushax
        jsr     push0
        lda     Header + O65_HDR_BLEN
        ldx     Header + O65_HDR_BLEN+1
        jsr     _memset                 ; memset (bss, 0, bss_size);

; We're done. Restore the register bank and return a success code

        jsr     RestoreRegBank          ; X will be zero on return
        lda     #MLOAD_OK
        rts

