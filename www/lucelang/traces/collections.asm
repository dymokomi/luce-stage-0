
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/collections.o:	file format mach-o arm64

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
      1c:      	sub	sp, sp, #0x170
      20:      	mov	x19, sp
      24:      	ldr	x8, [x0, #0x70]
      28:      	ldr	x20, [x0]
      2c:      	mov	x21, x0
      30:      	cbz	x8, 0x38c <ltmp0+0x38c>
      34:      	mov	x0, x20
      38:      	blr	x8
      3c:      	cmp	x0, #0x1
      40:      	cset	w23, lt
      44:      	adrp	x0, 0x0 <ltmp0>
      48:      	add	x0, x0, #0x0
      4c:      	mov	w1, #0x1                ; =1
      50:      	bl	0x50 <ltmp0+0x50>
      54:      	cbz	x0, 0x3a4 <ltmp0+0x3a4>
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
      c8:      	cbnz	w23, 0x404 <ltmp0+0x404>
      cc:      	sub	x23, sp, #0x20
      d0:      	mov	sp, x23
      d4:      	ldp	x2, x3, [x21, #0x20]
      d8:      	mov	x0, x22
      dc:      	mov	x1, x20
      e0:      	mov	x4, x23
      e4:      	bl	0xe4 <ltmp0+0xe4>
      e8:      	cbnz	w0, 0x628 <ltmp0+0x628>
      ec:      	mov	w8, #0xff04             ; =65284
      f0:      	mov	w9, #0x6                ; =6
      f4:      	stur	xzr, [x29, #-0x78]
      f8:      	sturh	w8, [x29, #-0x70]
      fc:      	adrp	x8, 0x0 <ltmp0>
     100:      	add	x8, x8, #0x0
     104:      	stp	x8, xzr, [x29, #-0x68]
     108:      	mov	w8, #0x2                ; =2
     10c:      	sturb	w8, [x29, #-0x88]
     110:      	sturb	w8, [x29, #-0xd0]
     114:      	strb	w8, [x19, #0xc0]
     118:      	strb	w8, [x19, #0x78]
     11c:      	strb	w8, [x19, #0x60]
     120:      	ldr	x8, [x23, #0x8]
     124:      	sturb	w9, [x29, #-0xb8]
     128:      	cmn	w8, #0x1
     12c:      	stur	xzr, [x29, #-0xa8]
     130:      	stur	xzr, [x29, #-0xc0]
     134:      	strb	w9, [x19, #0xd8]
     138:      	str	xzr, [x19, #0xe8]
     13c:      	str	xzr, [x19, #0xd0]
     140:      	strb	w9, [x19, #0xa8]
     144:      	str	xzr, [x19, #0xb8]
     148:      	strb	w9, [x19, #0x90]
     14c:      	str	xzr, [x19, #0xa0]
     150:      	str	xzr, [x19, #0x88]
     154:      	str	xzr, [x19, #0x70]
     158:      	strb	w9, [x19, #0x18]
     15c:      	str	xzr, [x19, #0x28]
     160:      	strb	w9, [x19]
     164:      	str	xzr, [x19, #0x10]
     168:      	b.eq	0x420 <ltmp0+0x420>
     16c:      	mov	w9, #0x70               ; =112
     170:      	ldr	x10, [x22, #0x60]
     174:      	umaddl	x9, w8, w9, x10
     178:      	lsr	x8, x8, #32
     17c:      	ldr	w10, [x9, #0x60]
     180:      	cmp	w10, w8
     184:      	b.ne	0x3ac <ltmp0+0x3ac>
     188:      	tbnz	w8, #0x0, 0x3ac <ltmp0+0x3ac>
     18c:      	ldr	x27, [x9, #0x10]
     190:      	sub	x1, x29, #0x88
     194:      	sub	x2, x29, #0xa0
     198:      	mov	x0, x22
     19c:      	stur	xzr, [x29, #-0x80]
     1a0:      	bl	0x1a0 <ltmp0+0x1a0>
     1a4:      	cbnz	w0, 0x448 <ltmp0+0x448>
     1a8:      	ldur	x24, [x29, #-0x98]
     1ac:      	cmn	w24, #0x1
     1b0:      	b.eq	0x458 <ltmp0+0x458>
     1b4:      	mov	w8, w24
     1b8:      	lsr	x26, x24, #32
     1bc:      	lsl	x9, x8, #7
     1c0:      	ldr	x8, [x22, #0x60]
     1c4:      	sub	x25, x9, w24, uxtw #4
     1c8:      	add	x9, x8, x25
     1cc:      	ldr	w10, [x9, #0x60]
     1d0:      	cmp	w10, w26
     1d4:      	b.ne	0x3c4 <ltmp0+0x3c4>
     1d8:      	tbnz	w26, #0x0, 0x3c4 <ltmp0+0x3c4>
     1dc:      	ldp	x12, x10, [x9, #0x8]
     1e0:      	add	x11, x10, #0x1
     1e4:      	cmp	x12, x11, lsl #3
     1e8:      	b.lo	0x480 <ltmp0+0x480>
     1ec:      	ldr	x12, [x9]
     1f0:      	str	x11, [x9, #0x10]
     1f4:      	str	x27, [x12, x10, lsl #3]
     1f8:      	add	x8, x8, x25
     1fc:      	ldp	x11, x9, [x8, #0x8]
     200:      	add	x10, x9, #0x1
     204:      	cmp	x11, x10, lsl #3
     208:      	b.lo	0x4d8 <ltmp0+0x4d8>
     20c:      	ldr	x11, [x8]
     210:      	mov	w12, #0x2               ; =2
     214:      	str	x10, [x8, #0x10]
     218:      	str	x12, [x11, x9, lsl #3]
     21c:      	add	x1, x19, #0xa8
     220:      	mov	x0, x22
     224:      	str	x24, [x19, #0xb0]
     228:      	bl	0x228 <ltmp0+0x228>
     22c:      	cbnz	w0, 0x4fc <ltmp0+0x4fc>
     230:      	ldr	x8, [x22, #0x60]
     234:      	add	x9, x8, x25
     238:      	ldr	w10, [x9, #0x60]
     23c:      	cmp	w10, w26
     240:      	b.ne	0x50c <ltmp0+0x50c>
     244:      	ldp	x12, x10, [x9, #0x8]
     248:      	add	x11, x10, #0x1
     24c:      	cmp	x12, x11, lsl #3
     250:      	b.lo	0x534 <ltmp0+0x534>
     254:      	ldr	x12, [x9]
     258:      	mov	w13, #0x3               ; =3
     25c:      	str	x11, [x9, #0x10]
     260:      	str	x13, [x12, x10, lsl #3]
     264:      	add	x8, x8, x25
     268:      	ldr	x10, [x8, #0x10]
     26c:      	subs	x9, x10, #0x1
     270:      	b.vs	0x590 <ltmp0+0x590>
     274:      	tbnz	x9, #0x3f, 0x5b8 <ltmp0+0x5b8>
     278:      	cmp	x9, x10
     27c:      	b.ge	0x5b8 <ltmp0+0x5b8>
     280:      	ldr	x8, [x8]
     284:      	add	x1, x19, #0x60
     288:      	add	x2, x19, #0x48
     28c:      	mov	x0, x22
     290:      	ldr	x8, [x8, x9, lsl #3]
     294:      	str	x8, [x19, #0x68]
     298:      	bl	0x298 <ltmp0+0x298>
     29c:      	cbnz	w0, 0x5e0 <ltmp0+0x5e0>
     2a0:      	ldp	x9, x10, [x19, #0x50]
     2a4:      	ldur	q0, [x19, #0x48]
     2a8:      	ldr	x8, [x21, #0x8]
     2ac:      	ldrb	w11, [x19, #0x49]
     2b0:      	stur	q0, [x29, #-0x70]
     2b4:      	stur	x10, [x29, #-0x60]
     2b8:      	cbz	x8, 0x3dc <ltmp0+0x3dc>
     2bc:      	add	x12, x19, #0x48
     2c0:      	cmp	w11, #0xff
     2c4:      	ldr	x0, [x21]
     2c8:      	orr	x12, x12, #0x2
     2cc:      	csel	x2, x10, x11, eq
     2d0:      	csel	x1, x9, x12, eq
     2d4:      	blr	x8
     2d8:      	cmn	w0, #0x1
     2dc:      	b.eq	0x5f0 <ltmp0+0x5f0>
     2e0:      	cmp	w0, #0x2
     2e4:      	b.hs	0x3dc <ltmp0+0x3dc>
     2e8:      	sub	x1, x29, #0x70
     2ec:      	add	x2, x19, #0x30
     2f0:      	mov	x0, x22
     2f4:      	bl	0x2f4 <ltmp0+0x2f4>
     2f8:      	add	x1, x19, #0x18
     2fc:      	mov	x0, x22
     300:      	str	x24, [x19, #0x20]
     304:      	bl	0x304 <ltmp0+0x304>
     308:      	cbnz	w0, 0x5fc <ltmp0+0x5fc>
     30c:      	add	x1, x19, #0x0
     310:      	mov	x0, x22
     314:      	str	x24, [x19, #0x8]
     318:      	bl	0x318 <ltmp0+0x318>
     31c:      	cbnz	w0, 0x60c <ltmp0+0x60c>
     320:      	mov	x0, x22
     324:      	mov	x1, x23
     328:      	bl	0x328 <ltmp0+0x328>
     32c:      	mov	w1, wzr
     330:      	mov	x0, x22
     334:      	bl	0x334 <ltmp0+0x334>
     338:      	mov	w23, w0
     33c:      	cmp	w0, #0x2
     340:      	b.eq	0x360 <ltmp0+0x360>
     344:      	ldr	x21, [x21, #0x18]
     348:      	cbz	x21, 0x360 <ltmp0+0x360>
     34c:      	mov	x0, x22
     350:      	bl	0x350 <ltmp0+0x350>
     354:      	mov	x1, x0
     358:      	mov	x0, x20
     35c:      	blr	x21
     360:      	mov	x0, x22
     364:      	bl	0x364 <ltmp0+0x364>
     368:      	mov	w0, w23
     36c:      	sub	sp, x29, #0x50
     370:      	ldp	x29, x30, [sp, #0x50]
     374:      	ldp	x20, x19, [sp, #0x40]
     378:      	ldp	x22, x21, [sp, #0x30]
     37c:      	ldp	x24, x23, [sp, #0x20]
     380:      	ldp	x26, x25, [sp, #0x10]
     384:      	ldp	x28, x27, [sp], #0x60
     388:      	ret
     38c:      	mov	w23, wzr
     390:      	adrp	x0, 0x0 <ltmp0>
     394:      	add	x0, x0, #0x0
     398:      	mov	w1, #0x1                ; =1
     39c:      	bl	0x39c <ltmp0+0x39c>
     3a0:      	cbnz	x0, 0x58 <ltmp0+0x58>
     3a4:      	mov	w23, #0x2               ; =2
     3a8:      	b	0x368 <ltmp0+0x368>
     3ac:      	adrp	x2, 0x0 <ltmp0>
     3b0:      	add	x2, x2, #0x0
     3b4:      	mov	x0, x22
     3b8:      	mov	w1, #0xd                ; =13
     3bc:      	mov	w3, #0x16               ; =22
     3c0:      	b	0x434 <ltmp0+0x434>
     3c4:      	adrp	x2, 0x0 <ltmp0>
     3c8:      	add	x2, x2, #0x0
     3cc:      	mov	x0, x22
     3d0:      	mov	w1, #0xd                ; =13
     3d4:      	mov	w3, #0x16               ; =22
     3d8:      	b	0x46c <ltmp0+0x46c>
     3dc:      	adrp	x2, 0x0 <ltmp0>
     3e0:      	add	x2, x2, #0x0
     3e4:      	mov	x0, x22
     3e8:      	mov	w1, #0x9                ; =9
     3ec:      	mov	w3, #0x18               ; =24
     3f0:      	bl	0x3f0 <ltmp0+0x3f0>
     3f4:      	mov	x0, x22
     3f8:      	mov	w1, wzr
     3fc:      	mov	w2, #0x15               ; =21
     400:      	b	0x618 <ltmp0+0x618>
     404:      	adrp	x2, 0x0 <ltmp0>
     408:      	add	x2, x2, #0x0
     40c:      	mov	x0, x22
     410:      	mov	w1, #0x6                ; =6
     414:      	mov	w3, #0x13               ; =19
     418:      	bl	0x418 <ltmp0+0x418>
     41c:      	b	0x628 <ltmp0+0x628>
     420:      	adrp	x2, 0x0 <ltmp0>
     424:      	add	x2, x2, #0x0
     428:      	mov	x0, x22
     42c:      	mov	w1, #0xe                ; =14
     430:      	mov	w3, #0x15               ; =21
     434:      	bl	0x434 <ltmp0+0x434>
     438:      	mov	x0, x22
     43c:      	mov	w1, wzr
     440:      	mov	w2, #0x1                ; =1
     444:      	b	0x618 <ltmp0+0x618>
     448:      	mov	x0, x22
     44c:      	mov	w1, wzr
     450:      	mov	w2, #0x3                ; =3
     454:      	b	0x618 <ltmp0+0x618>
     458:      	adrp	x2, 0x0 <ltmp0>
     45c:      	add	x2, x2, #0x0
     460:      	mov	x0, x22
     464:      	mov	w1, #0xe                ; =14
     468:      	mov	w3, #0x15               ; =21
     46c:      	bl	0x46c <ltmp0+0x46c>
     470:      	mov	x0, x22
     474:      	mov	w1, wzr
     478:      	mov	w2, #0x4                ; =4
     47c:      	b	0x618 <ltmp0+0x618>
     480:      	sub	x1, x29, #0xb8
     484:      	sub	x2, x29, #0xd0
     488:      	mov	x0, x22
     48c:      	stur	x24, [x29, #-0xb0]
     490:      	stur	x27, [x29, #-0xc8]
     494:      	bl	0x494 <ltmp0+0x494>
     498:      	cbnz	w0, 0x470 <ltmp0+0x470>
     49c:      	ldr	x8, [x22, #0x60]
     4a0:      	add	x9, x8, x25
     4a4:      	ldr	w9, [x9, #0x60]
     4a8:      	cmp	w9, w26
     4ac:      	b.eq	0x1f8 <ltmp0+0x1f8>
     4b0:      	adrp	x2, 0x0 <ltmp0>
     4b4:      	add	x2, x2, #0x0
     4b8:      	mov	x0, x22
     4bc:      	mov	w1, #0xd                ; =13
     4c0:      	mov	w3, #0x16               ; =22
     4c4:      	bl	0x4c4 <ltmp0+0x4c4>
     4c8:      	mov	x0, x22
     4cc:      	mov	w1, wzr
     4d0:      	mov	w2, #0x5                ; =5
     4d4:      	b	0x618 <ltmp0+0x618>
     4d8:      	mov	w8, #0x2                ; =2
     4dc:      	add	x1, x19, #0xd8
     4e0:      	add	x2, x19, #0xc0
     4e4:      	mov	x0, x22
     4e8:      	str	x24, [x19, #0xe0]
     4ec:      	str	x8, [x19, #0xc8]
     4f0:      	bl	0x4f0 <ltmp0+0x4f0>
     4f4:      	cbz	w0, 0x21c <ltmp0+0x21c>
     4f8:      	b	0x4c8 <ltmp0+0x4c8>
     4fc:      	mov	x0, x22
     500:      	mov	w1, wzr
     504:      	mov	w2, #0x8                ; =8
     508:      	b	0x618 <ltmp0+0x618>
     50c:      	adrp	x2, 0x0 <ltmp0>
     510:      	add	x2, x2, #0x0
     514:      	mov	x0, x22
     518:      	mov	w1, #0xd                ; =13
     51c:      	mov	w3, #0x16               ; =22
     520:      	bl	0x520 <ltmp0+0x520>
     524:      	mov	x0, x22
     528:      	mov	w1, wzr
     52c:      	mov	w2, #0xc                ; =12
     530:      	b	0x618 <ltmp0+0x618>
     534:      	mov	w8, #0x3                ; =3
     538:      	add	x1, x19, #0x90
     53c:      	add	x2, x19, #0x78
     540:      	mov	x0, x22
     544:      	str	x24, [x19, #0x98]
     548:      	str	x8, [x19, #0x80]
     54c:      	bl	0x54c <ltmp0+0x54c>
     550:      	cbnz	w0, 0x524 <ltmp0+0x524>
     554:      	ldr	x8, [x22, #0x60]
     558:      	add	x9, x8, x25
     55c:      	ldr	w9, [x9, #0x60]
     560:      	cmp	w9, w26
     564:      	b.eq	0x264 <ltmp0+0x264>
     568:      	adrp	x2, 0x0 <ltmp0>
     56c:      	add	x2, x2, #0x0
     570:      	mov	x0, x22
     574:      	mov	w1, #0xd                ; =13
     578:      	mov	w3, #0x16               ; =22
     57c:      	bl	0x57c <ltmp0+0x57c>
     580:      	mov	x0, x22
     584:      	mov	w1, wzr
     588:      	mov	w2, #0xf                ; =15
     58c:      	b	0x618 <ltmp0+0x618>
     590:      	adrp	x2, 0x0 <ltmp0>
     594:      	add	x2, x2, #0x0
     598:      	mov	x0, x22
     59c:      	mov	w1, wzr
     5a0:      	mov	w3, #0x10               ; =16
     5a4:      	bl	0x5a4 <ltmp0+0x5a4>
     5a8:      	mov	x0, x22
     5ac:      	mov	w1, wzr
     5b0:      	mov	w2, #0x11               ; =17
     5b4:      	b	0x618 <ltmp0+0x618>
     5b8:      	adrp	x2, 0x0 <ltmp0>
     5bc:      	add	x2, x2, #0x0
     5c0:      	mov	x0, x22
     5c4:      	mov	w1, #0xa                ; =10
     5c8:      	mov	w3, #0x13               ; =19
     5cc:      	bl	0x5cc <ltmp0+0x5cc>
     5d0:      	mov	x0, x22
     5d4:      	mov	w1, wzr
     5d8:      	mov	w2, #0x12               ; =18
     5dc:      	b	0x618 <ltmp0+0x618>
     5e0:      	mov	x0, x22
     5e4:      	mov	w1, wzr
     5e8:      	mov	w2, #0x13               ; =19
     5ec:      	b	0x618 <ltmp0+0x618>
     5f0:      	mov	x0, x22
     5f4:      	bl	0x5f4 <ltmp0+0x5f4>
     5f8:      	b	0x61c <ltmp0+0x61c>
     5fc:      	mov	x0, x22
     600:      	mov	w1, wzr
     604:      	mov	w2, #0x1a               ; =26
     608:      	b	0x618 <ltmp0+0x618>
     60c:      	mov	x0, x22
     610:      	mov	w1, wzr
     614:      	mov	w2, #0x1c               ; =28
     618:      	bl	0x618 <ltmp0+0x618>
     61c:      	mov	x0, x22
     620:      	mov	x1, x23
     624:      	bl	0x624 <ltmp0+0x624>
     628:      	ldr	x2, [x21, #0x10]
     62c:      	mov	x0, x22
     630:      	mov	x1, x20
     634:      	bl	0x634 <ltmp0+0x634>
     638:      	mov	w1, #0x1                ; =1
     63c:      	mov	x0, x22
     640:      	bl	0x640 <ltmp0+0x640>
     644:      	mov	w23, w0
     648:      	cmp	w0, #0x2
     64c:      	b.ne	0x344 <ltmp0+0x344>
     650:      	b	0x360 <ltmp0+0x360>
