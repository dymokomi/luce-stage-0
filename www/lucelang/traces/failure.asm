
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/failure.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce_main():
       0:      	stp	x24, x23, [sp, #-0x40]!
       4:      	stp	x22, x21, [sp, #0x10]
       8:      	stp	x20, x19, [sp, #0x20]
       c:      	stp	x29, x30, [sp, #0x30]
      10:      	add	x29, sp, #0x30
      14:      	sub	sp, sp, #0x70
      18:      	ldr	x8, [x0, #0x70]
      1c:      	ldr	x19, [x0]
      20:      	mov	x20, x0
      24:      	cbz	x8, 0x50 <ltmp0+0x50>
      28:      	mov	x0, x19
      2c:      	blr	x8
      30:      	mov	x23, x0
      34:      	adrp	x0, 0x0 <ltmp0>
      38:      	add	x0, x0, #0x0
      3c:      	mov	w1, #0x2                ; =2
      40:      	mov	w22, #0x2               ; =2
      44:      	bl	0x44 <ltmp0+0x44>
      48:      	cbnz	x0, 0x6c <ltmp0+0x6c>
      4c:      	b	0x220 <ltmp0+0x220>
      50:      	mov	w23, #0x100             ; =256
      54:      	adrp	x0, 0x0 <ltmp0>
      58:      	add	x0, x0, #0x0
      5c:      	mov	w1, #0x2                ; =2
      60:      	mov	w22, #0x2               ; =2
      64:      	bl	0x64 <ltmp0+0x64>
      68:      	cbz	x0, 0x220 <ltmp0+0x220>
      6c:      	ldp	x3, x4, [x20, #0x1b0]
      70:      	mov	x21, x0
      74:      	ldp	x5, x6, [x20, #0x1c0]
      78:      	ldr	x2, [x20, #0xe0]
      7c:      	ldp	x8, x9, [x20, #0xf8]
      80:      	ldr	x7, [x20, #0x1d0]
      84:      	ldur	q0, [x20, #0xe8]
      88:      	sub	sp, sp, #0x20
      8c:      	mov	x1, x19
      90:      	stp	x8, x9, [sp, #0x10]
      94:      	str	q0, [sp]
      98:      	bl	0x98 <ltmp0+0x98>
      9c:      	add	sp, sp, #0x20
      a0:      	ldp	x2, x3, [x20, #0x180]
      a4:      	mov	x0, x21
      a8:      	ldp	x4, x5, [x20, #0x190]
      ac:      	mov	x1, x19
      b0:      	ldr	x6, [x20, #0x1a0]
      b4:      	bl	0xb4 <ltmp0+0xb4>
      b8:      	ldp	x8, x9, [x20, #0x170]
      bc:      	ldp	x2, x3, [x20, #0x140]
      c0:      	ldp	x4, x5, [x20, #0x150]
      c4:      	ldp	x6, x7, [x20, #0x160]
      c8:      	stp	x8, x9, [sp, #-0x10]!
      cc:      	mov	x0, x21
      d0:      	mov	x1, x19
      d4:      	bl	0xd4 <ltmp0+0xd4>
      d8:      	add	sp, sp, #0x10
      dc:      	cmp	x23, #0x0
      e0:      	b.le	0x2d0 <ltmp0+0x2d0>
      e4:      	sub	x22, sp, #0x20
      e8:      	mov	sp, x22
      ec:      	ldp	x2, x3, [x20, #0x20]
      f0:      	mov	x0, x21
      f4:      	mov	x1, x19
      f8:      	mov	x4, x22
      fc:      	bl	0xfc <ltmp0+0xfc>
     100:      	cbnz	w0, 0x348 <ltmp0+0x348>
     104:      	ldr	x8, [x22, #0x8]
     108:      	mov	w9, #0x2                ; =2
     10c:      	stur	xzr, [x29, #-0x58]
     110:      	sturb	w9, [x29, #-0x68]
     114:      	cmn	w8, #0x1
     118:      	b.eq	0x2ec <ltmp0+0x2ec>
     11c:      	mov	w9, #0x70               ; =112
     120:      	ldr	x10, [x21, #0x60]
     124:      	umaddl	x9, w8, w9, x10
     128:      	lsr	x8, x8, #32
     12c:      	ldr	w10, [x9, #0x60]
     130:      	cmp	w10, w8
     134:      	b.ne	0x290 <ltmp0+0x290>
     138:      	tbnz	w8, #0x0, 0x290 <ltmp0+0x290>
     13c:      	cmp	x23, #0x1
     140:      	b.eq	0x314 <ltmp0+0x314>
     144:      	ldr	x8, [x9, #0x10]
     148:      	cbz	x8, 0x23c <ltmp0+0x23c>
     14c:      	mov	w9, #0x2a               ; =42
     150:      	cmp	x8, #0x0
     154:      	sdiv	x10, x9, x8
     158:      	mul	x11, x10, x8
     15c:      	ccmp	x11, x9, #0x4, mi
     160:      	cset	w8, ne
     164:      	sub	x8, x10, x8
     168:      	sub	x1, x29, #0x68
     16c:      	sub	x2, x29, #0x80
     170:      	mov	x0, x21
     174:      	stur	x8, [x29, #-0x60]
     178:      	bl	0x178 <ltmp0+0x178>
     17c:      	cbnz	w0, 0x280 <ltmp0+0x280>
     180:      	ldp	x9, x10, [x29, #-0x78]
     184:      	ldur	q0, [x29, #-0x80]
     188:      	ldr	x8, [x20, #0x8]
     18c:      	ldurb	w11, [x29, #-0x7f]
     190:      	stur	q0, [x29, #-0x50]
     194:      	stur	x10, [x29, #-0x40]
     198:      	cbz	x8, 0x2a8 <ltmp0+0x2a8>
     19c:      	sub	x12, x29, #0x80
     1a0:      	cmp	w11, #0xff
     1a4:      	ldr	x0, [x20]
     1a8:      	orr	x12, x12, #0x2
     1ac:      	csel	x2, x10, x11, eq
     1b0:      	csel	x1, x9, x12, eq
     1b4:      	blr	x8
     1b8:      	cmn	w0, #0x1
     1bc:      	b.eq	0x374 <ltmp0+0x374>
     1c0:      	cmp	w0, #0x2
     1c4:      	b.hs	0x2a8 <ltmp0+0x2a8>
     1c8:      	sub	x1, x29, #0x50
     1cc:      	sub	x2, x29, #0x98
     1d0:      	mov	x0, x21
     1d4:      	bl	0x1d4 <ltmp0+0x1d4>
     1d8:      	mov	x0, x21
     1dc:      	mov	x1, x22
     1e0:      	bl	0x1e0 <ltmp0+0x1e0>
     1e4:      	mov	w1, wzr
     1e8:      	mov	x0, x21
     1ec:      	bl	0x1ec <ltmp0+0x1ec>
     1f0:      	mov	w22, w0
     1f4:      	cmp	w0, #0x2
     1f8:      	b.eq	0x218 <ltmp0+0x218>
     1fc:      	ldr	x20, [x20, #0x18]
     200:      	cbz	x20, 0x218 <ltmp0+0x218>
     204:      	mov	x0, x21
     208:      	bl	0x208 <ltmp0+0x208>
     20c:      	mov	x1, x0
     210:      	mov	x0, x19
     214:      	blr	x20
     218:      	mov	x0, x21
     21c:      	bl	0x21c <ltmp0+0x21c>
     220:      	mov	w0, w22
     224:      	sub	sp, x29, #0x30
     228:      	ldp	x29, x30, [sp, #0x30]
     22c:      	ldp	x20, x19, [sp, #0x20]
     230:      	ldp	x22, x21, [sp, #0x10]
     234:      	ldp	x24, x23, [sp], #0x40
     238:      	ret
     23c:      	adrp	x2, 0x0 <ltmp0>
     240:      	add	x2, x2, #0x0
     244:      	mov	x0, x21
     248:      	mov	w1, #0x1                ; =1
     24c:      	mov	w3, #0x14               ; =20
     250:      	mov	w4, wzr
     254:      	mov	w5, #0x5                ; =5
     258:      	bl	0x258 <ltmp0+0x258>
     25c:      	mov	x0, x21
     260:      	bl	0x260 <ltmp0+0x260>
     264:      	mov	x8, #-0x1               ; =-1
     268:      	sub	x1, x29, #0x68
     26c:      	sub	x2, x29, #0x80
     270:      	mov	x0, x21
     274:      	stur	x8, [x29, #-0x60]
     278:      	bl	0x278 <ltmp0+0x278>
     27c:      	cbz	w0, 0x180 <ltmp0+0x180>
     280:      	mov	x0, x21
     284:      	mov	w1, #0x1                ; =1
     288:      	mov	w2, #0x11               ; =17
     28c:      	b	0x338 <ltmp0+0x338>
     290:      	adrp	x2, 0x0 <ltmp0>
     294:      	add	x2, x2, #0x0
     298:      	mov	x0, x21
     29c:      	mov	w1, #0xd                ; =13
     2a0:      	mov	w3, #0x16               ; =22
     2a4:      	b	0x300 <ltmp0+0x300>
     2a8:      	adrp	x2, 0x0 <ltmp0>
     2ac:      	add	x2, x2, #0x0
     2b0:      	mov	x0, x21
     2b4:      	mov	w1, #0x9                ; =9
     2b8:      	mov	w3, #0x18               ; =24
     2bc:      	bl	0x2bc <ltmp0+0x2bc>
     2c0:      	mov	x0, x21
     2c4:      	mov	w1, #0x1                ; =1
     2c8:      	mov	w2, #0x13               ; =19
     2cc:      	b	0x338 <ltmp0+0x338>
     2d0:      	adrp	x2, 0x0 <ltmp0>
     2d4:      	add	x2, x2, #0x0
     2d8:      	mov	x0, x21
     2dc:      	mov	w1, #0x6                ; =6
     2e0:      	mov	w3, #0x13               ; =19
     2e4:      	bl	0x2e4 <ltmp0+0x2e4>
     2e8:      	b	0x348 <ltmp0+0x348>
     2ec:      	adrp	x2, 0x0 <ltmp0>
     2f0:      	add	x2, x2, #0x0
     2f4:      	mov	x0, x21
     2f8:      	mov	w1, #0xe                ; =14
     2fc:      	mov	w3, #0x15               ; =21
     300:      	bl	0x300 <ltmp0+0x300>
     304:      	mov	x0, x21
     308:      	mov	w1, #0x1                ; =1
     30c:      	mov	w2, #0x2                ; =2
     310:      	b	0x338 <ltmp0+0x338>
     314:      	adrp	x2, 0x0 <ltmp0>
     318:      	add	x2, x2, #0x0
     31c:      	mov	x0, x21
     320:      	mov	w1, #0x6                ; =6
     324:      	mov	w3, #0x13               ; =19
     328:      	bl	0x328 <ltmp0+0x328>
     32c:      	mov	x0, x21
     330:      	mov	w1, #0x1                ; =1
     334:      	mov	w2, #0x3                ; =3
     338:      	bl	0x338 <ltmp0+0x338>
     33c:      	mov	x0, x21
     340:      	mov	x1, x22
     344:      	bl	0x344 <ltmp0+0x344>
     348:      	ldr	x2, [x20, #0x10]
     34c:      	mov	x0, x21
     350:      	mov	x1, x19
     354:      	bl	0x354 <ltmp0+0x354>
     358:      	mov	w1, #0x1                ; =1
     35c:      	mov	x0, x21
     360:      	bl	0x360 <ltmp0+0x360>
     364:      	mov	w22, w0
     368:      	cmp	w0, #0x2
     36c:      	b.ne	0x1fc <ltmp0+0x1fc>
     370:      	b	0x218 <ltmp0+0x218>
     374:      	mov	x0, x21
     378:      	bl	0x378 <ltmp0+0x378>
     37c:      	b	0x33c <ltmp0+0x33c>
