
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/host.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce_main():
       0:      	sub	sp, sp, #0x50
       4:      	stp	x22, x21, [sp, #0x20]
       8:      	stp	x20, x19, [sp, #0x30]
       c:      	stp	x29, x30, [sp, #0x40]
      10:      	ldr	x8, [x0, #0x70]
      14:      	ldr	x19, [x0]
      18:      	mov	x20, x0
      1c:      	cbz	x8, 0x12c <ltmp0+0x12c>
      20:      	mov	x0, x19
      24:      	blr	x8
      28:      	cmp	x0, #0x1
      2c:      	cset	w22, lt
      30:      	adrp	x0, 0x0 <ltmp0>
      34:      	add	x0, x0, #0x0
      38:      	mov	w1, #0x1                ; =1
      3c:      	bl	0x3c <ltmp0+0x3c>
      40:      	cbz	x0, 0x144 <ltmp0+0x144>
      44:      	ldp	x3, x4, [x20, #0x1b0]
      48:      	mov	x1, x19
      4c:      	ldp	x5, x6, [x20, #0x1c0]
      50:      	mov	x21, x0
      54:      	ldp	x8, x9, [x20, #0xf8]
      58:      	ldr	x2, [x20, #0xe0]
      5c:      	ldr	x7, [x20, #0x1d0]
      60:      	ldur	q0, [x20, #0xe8]
      64:      	stp	x8, x9, [sp, #0x10]
      68:      	str	q0, [sp]
      6c:      	bl	0x6c <ltmp0+0x6c>
      70:      	ldp	x2, x3, [x20, #0x180]
      74:      	mov	x0, x21
      78:      	ldp	x4, x5, [x20, #0x190]
      7c:      	mov	x1, x19
      80:      	ldr	x6, [x20, #0x1a0]
      84:      	bl	0x84 <ltmp0+0x84>
      88:      	ldp	x2, x3, [x20, #0x140]
      8c:      	mov	x0, x21
      90:      	ldp	x4, x5, [x20, #0x150]
      94:      	mov	x1, x19
      98:      	ldp	x6, x7, [x20, #0x160]
      9c:      	ldp	x8, x9, [x20, #0x170]
      a0:      	stp	x8, x9, [sp]
      a4:      	bl	0xa4 <ltmp0+0xa4>
      a8:      	cbnz	w22, 0x18c <ltmp0+0x18c>
      ac:      	ldr	x8, [x20, #0x8]
      b0:      	cbz	x8, 0x160 <ltmp0+0x160>
      b4:      	ldr	x0, [x20]
      b8:      	adrp	x1, 0x0 <ltmp0>
      bc:      	add	x1, x1, #0x0
      c0:      	mov	w2, #0x13               ; =19
      c4:      	blr	x8
      c8:      	cmn	w0, #0x1
      cc:      	b.eq	0x1a8 <ltmp0+0x1a8>
      d0:      	cmp	w0, #0x2
      d4:      	b.hs	0x160 <ltmp0+0x160>
      d8:      	mov	w1, wzr
      dc:      	mov	x0, x21
      e0:      	bl	0xe0 <ltmp0+0xe0>
      e4:      	mov	w22, w0
      e8:      	cmp	w0, #0x2
      ec:      	b.eq	0x10c <ltmp0+0x10c>
      f0:      	ldr	x20, [x20, #0x18]
      f4:      	cbz	x20, 0x10c <ltmp0+0x10c>
      f8:      	mov	x0, x21
      fc:      	bl	0xfc <ltmp0+0xfc>
     100:      	mov	x1, x0
     104:      	mov	x0, x19
     108:      	blr	x20
     10c:      	mov	x0, x21
     110:      	bl	0x110 <ltmp0+0x110>
     114:      	mov	w0, w22
     118:      	ldp	x29, x30, [sp, #0x40]
     11c:      	ldp	x20, x19, [sp, #0x30]
     120:      	ldp	x22, x21, [sp, #0x20]
     124:      	add	sp, sp, #0x50
     128:      	ret
     12c:      	mov	w22, wzr
     130:      	adrp	x0, 0x0 <ltmp0>
     134:      	add	x0, x0, #0x0
     138:      	mov	w1, #0x1                ; =1
     13c:      	bl	0x13c <ltmp0+0x13c>
     140:      	cbnz	x0, 0x44 <ltmp0+0x44>
     144:      	mov	w22, #0x2               ; =2
     148:      	mov	w0, w22
     14c:      	ldp	x29, x30, [sp, #0x40]
     150:      	ldp	x20, x19, [sp, #0x30]
     154:      	ldp	x22, x21, [sp, #0x20]
     158:      	add	sp, sp, #0x50
     15c:      	ret
     160:      	adrp	x2, 0x0 <ltmp0>
     164:      	add	x2, x2, #0x0
     168:      	mov	x0, x21
     16c:      	mov	w1, #0x9                ; =9
     170:      	mov	w3, #0x18               ; =24
     174:      	bl	0x174 <ltmp0+0x174>
     178:      	mov	x0, x21
     17c:      	mov	w1, wzr
     180:      	mov	w2, #0x1                ; =1
     184:      	bl	0x184 <ltmp0+0x184>
     188:      	b	0x1b0 <ltmp0+0x1b0>
     18c:      	adrp	x2, 0x0 <ltmp0>
     190:      	add	x2, x2, #0x0
     194:      	mov	x0, x21
     198:      	mov	w1, #0x6                ; =6
     19c:      	mov	w3, #0x13               ; =19
     1a0:      	bl	0x1a0 <ltmp0+0x1a0>
     1a4:      	b	0x1b0 <ltmp0+0x1b0>
     1a8:      	mov	x0, x21
     1ac:      	bl	0x1ac <ltmp0+0x1ac>
     1b0:      	ldr	x2, [x20, #0x10]
     1b4:      	mov	x0, x21
     1b8:      	mov	x1, x19
     1bc:      	bl	0x1bc <ltmp0+0x1bc>
     1c0:      	mov	w1, #0x1                ; =1
     1c4:      	mov	x0, x21
     1c8:      	bl	0x1c8 <ltmp0+0x1c8>
     1cc:      	mov	w22, w0
     1d0:      	cmp	w0, #0x2
     1d4:      	b.ne	0xf0 <ltmp0+0xf0>
     1d8:      	b	0x10c <ltmp0+0x10c>
