
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/closures.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce.bound.2():
       0:      	sub	sp, sp, #0x60
       4:      	stp	x20, x19, [sp, #0x40]
       8:      	mov	x19, x1
       c:      	ldr	x9, [x3, #0x8]
      10:      	stp	x22, x21, [sp, #0x30]
      14:      	mov	x21, x4
      18:      	mov	w8, #0x6                ; =6
      1c:      	add	x1, sp, #0x18
      20:      	mov	x4, sp
      24:      	mov	x0, x19
      28:      	mov	x2, xzr
      2c:      	mov	x3, xzr
      30:      	stp	x29, x30, [sp, #0x50]
      34:      	mov	x20, x5
      38:      	strb	w8, [sp, #0x18]
      3c:      	stp	x9, xzr, [sp, #0x20]
      40:      	bl	0x40 <ltmp0+0x40>
      44:      	cbnz	w0, 0x70 <ltmp0+0x70>
      48:      	ldr	x8, [sp, #0x8]
      4c:      	adds	x8, x8, x21
      50:      	b.vs	0x80 <ltmp0+0x80>
      54:      	mov	w0, wzr
      58:      	str	x8, [x20]
      5c:      	ldp	x29, x30, [sp, #0x50]
      60:      	ldp	x20, x19, [sp, #0x40]
      64:      	ldp	x22, x21, [sp, #0x30]
      68:      	add	sp, sp, #0x60
      6c:      	ret
      70:      	mov	x0, x19
      74:      	mov	w1, #0x2                ; =2
      78:      	mov	w2, #0x1                ; =1
      7c:      	b	0xa4 <ltmp0+0xa4>
      80:      	adrp	x2, 0x0 <ltmp0>
      84:      	add	x2, x2, #0x0
      88:      	mov	x0, x19
      8c:      	mov	w1, wzr
      90:      	mov	w3, #0x10               ; =16
      94:      	bl	0x94 <ltmp0+0x94>
      98:      	mov	x0, x19
      9c:      	mov	w1, #0x2                ; =2
      a0:      	mov	w2, #0x5                ; =5
      a4:      	bl	0xa4 <ltmp0+0xa4>
      a8:      	mov	w0, #0x1                ; =1
      ac:      	ldp	x29, x30, [sp, #0x50]
      b0:      	ldp	x20, x19, [sp, #0x40]
      b4:      	ldp	x22, x21, [sp, #0x30]
      b8:      	add	sp, sp, #0x60
      bc:      	ret

00000000000000c0 <_luce_main>:
; luce_main():
      c0:      	stp	x28, x27, [sp, #-0x60]!
      c4:      	stp	x26, x25, [sp, #0x10]
      c8:      	stp	x24, x23, [sp, #0x20]
      cc:      	stp	x22, x21, [sp, #0x30]
      d0:      	stp	x20, x19, [sp, #0x40]
      d4:      	stp	x29, x30, [sp, #0x50]
      d8:      	add	x29, sp, #0x50
      dc:      	sub	sp, sp, #0x1b0
      e0:      	mov	x19, sp
      e4:      	ldr	x8, [x0, #0x70]
      e8:      	ldr	x20, [x0]
      ec:      	mov	x21, x0
      f0:      	cbz	x8, 0x460 <_luce_main+0x3a0>
      f4:      	mov	x0, x20
      f8:      	blr	x8
      fc:      	mov	x24, x0
     100:      	adrp	x0, 0x0 <ltmp0>
     104:      	add	x0, x0, #0x0
     108:      	mov	w1, #0x3                ; =3
     10c:      	bl	0x10c <_luce_main+0x4c>
     110:      	cbz	x0, 0x478 <_luce_main+0x3b8>
     114:      	ldp	x3, x4, [x21, #0x1b0]
     118:      	mov	x22, x0
     11c:      	ldp	x5, x6, [x21, #0x1c0]
     120:      	ldr	x2, [x21, #0xe0]
     124:      	ldp	x8, x9, [x21, #0xf8]
     128:      	ldr	x7, [x21, #0x1d0]
     12c:      	ldur	q0, [x21, #0xe8]
     130:      	sub	sp, sp, #0x20
     134:      	mov	x1, x20
     138:      	stp	x8, x9, [sp, #0x10]
     13c:      	str	q0, [sp]
     140:      	bl	0x140 <_luce_main+0x80>
     144:      	add	sp, sp, #0x20
     148:      	ldp	x2, x3, [x21, #0x180]
     14c:      	mov	x0, x22
     150:      	ldp	x4, x5, [x21, #0x190]
     154:      	mov	x1, x20
     158:      	ldr	x6, [x21, #0x1a0]
     15c:      	bl	0x15c <_luce_main+0x9c>
     160:      	ldp	x8, x9, [x21, #0x170]
     164:      	ldp	x2, x3, [x21, #0x140]
     168:      	ldp	x4, x5, [x21, #0x150]
     16c:      	ldp	x6, x7, [x21, #0x160]
     170:      	stp	x8, x9, [sp, #-0x10]!
     174:      	mov	x0, x22
     178:      	mov	x1, x20
     17c:      	bl	0x17c <_luce_main+0xbc>
     180:      	add	sp, sp, #0x10
     184:      	cmp	x24, #0x0
     188:      	b.le	0x4e8 <_luce_main+0x428>
     18c:      	sub	x23, sp, #0x20
     190:      	mov	sp, x23
     194:      	ldp	x2, x3, [x21, #0x20]
     198:      	mov	x0, x22
     19c:      	mov	x1, x20
     1a0:      	mov	x4, x23
     1a4:      	bl	0x1a4 <_luce_main+0xe4>
     1a8:      	cbnz	w0, 0x58c <_luce_main+0x4cc>
     1ac:      	mov	w9, #0xff04             ; =65284
     1b0:      	mov	w8, #0xc                ; =12
     1b4:      	mov	w10, #0x2               ; =2
     1b8:      	strh	w9, [x19, #0x80]
     1bc:      	adrp	x9, 0x0 <ltmp0>
     1c0:      	add	x9, x9, #0x0
     1c4:      	str	x9, [x19, #0x88]
     1c8:      	ldr	x9, [x23, #0x8]
     1cc:      	strb	w8, [x19, #0xa0]
     1d0:      	cmn	w9, #0x1
     1d4:      	str	x10, [x19, #0xb0]
     1d8:      	strb	w10, [x19, #0x60]
     1dc:      	str	xzr, [x19, #0x70]
     1e0:      	strb	w8, [x19, #0x18]
     1e4:      	str	x10, [x19, #0x28]
     1e8:      	b.eq	0x504 <_luce_main+0x444>
     1ec:      	mov	w8, #0x70               ; =112
     1f0:      	ldr	x10, [x22, #0x60]
     1f4:      	umaddl	x8, w9, w8, x10
     1f8:      	lsr	x9, x9, #32
     1fc:      	ldr	w10, [x8, #0x60]
     200:      	cmp	w10, w9
     204:      	b.ne	0x480 <_luce_main+0x3c0>
     208:      	tbnz	w9, #0x0, 0x480 <_luce_main+0x3c0>
     20c:      	cmp	x24, #0x1
     210:      	b.eq	0x52c <_luce_main+0x46c>
     214:      	mov	w10, #0x7               ; =7
     218:      	ldr	x8, [x8, #0x10]
     21c:      	mov	w9, #0x2                ; =2
     220:      	sturb	w10, [x29, #-0xd0]
     224:      	mov	w10, #0xc               ; =12
     228:      	sub	x3, x29, #0x88
     22c:      	sub	x5, x29, #0xa0
     230:      	mov	x0, x22
     234:      	mov	x1, xzr
     238:      	mov	x2, #-0x1               ; =-1
     23c:      	mov	w4, #0x1                ; =1
     240:      	sturb	w9, [x29, #-0x88]
     244:      	stur	xzr, [x29, #-0xc0]
     248:      	mov	w25, #0x1               ; =1
     24c:      	strb	w10, [x19, #0x100]
     250:      	str	x9, [x19, #0x110]
     254:      	strb	w10, [x19, #0xe8]
     258:      	str	x9, [x19, #0xf8]
     25c:      	strb	w10, [x19, #0xb8]
     260:      	str	x9, [x19, #0xc8]
     264:      	stp	x8, xzr, [x29, #-0x80]
     268:      	bl	0x268 <_luce_main+0x1a8>
     26c:      	cbnz	w0, 0x560 <_luce_main+0x4a0>
     270:      	ldur	q0, [x29, #-0xa0]
     274:      	ldur	x8, [x29, #-0x90]
     278:      	sub	x26, x29, #0xe8
     27c:      	mov	w25, #0x2               ; =2
     280:      	sub	x1, x29, #0xd0
     284:      	sub	x3, x29, #0xe8
     288:      	mov	x0, x22
     28c:      	mov	w2, #0x2                ; =2
     290:      	stur	q0, [x26, #0x30]
     294:      	stur	x25, [x29, #-0xc8]
     298:      	stur	x8, [x29, #-0xa8]
     29c:      	bl	0x29c <_luce_main+0x1dc>
     2a0:      	cbnz	w0, 0x548 <_luce_main+0x488>
     2a4:      	ldr	q0, [x26]
     2a8:      	ldur	x8, [x29, #-0xd8]
     2ac:      	add	x1, x19, #0x100
     2b0:      	mov	x0, x22
     2b4:      	stur	q0, [x29, #-0x70]
     2b8:      	ldur	x26, [x29, #-0x68]
     2bc:      	stur	x8, [x29, #-0x60]
     2c0:      	str	x26, [x19, #0x108]
     2c4:      	bl	0x2c4 <_luce_main+0x204>
     2c8:      	cbnz	w0, 0x54c <_luce_main+0x48c>
     2cc:      	add	x1, x19, #0xe8
     2d0:      	add	x2, x19, #0xd0
     2d4:      	mov	x0, x22
     2d8:      	str	x26, [x19, #0xf0]
     2dc:      	bl	0x2dc <_luce_main+0x21c>
     2e0:      	cbnz	w0, 0x554 <_luce_main+0x494>
     2e4:      	ldr	x25, [x19, #0xd8]
     2e8:      	add	x1, x19, #0xb8
     2ec:      	mov	x0, x22
     2f0:      	str	x26, [x19, #0xc0]
     2f4:      	bl	0x2f4 <_luce_main+0x234>
     2f8:      	cbnz	w0, 0x55c <_luce_main+0x49c>
     2fc:      	sub	x1, x29, #0xe8
     300:      	sub	x2, x29, #0x70
     304:      	mov	x0, x22
     308:      	bl	0x308 <_luce_main+0x248>
     30c:      	mov	w8, #0xc                ; =12
     310:      	mov	w9, #0x2                ; =2
     314:      	strb	w8, [x19, #0xa0]
     318:      	stp	x25, x9, [x19, #0xa8]
     31c:      	cbz	x25, 0x498 <_luce_main+0x3d8>
     320:      	ldr	x8, [x25, #0x8]
     324:      	cmp	w8, #0x3
     328:      	b.hs	0x498 <_luce_main+0x3d8>
     32c:      	and	x8, x8, #0x3
     330:      	adrp	x9, 0x0 <ltmp0>
     334:      	add	x9, x9, #0x0
     338:      	ldr	x8, [x9, x8, lsl #3]
     33c:      	sub	x2, x24, #0x1
     340:      	add	x3, x25, #0x18
     344:      	add	x5, x19, #0x78
     348:      	mov	x0, x21
     34c:      	mov	x1, x22
     350:      	mov	w4, #0x2                ; =2
     354:      	blr	x8
     358:      	cbnz	w0, 0x4b0 <_luce_main+0x3f0>
     35c:      	ldr	x8, [x19, #0x78]
     360:      	add	x1, x19, #0x60
     364:      	add	x2, x19, #0x48
     368:      	mov	x0, x22
     36c:      	str	x8, [x19, #0x68]
     370:      	bl	0x370 <_luce_main+0x2b0>
     374:      	cbnz	w0, 0x5b8 <_luce_main+0x4f8>
     378:      	ldp	x9, x10, [x19, #0x50]
     37c:      	ldur	q0, [x19, #0x48]
     380:      	ldr	x8, [x21, #0x8]
     384:      	ldrb	w11, [x19, #0x49]
     388:      	str	q0, [x19, #0x80]
     38c:      	str	x10, [x19, #0x90]
     390:      	cbz	x8, 0x4c0 <_luce_main+0x400>
     394:      	add	x12, x19, #0x48
     398:      	cmp	w11, #0xff
     39c:      	ldr	x0, [x21]
     3a0:      	orr	x12, x12, #0x2
     3a4:      	csel	x2, x10, x11, eq
     3a8:      	csel	x1, x9, x12, eq
     3ac:      	blr	x8
     3b0:      	cmn	w0, #0x1
     3b4:      	b.eq	0x5c8 <_luce_main+0x508>
     3b8:      	cmp	w0, #0x2
     3bc:      	b.hs	0x4c0 <_luce_main+0x400>
     3c0:      	add	x1, x19, #0x80
     3c4:      	add	x2, x19, #0x30
     3c8:      	mov	x0, x22
     3cc:      	bl	0x3cc <_luce_main+0x30c>
     3d0:      	add	x1, x19, #0x18
     3d4:      	mov	x0, x22
     3d8:      	str	x25, [x19, #0x20]
     3dc:      	bl	0x3dc <_luce_main+0x31c>
     3e0:      	cbnz	w0, 0x5d4 <_luce_main+0x514>
     3e4:      	add	x1, x19, #0xa0
     3e8:      	add	x2, x19, #0x0
     3ec:      	mov	x0, x22
     3f0:      	bl	0x3f0 <_luce_main+0x330>
     3f4:      	mov	x0, x22
     3f8:      	mov	x1, x23
     3fc:      	bl	0x3fc <_luce_main+0x33c>
     400:      	mov	w1, wzr
     404:      	mov	x0, x22
     408:      	bl	0x408 <_luce_main+0x348>
     40c:      	mov	w23, w0
     410:      	cmp	w0, #0x2
     414:      	b.eq	0x434 <_luce_main+0x374>
     418:      	ldr	x21, [x21, #0x18]
     41c:      	cbz	x21, 0x434 <_luce_main+0x374>
     420:      	mov	x0, x22
     424:      	bl	0x424 <_luce_main+0x364>
     428:      	mov	x1, x0
     42c:      	mov	x0, x20
     430:      	blr	x21
     434:      	mov	x0, x22
     438:      	bl	0x438 <_luce_main+0x378>
     43c:      	mov	w0, w23
     440:      	sub	sp, x29, #0x50
     444:      	ldp	x29, x30, [sp, #0x50]
     448:      	ldp	x20, x19, [sp, #0x40]
     44c:      	ldp	x22, x21, [sp, #0x30]
     450:      	ldp	x24, x23, [sp, #0x20]
     454:      	ldp	x26, x25, [sp, #0x10]
     458:      	ldp	x28, x27, [sp], #0x60
     45c:      	ret
     460:      	mov	w24, #0x100             ; =256
     464:      	adrp	x0, 0x0 <ltmp0>
     468:      	add	x0, x0, #0x0
     46c:      	mov	w1, #0x3                ; =3
     470:      	bl	0x470 <_luce_main+0x3b0>
     474:      	cbnz	x0, 0x114 <_luce_main+0x54>
     478:      	mov	w23, #0x2               ; =2
     47c:      	b	0x43c <_luce_main+0x37c>
     480:      	adrp	x2, 0x0 <ltmp0>
     484:      	add	x2, x2, #0x0
     488:      	mov	x0, x22
     48c:      	mov	w1, #0xd                ; =13
     490:      	mov	w3, #0x16               ; =22
     494:      	b	0x518 <_luce_main+0x458>
     498:      	adrp	x2, 0x0 <ltmp0>
     49c:      	add	x2, x2, #0x0
     4a0:      	mov	x0, x22
     4a4:      	mov	w1, #0xe                ; =14
     4a8:      	mov	w3, #0x15               ; =21
     4ac:      	bl	0x4ac <_luce_main+0x3ec>
     4b0:      	mov	x0, x22
     4b4:      	mov	w1, #0x1                ; =1
     4b8:      	mov	w2, #0x6                ; =6
     4bc:      	b	0x57c <_luce_main+0x4bc>
     4c0:      	adrp	x2, 0x0 <ltmp0>
     4c4:      	add	x2, x2, #0x0
     4c8:      	mov	x0, x22
     4cc:      	mov	w1, #0x9                ; =9
     4d0:      	mov	w3, #0x18               ; =24
     4d4:      	bl	0x4d4 <_luce_main+0x414>
     4d8:      	mov	x0, x22
     4dc:      	mov	w1, #0x1                ; =1
     4e0:      	mov	w2, #0x9                ; =9
     4e4:      	b	0x57c <_luce_main+0x4bc>
     4e8:      	adrp	x2, 0x0 <ltmp0>
     4ec:      	add	x2, x2, #0x0
     4f0:      	mov	x0, x22
     4f4:      	mov	w1, #0x6                ; =6
     4f8:      	mov	w3, #0x13               ; =19
     4fc:      	bl	0x4fc <_luce_main+0x43c>
     500:      	b	0x58c <_luce_main+0x4cc>
     504:      	adrp	x2, 0x0 <ltmp0>
     508:      	add	x2, x2, #0x0
     50c:      	mov	x0, x22
     510:      	mov	w1, #0xe                ; =14
     514:      	mov	w3, #0x15               ; =21
     518:      	bl	0x518 <_luce_main+0x458>
     51c:      	mov	x0, x22
     520:      	mov	w1, #0x1                ; =1
     524:      	mov	w2, #0x1                ; =1
     528:      	b	0x57c <_luce_main+0x4bc>
     52c:      	adrp	x2, 0x0 <ltmp0>
     530:      	add	x2, x2, #0x0
     534:      	mov	x0, x22
     538:      	mov	w1, #0x6                ; =6
     53c:      	mov	w3, #0x13               ; =19
     540:      	bl	0x540 <_luce_main+0x480>
     544:      	b	0x570 <_luce_main+0x4b0>
     548:      	b	0x560 <_luce_main+0x4a0>
     54c:      	mov	w25, #0x5               ; =5
     550:      	b	0x560 <_luce_main+0x4a0>
     554:      	mov	w25, #0x6               ; =6
     558:      	b	0x560 <_luce_main+0x4a0>
     55c:      	mov	w25, #0x8               ; =8
     560:      	mov	x0, x22
     564:      	mov	w1, wzr
     568:      	mov	w2, w25
     56c:      	bl	0x56c <_luce_main+0x4ac>
     570:      	mov	x0, x22
     574:      	mov	w1, #0x1                ; =1
     578:      	mov	w2, #0x2                ; =2
     57c:      	bl	0x57c <_luce_main+0x4bc>
     580:      	mov	x0, x22
     584:      	mov	x1, x23
     588:      	bl	0x588 <_luce_main+0x4c8>
     58c:      	ldr	x2, [x21, #0x10]
     590:      	mov	x0, x22
     594:      	mov	x1, x20
     598:      	bl	0x598 <_luce_main+0x4d8>
     59c:      	mov	w1, #0x1                ; =1
     5a0:      	mov	x0, x22
     5a4:      	bl	0x5a4 <_luce_main+0x4e4>
     5a8:      	mov	w23, w0
     5ac:      	cmp	w0, #0x2
     5b0:      	b.ne	0x418 <_luce_main+0x358>
     5b4:      	b	0x434 <_luce_main+0x374>
     5b8:      	mov	x0, x22
     5bc:      	mov	w1, #0x1                ; =1
     5c0:      	mov	w2, #0x7                ; =7
     5c4:      	b	0x57c <_luce_main+0x4bc>
     5c8:      	mov	x0, x22
     5cc:      	bl	0x5cc <_luce_main+0x50c>
     5d0:      	b	0x580 <_luce_main+0x4c0>
     5d4:      	mov	x0, x22
     5d8:      	mov	w1, #0x1                ; =1
     5dc:      	mov	w2, #0xe                ; =14
     5e0:      	b	0x57c <_luce_main+0x4bc>
