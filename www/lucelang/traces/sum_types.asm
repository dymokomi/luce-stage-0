
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/sum_types.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce_main():
       0:      	stp	x24, x23, [sp, #-0x40]!
       4:      	stp	x22, x21, [sp, #0x10]
       8:      	stp	x20, x19, [sp, #0x20]
       c:      	stp	x29, x30, [sp, #0x30]
      10:      	add	x29, sp, #0x30
      14:      	sub	sp, sp, #0xd0
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
      4c:      	b	0x264 <ltmp0+0x264>
      50:      	mov	w23, #0x100             ; =256
      54:      	adrp	x0, 0x0 <ltmp0>
      58:      	add	x0, x0, #0x0
      5c:      	mov	w1, #0x2                ; =2
      60:      	mov	w22, #0x2               ; =2
      64:      	bl	0x64 <ltmp0+0x64>
      68:      	cbz	x0, 0x264 <ltmp0+0x264>
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
      e0:      	b.le	0x2e8 <ltmp0+0x2e8>
      e4:      	sub	x22, sp, #0x20
      e8:      	mov	sp, x22
      ec:      	ldp	x2, x3, [x20, #0x20]
      f0:      	mov	x0, x21
      f4:      	mov	x1, x19
      f8:      	mov	x4, x22
      fc:      	bl	0xfc <ltmp0+0xfc>
     100:      	cbnz	w0, 0x370 <ltmp0+0x370>
     104:      	ldr	x8, [x22, #0x8]
     108:      	mov	w9, #0x2                ; =2
     10c:      	stur	xzr, [x29, #-0x90]
     110:      	sturb	w9, [x29, #-0xa0]
     114:      	cmn	w8, #0x1
     118:      	sturb	w9, [x29, #-0x88]
     11c:      	stur	xzr, [x29, #-0x78]
     120:      	sturb	w9, [x29, #-0xd0]
     124:      	stur	xzr, [x29, #-0xc0]
     128:      	b.eq	0x304 <ltmp0+0x304>
     12c:      	mov	w9, #0x70               ; =112
     130:      	ldr	x10, [x21, #0x60]
     134:      	umaddl	x9, w8, w9, x10
     138:      	lsr	x8, x8, #32
     13c:      	ldr	w10, [x9, #0x60]
     140:      	cmp	w10, w8
     144:      	b.ne	0x2a8 <ltmp0+0x2a8>
     148:      	tbnz	w8, #0x0, 0x2a8 <ltmp0+0x2a8>
     14c:      	ldr	x8, [x9, #0x10]
     150:      	mov	w9, #0x1                ; =1
     154:      	sub	x1, x29, #0xa0
     158:      	sub	x3, x29, #0xb8
     15c:      	mov	x0, x21
     160:      	mov	w2, #0x2                ; =2
     164:      	stur	x9, [x29, #-0x98]
     168:      	stur	x8, [x29, #-0x80]
     16c:      	bl	0x16c <ltmp0+0x16c>
     170:      	cbnz	w0, 0x32c <ltmp0+0x32c>
     174:      	ldur	q0, [x29, #-0xb8]
     178:      	ldur	x8, [x29, #-0xa8]
     17c:      	cmp	x23, #0x1
     180:      	stur	q0, [x29, #-0x50]
     184:      	stur	x8, [x29, #-0x40]
     188:      	b.eq	0x33c <ltmp0+0x33c>
     18c:      	ldur	x8, [x29, #-0x48]
     190:      	ldr	x9, [x8, #0x8]
     194:      	cbz	x9, 0x280 <ltmp0+0x280>
     198:      	ldr	x8, [x8, #0x20]
     19c:      	sub	x1, x29, #0xd0
     1a0:      	sub	x2, x29, #0xe8
     1a4:      	mov	x0, x21
     1a8:      	stur	x8, [x29, #-0xc8]
     1ac:      	bl	0x1ac <ltmp0+0x1ac>
     1b0:      	cbnz	w0, 0x298 <ltmp0+0x298>
     1b4:      	ldp	x9, x10, [x29, #-0xe0]
     1b8:      	ldur	q0, [x29, #-0xe8]
     1bc:      	ldr	x8, [x20, #0x8]
     1c0:      	ldurb	w11, [x29, #-0xe7]
     1c4:      	stur	q0, [x29, #-0x70]
     1c8:      	stur	x10, [x29, #-0x60]
     1cc:      	cbz	x8, 0x2c0 <ltmp0+0x2c0>
     1d0:      	sub	x12, x29, #0xe8
     1d4:      	cmp	w11, #0xff
     1d8:      	ldr	x0, [x20]
     1dc:      	orr	x12, x12, #0x2
     1e0:      	csel	x2, x10, x11, eq
     1e4:      	csel	x1, x9, x12, eq
     1e8:      	blr	x8
     1ec:      	cmn	w0, #0x1
     1f0:      	b.eq	0x39c <ltmp0+0x39c>
     1f4:      	cmp	w0, #0x2
     1f8:      	b.hs	0x2c0 <ltmp0+0x2c0>
     1fc:      	sub	x1, x29, #0x70
     200:      	sub	x2, x29, #0x100
     204:      	mov	x0, x21
     208:      	bl	0x208 <ltmp0+0x208>
     20c:      	sub	x1, x29, #0xb8
     210:      	sub	x2, x29, #0x50
     214:      	mov	x0, x21
     218:      	bl	0x218 <ltmp0+0x218>
     21c:      	mov	x0, x21
     220:      	mov	x1, x22
     224:      	bl	0x224 <ltmp0+0x224>
     228:      	mov	w1, wzr
     22c:      	mov	x0, x21
     230:      	bl	0x230 <ltmp0+0x230>
     234:      	mov	w22, w0
     238:      	cmp	w0, #0x2
     23c:      	b.eq	0x25c <ltmp0+0x25c>
     240:      	ldr	x20, [x20, #0x18]
     244:      	cbz	x20, 0x25c <ltmp0+0x25c>
     248:      	mov	x0, x21
     24c:      	bl	0x24c <ltmp0+0x24c>
     250:      	mov	x1, x0
     254:      	mov	x0, x19
     258:      	blr	x20
     25c:      	mov	x0, x21
     260:      	bl	0x260 <ltmp0+0x260>
     264:      	mov	w0, w22
     268:      	sub	sp, x29, #0x30
     26c:      	ldp	x29, x30, [sp, #0x30]
     270:      	ldp	x20, x19, [sp, #0x20]
     274:      	ldp	x22, x21, [sp, #0x10]
     278:      	ldp	x24, x23, [sp], #0x40
     27c:      	ret
     280:      	sub	x1, x29, #0xd0
     284:      	sub	x2, x29, #0xe8
     288:      	mov	x0, x21
     28c:      	stur	xzr, [x29, #-0xc8]
     290:      	bl	0x290 <ltmp0+0x290>
     294:      	cbz	w0, 0x1b4 <ltmp0+0x1b4>
     298:      	mov	x0, x21
     29c:      	mov	w1, #0x1                ; =1
     2a0:      	mov	w2, #0x6                ; =6
     2a4:      	b	0x360 <ltmp0+0x360>
     2a8:      	adrp	x2, 0x0 <ltmp0>
     2ac:      	add	x2, x2, #0x0
     2b0:      	mov	x0, x21
     2b4:      	mov	w1, #0xd                ; =13
     2b8:      	mov	w3, #0x16               ; =22
     2bc:      	b	0x318 <ltmp0+0x318>
     2c0:      	adrp	x2, 0x0 <ltmp0>
     2c4:      	add	x2, x2, #0x0
     2c8:      	mov	x0, x21
     2cc:      	mov	w1, #0x9                ; =9
     2d0:      	mov	w3, #0x18               ; =24
     2d4:      	bl	0x2d4 <ltmp0+0x2d4>
     2d8:      	mov	x0, x21
     2dc:      	mov	w1, #0x1                ; =1
     2e0:      	mov	w2, #0x8                ; =8
     2e4:      	b	0x360 <ltmp0+0x360>
     2e8:      	adrp	x2, 0x0 <ltmp0>
     2ec:      	add	x2, x2, #0x0
     2f0:      	mov	x0, x21
     2f4:      	mov	w1, #0x6                ; =6
     2f8:      	mov	w3, #0x13               ; =19
     2fc:      	bl	0x2fc <ltmp0+0x2fc>
     300:      	b	0x370 <ltmp0+0x370>
     304:      	adrp	x2, 0x0 <ltmp0>
     308:      	add	x2, x2, #0x0
     30c:      	mov	x0, x21
     310:      	mov	w1, #0xe                ; =14
     314:      	mov	w3, #0x15               ; =21
     318:      	bl	0x318 <ltmp0+0x318>
     31c:      	mov	x0, x21
     320:      	mov	w1, #0x1                ; =1
     324:      	mov	w2, #0x1                ; =1
     328:      	b	0x360 <ltmp0+0x360>
     32c:      	mov	x0, x21
     330:      	mov	w1, #0x1                ; =1
     334:      	mov	w2, #0x2                ; =2
     338:      	b	0x360 <ltmp0+0x360>
     33c:      	adrp	x2, 0x0 <ltmp0>
     340:      	add	x2, x2, #0x0
     344:      	mov	x0, x21
     348:      	mov	w1, #0x6                ; =6
     34c:      	mov	w3, #0x13               ; =19
     350:      	bl	0x350 <ltmp0+0x350>
     354:      	mov	x0, x21
     358:      	mov	w1, #0x1                ; =1
     35c:      	mov	w2, #0x5                ; =5
     360:      	bl	0x360 <ltmp0+0x360>
     364:      	mov	x0, x21
     368:      	mov	x1, x22
     36c:      	bl	0x36c <ltmp0+0x36c>
     370:      	ldr	x2, [x20, #0x10]
     374:      	mov	x0, x21
     378:      	mov	x1, x19
     37c:      	bl	0x37c <ltmp0+0x37c>
     380:      	mov	w1, #0x1                ; =1
     384:      	mov	x0, x21
     388:      	bl	0x388 <ltmp0+0x388>
     38c:      	mov	w22, w0
     390:      	cmp	w0, #0x2
     394:      	b.ne	0x240 <ltmp0+0x240>
     398:      	b	0x25c <ltmp0+0x25c>
     39c:      	mov	x0, x21
     3a0:      	bl	0x3a0 <ltmp0+0x3a0>
     3a4:      	b	0x364 <ltmp0+0x364>
