
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/memory.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce_main():
       0:      	stp	x28, x27, [sp, #-0x60]!
       4:      	stp	x26, x25, [sp, #0x10]
       8:      	stp	x24, x23, [sp, #0x20]
       c:      	stp	x22, x21, [sp, #0x30]
      10:      	stp	x20, x19, [sp, #0x40]
      14:      	stp	x29, x30, [sp, #0x50]
      18:      	add	x29, sp, #0x50
      1c:      	sub	sp, sp, #0x140
      20:      	mov	x19, sp
      24:      	ldr	x8, [x0, #0x70]
      28:      	ldr	x20, [x0]
      2c:      	mov	x21, x0
      30:      	cbz	x8, 0x33c <ltmp0+0x33c>
      34:      	mov	x0, x20
      38:      	blr	x8
      3c:      	cmp	x0, #0x1
      40:      	cset	w23, lt
      44:      	adrp	x0, 0x0 <ltmp0>
      48:      	add	x0, x0, #0x0
      4c:      	mov	w1, #0x1                ; =1
      50:      	bl	0x50 <ltmp0+0x50>
      54:      	cbz	x0, 0x354 <ltmp0+0x354>
      58:      	ldp	x3, x4, [x21, #0x1b0]
      5c:      	mov	x22, x0
      60:      	ldp	x5, x6, [x21, #0x1c0]
      64:      	ldr	x2, [x21, #0xe0]
      68:      	ldp	x8, x9, [x21, #0xf8]
      6c:      	ldr	x7, [x21, #0x1d0]
      70:      	ldur	q0, [x21, #0xe8]
      74:      	sub	sp, sp, #0x20
      78:      	mov	x1, x20
      7c:      	stp	x8, x9, [sp, #0x10]
      80:      	str	q0, [sp]
      84:      	bl	0x84 <ltmp0+0x84>
      88:      	add	sp, sp, #0x20
      8c:      	ldp	x2, x3, [x21, #0x180]
      90:      	mov	x0, x22
      94:      	ldp	x4, x5, [x21, #0x190]
      98:      	mov	x1, x20
      9c:      	ldr	x6, [x21, #0x1a0]
      a0:      	bl	0xa0 <ltmp0+0xa0>
      a4:      	ldp	x8, x9, [x21, #0x170]
      a8:      	ldp	x2, x3, [x21, #0x140]
      ac:      	ldp	x4, x5, [x21, #0x150]
      b0:      	ldp	x6, x7, [x21, #0x160]
      b4:      	stp	x8, x9, [sp, #-0x10]!
      b8:      	mov	x0, x22
      bc:      	mov	x1, x20
      c0:      	bl	0xc0 <ltmp0+0xc0>
      c4:      	add	sp, sp, #0x10
      c8:      	cbnz	w23, 0x3b4 <ltmp0+0x3b4>
      cc:      	sub	x23, sp, #0x20
      d0:      	mov	sp, x23
      d4:      	ldp	x2, x3, [x21, #0x20]
      d8:      	mov	x0, x22
      dc:      	mov	x1, x20
      e0:      	mov	x4, x23
      e4:      	bl	0xe4 <ltmp0+0xe4>
      e8:      	cbnz	w0, 0x52c <ltmp0+0x52c>
      ec:      	mov	w8, #0xff04             ; =65284
      f0:      	mov	w9, #0x6                ; =6
      f4:      	stur	xzr, [x29, #-0x78]
      f8:      	sturh	w8, [x29, #-0x70]
      fc:      	adrp	x8, 0x0 <ltmp0>
     100:      	add	x8, x8, #0x0
     104:      	stp	x8, xzr, [x29, #-0x68]
     108:      	mov	w8, #0x2                ; =2
     10c:      	sturb	w8, [x29, #-0x88]
     110:      	strb	w8, [x19, #0xc0]
     114:      	strb	w8, [x19, #0x78]
     118:      	strb	w8, [x19, #0x60]
     11c:      	ldr	x8, [x23, #0x8]
     120:      	sturb	w9, [x29, #-0xb8]
     124:      	cmn	w8, #0x1
     128:      	stur	xzr, [x29, #-0xa8]
     12c:      	str	xzr, [x19, #0xd0]
     130:      	strb	w9, [x19, #0xa8]
     134:      	str	xzr, [x19, #0xb8]
     138:      	strb	w9, [x19, #0x90]
     13c:      	str	xzr, [x19, #0xa0]
     140:      	str	xzr, [x19, #0x88]
     144:      	str	xzr, [x19, #0x70]
     148:      	strb	w9, [x19, #0x18]
     14c:      	str	xzr, [x19, #0x28]
     150:      	strb	w9, [x19]
     154:      	str	xzr, [x19, #0x10]
     158:      	b.eq	0x3d0 <ltmp0+0x3d0>
     15c:      	mov	w9, #0x70               ; =112
     160:      	ldr	x10, [x22, #0x60]
     164:      	umaddl	x9, w8, w9, x10
     168:      	lsr	x8, x8, #32
     16c:      	ldr	w10, [x9, #0x60]
     170:      	cmp	w10, w8
     174:      	b.ne	0x35c <ltmp0+0x35c>
     178:      	tbnz	w8, #0x0, 0x35c <ltmp0+0x35c>
     17c:      	ldr	x27, [x9, #0x10]
     180:      	sub	x1, x29, #0x88
     184:      	sub	x2, x29, #0xa0
     188:      	mov	x0, x22
     18c:      	stur	xzr, [x29, #-0x80]
     190:      	bl	0x190 <ltmp0+0x190>
     194:      	cbnz	w0, 0x3f8 <ltmp0+0x3f8>
     198:      	ldur	x24, [x29, #-0x98]
     19c:      	cmn	w24, #0x1
     1a0:      	b.eq	0x408 <ltmp0+0x408>
     1a4:      	mov	w8, w24
     1a8:      	ldr	x9, [x22, #0x60]
     1ac:      	lsr	x26, x24, #32
     1b0:      	lsl	x8, x8, #7
     1b4:      	sub	x25, x8, w24, uxtw #4
     1b8:      	add	x8, x9, x25
     1bc:      	ldr	w9, [x8, #0x60]
     1c0:      	cmp	w9, w26
     1c4:      	b.ne	0x374 <ltmp0+0x374>
     1c8:      	tbnz	w26, #0x0, 0x374 <ltmp0+0x374>
     1cc:      	ldp	x11, x9, [x8, #0x8]
     1d0:      	add	x10, x9, #0x1
     1d4:      	cmp	x11, x10, lsl #3
     1d8:      	b.lo	0x430 <ltmp0+0x430>
     1dc:      	ldr	x11, [x8]
     1e0:      	str	x10, [x8, #0x10]
     1e4:      	str	x27, [x11, x9, lsl #3]
     1e8:      	add	x1, x19, #0xa8
     1ec:      	mov	x0, x22
     1f0:      	str	x24, [x19, #0xb0]
     1f4:      	bl	0x1f4 <ltmp0+0x1f4>
     1f8:      	cbnz	w0, 0x450 <ltmp0+0x450>
     1fc:      	ldr	x8, [x22, #0x60]
     200:      	add	x9, x8, x25
     204:      	ldr	w10, [x9, #0x60]
     208:      	cmp	w10, w26
     20c:      	b.ne	0x460 <ltmp0+0x460>
     210:      	ldp	x12, x10, [x9, #0x8]
     214:      	add	x11, x10, #0x1
     218:      	cmp	x12, x11, lsl #3
     21c:      	b.lo	0x488 <ltmp0+0x488>
     220:      	ldr	x12, [x9]
     224:      	mov	w13, #0x2a              ; =42
     228:      	str	x11, [x9, #0x10]
     22c:      	str	x13, [x12, x10, lsl #3]
     230:      	add	x8, x8, x25
     234:      	add	x1, x19, #0x60
     238:      	add	x2, x19, #0x48
     23c:      	ldr	x8, [x8, #0x10]
     240:      	mov	x0, x22
     244:      	str	x8, [x19, #0x68]
     248:      	bl	0x248 <ltmp0+0x248>
     24c:      	cbnz	w0, 0x4e4 <ltmp0+0x4e4>
     250:      	ldp	x9, x10, [x19, #0x50]
     254:      	ldur	q0, [x19, #0x48]
     258:      	ldr	x8, [x21, #0x8]
     25c:      	ldrb	w11, [x19, #0x49]
     260:      	stur	q0, [x29, #-0x70]
     264:      	stur	x10, [x29, #-0x60]
     268:      	cbz	x8, 0x38c <ltmp0+0x38c>
     26c:      	add	x12, x19, #0x48
     270:      	cmp	w11, #0xff
     274:      	ldr	x0, [x21]
     278:      	orr	x12, x12, #0x2
     27c:      	csel	x2, x10, x11, eq
     280:      	csel	x1, x9, x12, eq
     284:      	blr	x8
     288:      	cmn	w0, #0x1
     28c:      	b.eq	0x4f4 <ltmp0+0x4f4>
     290:      	cmp	w0, #0x2
     294:      	b.hs	0x38c <ltmp0+0x38c>
     298:      	sub	x1, x29, #0x70
     29c:      	add	x2, x19, #0x30
     2a0:      	mov	x0, x22
     2a4:      	bl	0x2a4 <ltmp0+0x2a4>
     2a8:      	add	x1, x19, #0x18
     2ac:      	mov	x0, x22
     2b0:      	str	x24, [x19, #0x20]
     2b4:      	bl	0x2b4 <ltmp0+0x2b4>
     2b8:      	cbnz	w0, 0x500 <ltmp0+0x500>
     2bc:      	add	x1, x19, #0x0
     2c0:      	mov	x0, x22
     2c4:      	str	x24, [x19, #0x8]
     2c8:      	bl	0x2c8 <ltmp0+0x2c8>
     2cc:      	cbnz	w0, 0x510 <ltmp0+0x510>
     2d0:      	mov	x0, x22
     2d4:      	mov	x1, x23
     2d8:      	bl	0x2d8 <ltmp0+0x2d8>
     2dc:      	mov	w1, wzr
     2e0:      	mov	x0, x22
     2e4:      	bl	0x2e4 <ltmp0+0x2e4>
     2e8:      	mov	w23, w0
     2ec:      	cmp	w0, #0x2
     2f0:      	b.eq	0x310 <ltmp0+0x310>
     2f4:      	ldr	x21, [x21, #0x18]
     2f8:      	cbz	x21, 0x310 <ltmp0+0x310>
     2fc:      	mov	x0, x22
     300:      	bl	0x300 <ltmp0+0x300>
     304:      	mov	x1, x0
     308:      	mov	x0, x20
     30c:      	blr	x21
     310:      	mov	x0, x22
     314:      	bl	0x314 <ltmp0+0x314>
     318:      	mov	w0, w23
     31c:      	sub	sp, x29, #0x50
     320:      	ldp	x29, x30, [sp, #0x50]
     324:      	ldp	x20, x19, [sp, #0x40]
     328:      	ldp	x22, x21, [sp, #0x30]
     32c:      	ldp	x24, x23, [sp, #0x20]
     330:      	ldp	x26, x25, [sp, #0x10]
     334:      	ldp	x28, x27, [sp], #0x60
     338:      	ret
     33c:      	mov	w23, wzr
     340:      	adrp	x0, 0x0 <ltmp0>
     344:      	add	x0, x0, #0x0
     348:      	mov	w1, #0x1                ; =1
     34c:      	bl	0x34c <ltmp0+0x34c>
     350:      	cbnz	x0, 0x58 <ltmp0+0x58>
     354:      	mov	w23, #0x2               ; =2
     358:      	b	0x318 <ltmp0+0x318>
     35c:      	adrp	x2, 0x0 <ltmp0>
     360:      	add	x2, x2, #0x0
     364:      	mov	x0, x22
     368:      	mov	w1, #0xd                ; =13
     36c:      	mov	w3, #0x16               ; =22
     370:      	b	0x3e4 <ltmp0+0x3e4>
     374:      	adrp	x2, 0x0 <ltmp0>
     378:      	add	x2, x2, #0x0
     37c:      	mov	x0, x22
     380:      	mov	w1, #0xd                ; =13
     384:      	mov	w3, #0x16               ; =22
     388:      	b	0x41c <ltmp0+0x41c>
     38c:      	adrp	x2, 0x0 <ltmp0>
     390:      	add	x2, x2, #0x0
     394:      	mov	x0, x22
     398:      	mov	w1, #0x9                ; =9
     39c:      	mov	w3, #0x18               ; =24
     3a0:      	bl	0x3a0 <ltmp0+0x3a0>
     3a4:      	mov	x0, x22
     3a8:      	mov	w1, wzr
     3ac:      	mov	w2, #0xf                ; =15
     3b0:      	b	0x51c <ltmp0+0x51c>
     3b4:      	adrp	x2, 0x0 <ltmp0>
     3b8:      	add	x2, x2, #0x0
     3bc:      	mov	x0, x22
     3c0:      	mov	w1, #0x6                ; =6
     3c4:      	mov	w3, #0x13               ; =19
     3c8:      	bl	0x3c8 <ltmp0+0x3c8>
     3cc:      	b	0x52c <ltmp0+0x52c>
     3d0:      	adrp	x2, 0x0 <ltmp0>
     3d4:      	add	x2, x2, #0x0
     3d8:      	mov	x0, x22
     3dc:      	mov	w1, #0xe                ; =14
     3e0:      	mov	w3, #0x15               ; =21
     3e4:      	bl	0x3e4 <ltmp0+0x3e4>
     3e8:      	mov	x0, x22
     3ec:      	mov	w1, wzr
     3f0:      	mov	w2, #0x1                ; =1
     3f4:      	b	0x51c <ltmp0+0x51c>
     3f8:      	mov	x0, x22
     3fc:      	mov	w1, wzr
     400:      	mov	w2, #0x2                ; =2
     404:      	b	0x51c <ltmp0+0x51c>
     408:      	adrp	x2, 0x0 <ltmp0>
     40c:      	add	x2, x2, #0x0
     410:      	mov	x0, x22
     414:      	mov	w1, #0xe                ; =14
     418:      	mov	w3, #0x15               ; =21
     41c:      	bl	0x41c <ltmp0+0x41c>
     420:      	mov	x0, x22
     424:      	mov	w1, wzr
     428:      	mov	w2, #0x3                ; =3
     42c:      	b	0x51c <ltmp0+0x51c>
     430:      	sub	x1, x29, #0xb8
     434:      	add	x2, x19, #0xc0
     438:      	mov	x0, x22
     43c:      	stur	x24, [x29, #-0xb0]
     440:      	str	x27, [x19, #0xc8]
     444:      	bl	0x444 <ltmp0+0x444>
     448:      	cbz	w0, 0x1e8 <ltmp0+0x1e8>
     44c:      	b	0x420 <ltmp0+0x420>
     450:      	mov	x0, x22
     454:      	mov	w1, wzr
     458:      	mov	w2, #0x6                ; =6
     45c:      	b	0x51c <ltmp0+0x51c>
     460:      	adrp	x2, 0x0 <ltmp0>
     464:      	add	x2, x2, #0x0
     468:      	mov	x0, x22
     46c:      	mov	w1, #0xd                ; =13
     470:      	mov	w3, #0x16               ; =22
     474:      	bl	0x474 <ltmp0+0x474>
     478:      	mov	x0, x22
     47c:      	mov	w1, wzr
     480:      	mov	w2, #0xa                ; =10
     484:      	b	0x51c <ltmp0+0x51c>
     488:      	mov	w8, #0x2a               ; =42
     48c:      	add	x1, x19, #0x90
     490:      	add	x2, x19, #0x78
     494:      	mov	x0, x22
     498:      	str	x24, [x19, #0x98]
     49c:      	str	x8, [x19, #0x80]
     4a0:      	bl	0x4a0 <ltmp0+0x4a0>
     4a4:      	cbnz	w0, 0x478 <ltmp0+0x478>
     4a8:      	ldr	x8, [x22, #0x60]
     4ac:      	add	x9, x8, x25
     4b0:      	ldr	w9, [x9, #0x60]
     4b4:      	cmp	w9, w26
     4b8:      	b.eq	0x230 <ltmp0+0x230>
     4bc:      	adrp	x2, 0x0 <ltmp0>
     4c0:      	add	x2, x2, #0x0
     4c4:      	mov	x0, x22
     4c8:      	mov	w1, #0xd                ; =13
     4cc:      	mov	w3, #0x16               ; =22
     4d0:      	bl	0x4d0 <ltmp0+0x4d0>
     4d4:      	mov	x0, x22
     4d8:      	mov	w1, wzr
     4dc:      	mov	w2, #0xc                ; =12
     4e0:      	b	0x51c <ltmp0+0x51c>
     4e4:      	mov	x0, x22
     4e8:      	mov	w1, wzr
     4ec:      	mov	w2, #0xd                ; =13
     4f0:      	b	0x51c <ltmp0+0x51c>
     4f4:      	mov	x0, x22
     4f8:      	bl	0x4f8 <ltmp0+0x4f8>
     4fc:      	b	0x520 <ltmp0+0x520>
     500:      	mov	x0, x22
     504:      	mov	w1, wzr
     508:      	mov	w2, #0x14               ; =20
     50c:      	b	0x51c <ltmp0+0x51c>
     510:      	mov	x0, x22
     514:      	mov	w1, wzr
     518:      	mov	w2, #0x16               ; =22
     51c:      	bl	0x51c <ltmp0+0x51c>
     520:      	mov	x0, x22
     524:      	mov	x1, x23
     528:      	bl	0x528 <ltmp0+0x528>
     52c:      	ldr	x2, [x21, #0x10]
     530:      	mov	x0, x22
     534:      	mov	x1, x20
     538:      	bl	0x538 <ltmp0+0x538>
     53c:      	mov	w1, #0x1                ; =1
     540:      	mov	x0, x22
     544:      	bl	0x544 <ltmp0+0x544>
     548:      	mov	w23, w0
     54c:      	cmp	w0, #0x2
     550:      	b.ne	0x2f4 <ltmp0+0x2f4>
     554:      	b	0x310 <ltmp0+0x310>
