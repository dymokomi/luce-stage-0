
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/standard.o:	file format mach-o arm64

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
      1c:      	sub	sp, sp, #0x290
      20:      	mov	x19, sp
      24:      	ldr	x8, [x0, #0x70]
      28:      	ldr	x25, [x0]
      2c:      	mov	x27, x0
      30:      	cbz	x8, 0x5c <ltmp0+0x5c>
      34:      	mov	x0, x25
      38:      	blr	x8
      3c:      	mov	x24, x0
      40:      	adrp	x0, 0x0 <ltmp0>
      44:      	add	x0, x0, #0x0
      48:      	mov	w1, #0x2                ; =2
      4c:      	mov	w23, #0x2               ; =2
      50:      	bl	0x50 <ltmp0+0x50>
      54:      	cbnz	x0, 0x78 <ltmp0+0x78>
      58:      	b	0x534 <ltmp0+0x534>
      5c:      	mov	w24, #0x100             ; =256
      60:      	adrp	x0, 0x0 <ltmp0>
      64:      	add	x0, x0, #0x0
      68:      	mov	w1, #0x2                ; =2
      6c:      	mov	w23, #0x2               ; =2
      70:      	bl	0x70 <ltmp0+0x70>
      74:      	cbz	x0, 0x534 <ltmp0+0x534>
      78:      	ldp	x3, x4, [x27, #0x1b0]
      7c:      	mov	x22, x0
      80:      	ldp	x5, x6, [x27, #0x1c0]
      84:      	ldr	x2, [x27, #0xe0]
      88:      	ldp	x8, x9, [x27, #0xf8]
      8c:      	ldr	x7, [x27, #0x1d0]
      90:      	ldur	q0, [x27, #0xe8]
      94:      	sub	sp, sp, #0x20
      98:      	mov	x1, x25
      9c:      	stp	x8, x9, [sp, #0x10]
      a0:      	str	q0, [sp]
      a4:      	bl	0xa4 <ltmp0+0xa4>
      a8:      	add	sp, sp, #0x20
      ac:      	ldp	x2, x3, [x27, #0x180]
      b0:      	mov	x0, x22
      b4:      	ldp	x4, x5, [x27, #0x190]
      b8:      	mov	x1, x25
      bc:      	ldr	x6, [x27, #0x1a0]
      c0:      	bl	0xc0 <ltmp0+0xc0>
      c4:      	ldp	x8, x9, [x27, #0x170]
      c8:      	ldp	x2, x3, [x27, #0x140]
      cc:      	ldp	x4, x5, [x27, #0x150]
      d0:      	ldp	x6, x7, [x27, #0x160]
      d4:      	stp	x8, x9, [sp, #-0x10]!
      d8:      	mov	x0, x22
      dc:      	mov	x1, x25
      e0:      	bl	0xe0 <ltmp0+0xe0>
      e4:      	add	sp, sp, #0x10
      e8:      	cmp	x24, #0x0
      ec:      	b.le	0x628 <ltmp0+0x628>
      f0:      	sub	x28, sp, #0x20
      f4:      	mov	sp, x28
      f8:      	ldp	x2, x3, [x27, #0x20]
      fc:      	mov	x0, x22
     100:      	mov	x1, x25
     104:      	mov	x4, x28
     108:      	bl	0x108 <ltmp0+0x108>
     10c:      	cbnz	w0, 0x59c <ltmp0+0x59c>
     110:      	mov	w8, #0xff04             ; =65284
     114:      	mov	w9, #0x2                ; =2
     118:      	adrp	x26, 0x0 <ltmp0>
     11c:      	add	x26, x26, #0x0
     120:      	strh	w8, [x19, #0x128]
     124:      	strh	w8, [x19, #0xe0]
     128:      	strh	w8, [x19, #0xb0]
     12c:      	ldr	x8, [x28, #0x8]
     130:      	strb	w9, [x19, #0x110]
     134:      	mov	w9, #0x6                ; =6
     138:      	cmn	w8, #0x1
     13c:      	stp	x26, xzr, [x19, #0x130]
     140:      	str	xzr, [x19, #0x120]
     144:      	strb	w9, [x19, #0x80]
     148:      	str	xzr, [x19, #0x90]
     14c:      	strb	w9, [x19, #0x68]
     150:      	str	xzr, [x19, #0x78]
     154:      	strb	w9, [x19, #0x38]
     158:      	str	xzr, [x19, #0x48]
     15c:      	b.eq	0x644 <ltmp0+0x644>
     160:      	mov	w9, #0x70               ; =112
     164:      	ldr	x10, [x22, #0x60]
     168:      	umaddl	x9, w8, w9, x10
     16c:      	lsr	x8, x8, #32
     170:      	ldr	w10, [x9, #0x60]
     174:      	cmp	w10, w8
     178:      	b.ne	0x5e8 <ltmp0+0x5e8>
     17c:      	tbnz	w8, #0x0, 0x5e8 <ltmp0+0x5e8>
     180:      	ldr	x8, [x9, #0x10]
     184:      	add	x1, x19, #0x110
     188:      	add	x2, x19, #0xf8
     18c:      	mov	x0, x22
     190:      	str	x8, [x19, #0x118]
     194:      	bl	0x194 <ltmp0+0x194>
     198:      	cbnz	w0, 0x66c <ltmp0+0x66c>
     19c:      	add	x1, x19, #0xe0
     1a0:      	add	x2, x19, #0xc8
     1a4:      	mov	x0, x22
     1a8:      	stp	x26, xzr, [x19, #0xe8]
     1ac:      	bl	0x1ac <ltmp0+0x1ac>
     1b0:      	cbnz	w0, 0x67c <ltmp0+0x67c>
     1b4:      	adrp	x8, 0x0 <ltmp0>
     1b8:      	add	x8, x8, #0x0
     1bc:      	ldr	x20, [x19, #0xd0]
     1c0:      	mov	w9, #0x4                ; =4
     1c4:      	add	x1, x19, #0xb0
     1c8:      	add	x2, x19, #0x98
     1cc:      	mov	x0, x22
     1d0:      	stp	x8, x9, [x19, #0xb8]
     1d4:      	bl	0x1d4 <ltmp0+0x1d4>
     1d8:      	cbnz	w0, 0x68c <ltmp0+0x68c>
     1dc:      	add	x1, x19, #0x80
     1e0:      	add	x2, x19, #0x98
     1e4:      	mov	x0, x22
     1e8:      	str	x20, [x19, #0x88]
     1ec:      	bl	0x1ec <ltmp0+0x1ec>
     1f0:      	cbnz	w0, 0x69c <ltmp0+0x69c>
     1f4:      	add	x1, x19, #0x68
     1f8:      	add	x2, x19, #0xf8
     1fc:      	mov	x0, x22
     200:      	str	x20, [x19, #0x70]
     204:      	bl	0x204 <ltmp0+0x204>
     208:      	cbnz	w0, 0x6ac <ltmp0+0x6ac>
     20c:      	cmp	x24, #0x1
     210:      	b.eq	0x6bc <ltmp0+0x6bc>
     214:      	mov	w8, #0xff04             ; =65284
     218:      	mov	w9, #0x6                ; =6
     21c:      	sub	x1, x29, #0x98
     220:      	mov	x0, x22
     224:      	sturh	w8, [x29, #-0x80]
     228:      	stp	x26, xzr, [x29, #-0x78]
     22c:      	sturh	w8, [x29, #-0xc8]
     230:      	strb	w9, [x19, #0x1d0]
     234:      	str	xzr, [x19, #0x1e0]
     238:      	strb	w9, [x19, #0x188]
     23c:      	str	xzr, [x19, #0x198]
     240:      	strb	w9, [x19, #0x170]
     244:      	str	xzr, [x19, #0x180]
     248:      	strh	w8, [x19, #0x158]
     24c:      	strb	w9, [x19, #0x140]
     250:      	str	xzr, [x19, #0x150]
     254:      	bl	0x254 <ltmp0+0x254>
     258:      	cbnz	w0, 0x6d8 <ltmp0+0x6d8>
     25c:      	cmn	w20, #0x1
     260:      	b.eq	0x5c8 <ltmp0+0x5c8>
     264:      	mov	w8, w20
     268:      	lsr	x10, x20, #32
     26c:      	stp	x28, x27, [x19, #0x10]
     270:      	lsl	x8, x8, #7
     274:      	str	x20, [x19, #0x8]
     278:      	str	x10, [x19, #0x30]
     27c:      	sub	x9, x8, w20, uxtw #4
     280:      	ldr	x8, [x22, #0x60]
     284:      	add	x8, x8, x9
     288:      	stp	x25, x9, [x19, #0x20]
     28c:      	ldr	w9, [x8, #0x60]
     290:      	cmp	w9, w10
     294:      	b.ne	0x404 <ltmp0+0x404>
     298:      	ldr	x9, [x19, #0x30]
     29c:      	tbnz	w9, #0x0, 0x404 <ltmp0+0x404>
     2a0:      	ldr	x9, [x8, #0x10]
     2a4:      	ldur	x24, [x29, #-0x90]
     2a8:      	cmp	x9, #0x1
     2ac:      	b.lt	0x424 <ltmp0+0x424>
     2b0:      	ldr	x8, [x8]
     2b4:      	sub	x1, x29, #0x80
     2b8:      	sub	x2, x29, #0xb0
     2bc:      	mov	x0, x22
     2c0:      	ldp	x21, x23, [x8, #0x8]
     2c4:      	ldrb	w20, [x8, #0x1]
     2c8:      	add	x25, x8, #0x2
     2cc:      	bl	0x2cc <ltmp0+0x2cc>
     2d0:      	cmp	w20, #0xff
     2d4:      	sub	x1, x29, #0xc8
     2d8:      	sub	x2, x29, #0xe0
     2dc:      	csel	x8, x21, x25, eq
     2e0:      	csel	x9, x23, x20, eq
     2e4:      	mov	x0, x22
     2e8:      	stp	x8, x9, [x29, #-0xc0]
     2ec:      	bl	0x2ec <ltmp0+0x2ec>
     2f0:      	cbnz	w0, 0x558 <ltmp0+0x558>
     2f4:      	sub	x28, x29, #0xe0
     2f8:      	ldur	x8, [x29, #-0xd0]
     2fc:      	add	x1, x19, #0x140
     300:      	ldr	q0, [x28]
     304:      	sub	x2, x29, #0xe0
     308:      	mov	x0, x22
     30c:      	stur	x8, [x29, #-0x70]
     310:      	str	q0, [x28, #0x60]
     314:      	str	x24, [x19, #0x148]
     318:      	bl	0x318 <ltmp0+0x318>
     31c:      	cbnz	w0, 0x560 <ltmp0+0x560>
     320:      	ldp	x9, x10, [x19, #0x28]
     324:      	ldr	x8, [x22, #0x60]
     328:      	add	x8, x8, x9
     32c:      	ldr	w9, [x8, #0x60]
     330:      	cmp	w9, w10
     334:      	b.ne	0x404 <ltmp0+0x404>
     338:      	mov	x23, xzr
     33c:      	mov	x20, xzr
     340:      	ldr	x9, [x8, #0x10]
     344:      	add	x23, x23, #0x1
     348:      	cmp	x23, x9
     34c:      	b.ge	0x424 <ltmp0+0x424>
     350:      	ldr	x8, [x8]
     354:      	sub	x1, x29, #0x80
     358:      	sub	x2, x29, #0xb0
     35c:      	mov	x0, x22
     360:      	add	x25, x8, x20
     364:      	ldp	x26, x27, [x25, #0x20]
     368:      	ldrb	w21, [x25, #0x19]
     36c:      	bl	0x36c <ltmp0+0x36c>
     370:      	cmp	w21, #0xff
     374:      	add	x8, x25, #0x1a
     378:      	sub	x1, x29, #0xc8
     37c:      	csel	x8, x26, x8, eq
     380:      	csel	x9, x27, x21, eq
     384:      	sub	x2, x29, #0xe0
     388:      	mov	x0, x22
     38c:      	stp	x8, x9, [x29, #-0xc0]
     390:      	bl	0x390 <ltmp0+0x390>
     394:      	cbnz	w0, 0x558 <ltmp0+0x558>
     398:      	ldur	x8, [x29, #-0xd0]
     39c:      	ldr	q0, [x28]
     3a0:      	add	x1, x19, #0x170
     3a4:      	add	x2, x19, #0x158
     3a8:      	mov	x0, x22
     3ac:      	str	x24, [x19, #0x178]
     3b0:      	stur	x8, [x29, #-0x70]
     3b4:      	adrp	x8, 0x0 <ltmp0>
     3b8:      	add	x9, x8, #0x0
     3bc:      	mov	w8, #0x1                ; =1
     3c0:      	str	q0, [x28, #0x60]
     3c4:      	stp	x9, x8, [x19, #0x160]
     3c8:      	bl	0x3c8 <ltmp0+0x3c8>
     3cc:      	cbnz	w0, 0x568 <ltmp0+0x568>
     3d0:      	add	x1, x19, #0x140
     3d4:      	sub	x2, x29, #0xe0
     3d8:      	mov	x0, x22
     3dc:      	str	x24, [x19, #0x148]
     3e0:      	bl	0x3e0 <ltmp0+0x3e0>
     3e4:      	cbnz	w0, 0x560 <ltmp0+0x560>
     3e8:      	ldp	x9, x10, [x19, #0x28]
     3ec:      	add	x20, x20, #0x18
     3f0:      	ldr	x8, [x22, #0x60]
     3f4:      	add	x8, x8, x9
     3f8:      	ldr	w9, [x8, #0x60]
     3fc:      	cmp	w9, w10
     400:      	b.eq	0x340 <ltmp0+0x340>
     404:      	adrp	x2, 0x0 <ltmp0>
     408:      	add	x2, x2, #0x0
     40c:      	mov	x0, x22
     410:      	mov	w1, #0xd                ; =13
     414:      	mov	w3, #0x16               ; =22
     418:      	bl	0x418 <ltmp0+0x418>
     41c:      	mov	w2, #0x8                ; =8
     420:      	b	0x56c <ltmp0+0x56c>
     424:      	sub	x1, x29, #0x80
     428:      	sub	x2, x29, #0xf8
     42c:      	mov	x0, x22
     430:      	bl	0x430 <ltmp0+0x430>
     434:      	add	x1, x19, #0x1d0
     438:      	add	x2, x19, #0x1b8
     43c:      	mov	x0, x22
     440:      	str	x24, [x19, #0x1d8]
     444:      	bl	0x444 <ltmp0+0x444>
     448:      	ldp	x27, x25, [x19, #0x18]
     44c:      	ldr	x28, [x19, #0x10]
     450:      	cbnz	w0, 0x6e0 <ltmp0+0x6e0>
     454:      	add	x1, x19, #0x1b8
     458:      	add	x2, x19, #0x1a0
     45c:      	mov	x0, x22
     460:      	bl	0x460 <ltmp0+0x460>
     464:      	cbnz	w0, 0x6e8 <ltmp0+0x6e8>
     468:      	ldp	x21, x23, [x19, #0x1a8]
     46c:      	add	x1, x19, #0x188
     470:      	ldrb	w20, [x19, #0x1a1]
     474:      	mov	x0, x22
     478:      	str	x24, [x19, #0x190]
     47c:      	bl	0x47c <ltmp0+0x47c>
     480:      	cbnz	w0, 0x6f0 <ltmp0+0x6f0>
     484:      	add	x8, x19, #0x1a0
     488:      	cmp	w20, #0xff
     48c:      	mov	w9, #0xff04             ; =65284
     490:      	orr	x10, x8, #0x2
     494:      	ldr	x8, [x27, #0x8]
     498:      	csel	x2, x23, x20, eq
     49c:      	csel	x1, x21, x10, eq
     4a0:      	strh	w9, [x19, #0x128]
     4a4:      	stp	x1, x2, [x19, #0x130]
     4a8:      	cbz	x8, 0x600 <ltmp0+0x600>
     4ac:      	ldr	x0, [x27]
     4b0:      	blr	x8
     4b4:      	cmn	w0, #0x1
     4b8:      	b.eq	0x6f8 <ltmp0+0x6f8>
     4bc:      	cmp	w0, #0x2
     4c0:      	b.hs	0x600 <ltmp0+0x600>
     4c4:      	add	x1, x19, #0x128
     4c8:      	add	x2, x19, #0x50
     4cc:      	mov	x0, x22
     4d0:      	bl	0x4d0 <ltmp0+0x4d0>
     4d4:      	ldr	x8, [x19, #0x8]
     4d8:      	add	x1, x19, #0x38
     4dc:      	mov	x0, x22
     4e0:      	str	x8, [x19, #0x40]
     4e4:      	bl	0x4e4 <ltmp0+0x4e4>
     4e8:      	cbnz	w0, 0x704 <ltmp0+0x704>
     4ec:      	mov	x0, x22
     4f0:      	mov	x1, x28
     4f4:      	bl	0x4f4 <ltmp0+0x4f4>
     4f8:      	mov	w1, wzr
     4fc:      	mov	x0, x22
     500:      	bl	0x500 <ltmp0+0x500>
     504:      	mov	w23, w0
     508:      	cmp	w0, #0x2
     50c:      	b.eq	0x52c <ltmp0+0x52c>
     510:      	ldr	x20, [x27, #0x18]
     514:      	cbz	x20, 0x52c <ltmp0+0x52c>
     518:      	mov	x0, x22
     51c:      	bl	0x51c <ltmp0+0x51c>
     520:      	mov	x1, x0
     524:      	mov	x0, x25
     528:      	blr	x20
     52c:      	mov	x0, x22
     530:      	bl	0x530 <ltmp0+0x530>
     534:      	mov	w0, w23
     538:      	sub	sp, x29, #0x50
     53c:      	ldp	x29, x30, [sp, #0x50]
     540:      	ldp	x20, x19, [sp, #0x40]
     544:      	ldp	x22, x21, [sp, #0x30]
     548:      	ldp	x24, x23, [sp, #0x20]
     54c:      	ldp	x26, x25, [sp, #0x10]
     550:      	ldp	x28, x27, [sp], #0x60
     554:      	ret
     558:      	mov	w2, #0x14               ; =20
     55c:      	b	0x56c <ltmp0+0x56c>
     560:      	mov	w2, #0x20               ; =32
     564:      	b	0x56c <ltmp0+0x56c>
     568:      	mov	w2, #0x1c               ; =28
     56c:      	ldp	x27, x25, [x19, #0x18]
     570:      	ldr	x28, [x19, #0x10]
     574:      	mov	x0, x22
     578:      	mov	w1, #0x1                ; =1
     57c:      	bl	0x57c <ltmp0+0x57c>
     580:      	mov	x0, x22
     584:      	mov	w1, wzr
     588:      	mov	w2, #0xb                ; =11
     58c:      	bl	0x58c <ltmp0+0x58c>
     590:      	mov	x0, x22
     594:      	mov	x1, x28
     598:      	bl	0x598 <ltmp0+0x598>
     59c:      	ldr	x2, [x27, #0x10]
     5a0:      	mov	x0, x22
     5a4:      	mov	x1, x25
     5a8:      	bl	0x5a8 <ltmp0+0x5a8>
     5ac:      	mov	w1, #0x1                ; =1
     5b0:      	mov	x0, x22
     5b4:      	bl	0x5b4 <ltmp0+0x5b4>
     5b8:      	mov	w23, w0
     5bc:      	cmp	w0, #0x2
     5c0:      	b.ne	0x510 <ltmp0+0x510>
     5c4:      	b	0x52c <ltmp0+0x52c>
     5c8:      	adrp	x2, 0x0 <ltmp0>
     5cc:      	add	x2, x2, #0x0
     5d0:      	mov	x0, x22
     5d4:      	mov	w1, #0xe                ; =14
     5d8:      	mov	w3, #0x15               ; =21
     5dc:      	bl	0x5dc <ltmp0+0x5dc>
     5e0:      	mov	w2, #0x8                ; =8
     5e4:      	b	0x574 <ltmp0+0x574>
     5e8:      	adrp	x2, 0x0 <ltmp0>
     5ec:      	add	x2, x2, #0x0
     5f0:      	mov	x0, x22
     5f4:      	mov	w1, #0xd                ; =13
     5f8:      	mov	w3, #0x16               ; =22
     5fc:      	b	0x658 <ltmp0+0x658>
     600:      	adrp	x2, 0x0 <ltmp0>
     604:      	add	x2, x2, #0x0
     608:      	mov	x0, x22
     60c:      	mov	w1, #0x9                ; =9
     610:      	mov	w3, #0x18               ; =24
     614:      	bl	0x614 <ltmp0+0x614>
     618:      	mov	x0, x22
     61c:      	mov	w1, wzr
     620:      	mov	w2, #0xd                ; =13
     624:      	b	0x58c <ltmp0+0x58c>
     628:      	adrp	x2, 0x0 <ltmp0>
     62c:      	add	x2, x2, #0x0
     630:      	mov	x0, x22
     634:      	mov	w1, #0x6                ; =6
     638:      	mov	w3, #0x13               ; =19
     63c:      	bl	0x63c <ltmp0+0x63c>
     640:      	b	0x59c <ltmp0+0x59c>
     644:      	adrp	x2, 0x0 <ltmp0>
     648:      	add	x2, x2, #0x0
     64c:      	mov	x0, x22
     650:      	mov	w1, #0xe                ; =14
     654:      	mov	w3, #0x15               ; =21
     658:      	bl	0x658 <ltmp0+0x658>
     65c:      	mov	x0, x22
     660:      	mov	w1, wzr
     664:      	mov	w2, #0x2                ; =2
     668:      	b	0x58c <ltmp0+0x58c>
     66c:      	mov	x0, x22
     670:      	mov	w1, wzr
     674:      	mov	w2, #0x3                ; =3
     678:      	b	0x58c <ltmp0+0x58c>
     67c:      	mov	x0, x22
     680:      	mov	w1, wzr
     684:      	mov	w2, #0x4                ; =4
     688:      	b	0x58c <ltmp0+0x58c>
     68c:      	mov	x0, x22
     690:      	mov	w1, wzr
     694:      	mov	w2, #0x5                ; =5
     698:      	b	0x58c <ltmp0+0x58c>
     69c:      	mov	x0, x22
     6a0:      	mov	w1, wzr
     6a4:      	mov	w2, #0x6                ; =6
     6a8:      	b	0x58c <ltmp0+0x58c>
     6ac:      	mov	x0, x22
     6b0:      	mov	w1, wzr
     6b4:      	mov	w2, #0x7                ; =7
     6b8:      	b	0x58c <ltmp0+0x58c>
     6bc:      	adrp	x2, 0x0 <ltmp0>
     6c0:      	add	x2, x2, #0x0
     6c4:      	mov	x0, x22
     6c8:      	mov	w1, #0x6                ; =6
     6cc:      	mov	w3, #0x13               ; =19
     6d0:      	bl	0x6d0 <ltmp0+0x6d0>
     6d4:      	b	0x580 <ltmp0+0x580>
     6d8:      	mov	w2, wzr
     6dc:      	b	0x574 <ltmp0+0x574>
     6e0:      	mov	w2, #0x2b               ; =43
     6e4:      	b	0x574 <ltmp0+0x574>
     6e8:      	mov	w2, #0x2c               ; =44
     6ec:      	b	0x574 <ltmp0+0x574>
     6f0:      	mov	w2, #0x2e               ; =46
     6f4:      	b	0x574 <ltmp0+0x574>
     6f8:      	mov	x0, x22
     6fc:      	bl	0x6fc <ltmp0+0x6fc>
     700:      	b	0x590 <ltmp0+0x590>
     704:      	mov	x0, x22
     708:      	mov	w1, wzr
     70c:      	mov	w2, #0x12               ; =18
     710:      	b	0x58c <ltmp0+0x58c>
