
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/classes.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce_main():
       0:      	stp	x26, x25, [sp, #-0x50]!
       4:      	stp	x24, x23, [sp, #0x10]
       8:      	stp	x22, x21, [sp, #0x20]
       c:      	stp	x20, x19, [sp, #0x30]
      10:      	stp	x29, x30, [sp, #0x40]
      14:      	add	x29, sp, #0x40
      18:      	sub	sp, sp, #0x140
      1c:      	mov	x19, sp
      20:      	ldr	x8, [x0, #0x70]
      24:      	ldr	x20, [x0]
      28:      	mov	x21, x0
      2c:      	cbz	x8, 0x338 <ltmp0+0x338>
      30:      	mov	x0, x20
      34:      	blr	x8
      38:      	mov	x24, x0
      3c:      	adrp	x0, 0x0 <ltmp0>
      40:      	add	x0, x0, #0x0
      44:      	mov	w1, #0x3                ; =3
      48:      	bl	0x48 <ltmp0+0x48>
      4c:      	cbz	x0, 0x350 <ltmp0+0x350>
      50:      	ldp	x3, x4, [x21, #0x1b0]
      54:      	mov	x22, x0
      58:      	ldp	x5, x6, [x21, #0x1c0]
      5c:      	ldr	x2, [x21, #0xe0]
      60:      	ldp	x8, x9, [x21, #0xf8]
      64:      	ldr	x7, [x21, #0x1d0]
      68:      	ldur	q0, [x21, #0xe8]
      6c:      	sub	sp, sp, #0x20
      70:      	mov	x1, x20
      74:      	stp	x8, x9, [sp, #0x10]
      78:      	str	q0, [sp]
      7c:      	bl	0x7c <ltmp0+0x7c>
      80:      	add	sp, sp, #0x20
      84:      	ldp	x2, x3, [x21, #0x180]
      88:      	mov	x0, x22
      8c:      	ldp	x4, x5, [x21, #0x190]
      90:      	mov	x1, x20
      94:      	ldr	x6, [x21, #0x1a0]
      98:      	bl	0x98 <ltmp0+0x98>
      9c:      	ldp	x8, x9, [x21, #0x170]
      a0:      	ldp	x2, x3, [x21, #0x140]
      a4:      	ldp	x4, x5, [x21, #0x150]
      a8:      	ldp	x6, x7, [x21, #0x160]
      ac:      	stp	x8, x9, [sp, #-0x10]!
      b0:      	mov	x0, x22
      b4:      	mov	x1, x20
      b8:      	bl	0xb8 <ltmp0+0xb8>
      bc:      	add	sp, sp, #0x10
      c0:      	cmp	x24, #0x0
      c4:      	b.le	0x398 <ltmp0+0x398>
      c8:      	sub	x23, sp, #0x20
      cc:      	mov	sp, x23
      d0:      	ldp	x2, x3, [x21, #0x20]
      d4:      	mov	x0, x22
      d8:      	mov	x1, x20
      dc:      	mov	x4, x23
      e0:      	bl	0xe0 <ltmp0+0xe0>
      e4:      	cbnz	w0, 0x480 <ltmp0+0x480>
      e8:      	mov	w8, #0xff04             ; =65284
      ec:      	adrp	x9, 0x0 <ltmp0>
      f0:      	add	x9, x9, #0x0
      f4:      	strh	w8, [x19, #0x90]
      f8:      	mov	w8, #0x2                ; =2
      fc:      	strb	w8, [x19, #0x60]
     100:      	ldr	x8, [x23, #0x8]
     104:      	str	x9, [x19, #0x98]
     108:      	mov	w9, #0x6                ; =6
     10c:      	cmn	w8, #0x1
     110:      	strb	w9, [x19, #0x78]
     114:      	str	xzr, [x19, #0x88]
     118:      	str	xzr, [x19, #0x70]
     11c:      	strb	w9, [x19, #0x18]
     120:      	str	xzr, [x19, #0x28]
     124:      	strb	w9, [x19]
     128:      	str	xzr, [x19, #0x10]
     12c:      	b.eq	0x3b4 <ltmp0+0x3b4>
     130:      	mov	w9, #0x70               ; =112
     134:      	ldr	x10, [x22, #0x60]
     138:      	umaddl	x9, w8, w9, x10
     13c:      	lsr	x8, x8, #32
     140:      	ldr	w10, [x9, #0x60]
     144:      	cmp	w10, w8
     148:      	b.ne	0x358 <ltmp0+0x358>
     14c:      	tbnz	w8, #0x0, 0x358 <ltmp0+0x358>
     150:      	cmp	x24, #0x1
     154:      	b.eq	0x3dc <ltmp0+0x3dc>
     158:      	ldr	x9, [x9, #0x10]
     15c:      	mov	w8, #0x2                ; =2
     160:      	sub	x3, x29, #0x58
     164:      	sub	x5, x29, #0x70
     168:      	mov	x0, x22
     16c:      	mov	x1, xzr
     170:      	mov	x2, #-0x1               ; =-1
     174:      	mov	w4, #0x1                ; =1
     178:      	sturb	w8, [x29, #-0x58]
     17c:      	stp	x9, xzr, [x29, #-0x50]
     180:      	bl	0x180 <ltmp0+0x180>
     184:      	cbnz	w0, 0x3f8 <ltmp0+0x3f8>
     188:      	ldur	x25, [x29, #-0x68]
     18c:      	add	x1, x19, #0x78
     190:      	mov	x0, x22
     194:      	str	x25, [x19, #0x80]
     198:      	bl	0x198 <ltmp0+0x198>
     19c:      	cbnz	w0, 0x418 <ltmp0+0x418>
     1a0:      	mov	w8, #0x6                ; =6
     1a4:      	mov	w24, #0x2               ; =2
     1a8:      	sub	x1, x29, #0x58
     1ac:      	sub	x4, x29, #0x70
     1b0:      	mov	x0, x22
     1b4:      	mov	x2, xzr
     1b8:      	mov	x3, xzr
     1bc:      	sturb	w8, [x29, #-0x58]
     1c0:      	sturb	w8, [x29, #-0x88]
     1c4:      	stur	xzr, [x29, #-0x78]
     1c8:      	sturb	w24, [x29, #-0xa0]
     1cc:      	stur	xzr, [x29, #-0x90]
     1d0:      	sturb	w8, [x29, #-0xb8]
     1d4:      	stur	xzr, [x29, #-0xa8]
     1d8:      	stp	x25, xzr, [x29, #-0x50]
     1dc:      	bl	0x1dc <ltmp0+0x1dc>
     1e0:      	cbnz	w0, 0x454 <ltmp0+0x454>
     1e4:      	ldur	x8, [x29, #-0x68]
     1e8:      	adds	x8, x8, #0x1
     1ec:      	b.vs	0x428 <ltmp0+0x428>
     1f0:      	sub	x1, x29, #0x88
     1f4:      	sub	x4, x29, #0xa0
     1f8:      	mov	x0, x22
     1fc:      	mov	x2, xzr
     200:      	mov	x3, xzr
     204:      	stur	x25, [x29, #-0x80]
     208:      	stur	x8, [x29, #-0x98]
     20c:      	bl	0x20c <ltmp0+0x20c>
     210:      	cbnz	w0, 0x448 <ltmp0+0x448>
     214:      	sub	x1, x29, #0xb8
     218:      	add	x4, x19, #0xb0
     21c:      	mov	x0, x22
     220:      	mov	x2, xzr
     224:      	mov	x3, xzr
     228:      	stur	x25, [x29, #-0xb0]
     22c:      	bl	0x22c <ltmp0+0x22c>
     230:      	cbnz	w0, 0x450 <ltmp0+0x450>
     234:      	ldr	x8, [x19, #0xb8]
     238:      	add	x1, x19, #0x60
     23c:      	add	x2, x19, #0x48
     240:      	mov	x0, x22
     244:      	str	x8, [x19, #0x68]
     248:      	bl	0x248 <ltmp0+0x248>
     24c:      	cbnz	w0, 0x4ac <ltmp0+0x4ac>
     250:      	ldp	x9, x10, [x19, #0x50]
     254:      	ldur	q0, [x19, #0x48]
     258:      	ldr	x8, [x21, #0x8]
     25c:      	ldrb	w11, [x19, #0x49]
     260:      	str	q0, [x19, #0x90]
     264:      	str	x10, [x19, #0xa0]
     268:      	cbz	x8, 0x370 <ltmp0+0x370>
     26c:      	add	x12, x19, #0x48
     270:      	cmp	w11, #0xff
     274:      	ldr	x0, [x21]
     278:      	orr	x12, x12, #0x2
     27c:      	csel	x2, x10, x11, eq
     280:      	csel	x1, x9, x12, eq
     284:      	blr	x8
     288:      	cmn	w0, #0x1
     28c:      	b.eq	0x4bc <ltmp0+0x4bc>
     290:      	cmp	w0, #0x2
     294:      	b.hs	0x370 <ltmp0+0x370>
     298:      	add	x1, x19, #0x90
     29c:      	add	x2, x19, #0x30
     2a0:      	mov	x0, x22
     2a4:      	bl	0x2a4 <ltmp0+0x2a4>
     2a8:      	add	x1, x19, #0x18
     2ac:      	mov	x0, x22
     2b0:      	str	x25, [x19, #0x20]
     2b4:      	bl	0x2b4 <ltmp0+0x2b4>
     2b8:      	cbnz	w0, 0x4c8 <ltmp0+0x4c8>
     2bc:      	add	x1, x19, #0x0
     2c0:      	mov	x0, x22
     2c4:      	str	x25, [x19, #0x8]
     2c8:      	bl	0x2c8 <ltmp0+0x2c8>
     2cc:      	cbnz	w0, 0x4d8 <ltmp0+0x4d8>
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
     31c:      	sub	sp, x29, #0x40
     320:      	ldp	x29, x30, [sp, #0x40]
     324:      	ldp	x20, x19, [sp, #0x30]
     328:      	ldp	x22, x21, [sp, #0x20]
     32c:      	ldp	x24, x23, [sp, #0x10]
     330:      	ldp	x26, x25, [sp], #0x50
     334:      	ret
     338:      	mov	w24, #0x100             ; =256
     33c:      	adrp	x0, 0x0 <ltmp0>
     340:      	add	x0, x0, #0x0
     344:      	mov	w1, #0x3                ; =3
     348:      	bl	0x348 <ltmp0+0x348>
     34c:      	cbnz	x0, 0x50 <ltmp0+0x50>
     350:      	mov	w23, #0x2               ; =2
     354:      	b	0x318 <ltmp0+0x318>
     358:      	adrp	x2, 0x0 <ltmp0>
     35c:      	add	x2, x2, #0x0
     360:      	mov	x0, x22
     364:      	mov	w1, #0xd                ; =13
     368:      	mov	w3, #0x16               ; =22
     36c:      	b	0x3c8 <ltmp0+0x3c8>
     370:      	adrp	x2, 0x0 <ltmp0>
     374:      	add	x2, x2, #0x0
     378:      	mov	x0, x22
     37c:      	mov	w1, #0x9                ; =9
     380:      	mov	w3, #0x18               ; =24
     384:      	bl	0x384 <ltmp0+0x384>
     388:      	mov	x0, x22
     38c:      	mov	w1, wzr
     390:      	mov	w2, #0xb                ; =11
     394:      	b	0x470 <ltmp0+0x470>
     398:      	adrp	x2, 0x0 <ltmp0>
     39c:      	add	x2, x2, #0x0
     3a0:      	mov	x0, x22
     3a4:      	mov	w1, #0x6                ; =6
     3a8:      	mov	w3, #0x13               ; =19
     3ac:      	bl	0x3ac <ltmp0+0x3ac>
     3b0:      	b	0x480 <ltmp0+0x480>
     3b4:      	adrp	x2, 0x0 <ltmp0>
     3b8:      	add	x2, x2, #0x0
     3bc:      	mov	x0, x22
     3c0:      	mov	w1, #0xe                ; =14
     3c4:      	mov	w3, #0x15               ; =21
     3c8:      	bl	0x3c8 <ltmp0+0x3c8>
     3cc:      	mov	x0, x22
     3d0:      	mov	w1, wzr
     3d4:      	mov	w2, #0x1                ; =1
     3d8:      	b	0x470 <ltmp0+0x470>
     3dc:      	adrp	x2, 0x0 <ltmp0>
     3e0:      	add	x2, x2, #0x0
     3e4:      	mov	x0, x22
     3e8:      	mov	w1, #0x6                ; =6
     3ec:      	mov	w3, #0x13               ; =19
     3f0:      	bl	0x3f0 <ltmp0+0x3f0>
     3f4:      	b	0x408 <ltmp0+0x408>
     3f8:      	mov	x0, x22
     3fc:      	mov	w1, #0x2                ; =2
     400:      	mov	w2, #0x5                ; =5
     404:      	bl	0x404 <ltmp0+0x404>
     408:      	mov	x0, x22
     40c:      	mov	w1, wzr
     410:      	mov	w2, #0x2                ; =2
     414:      	b	0x470 <ltmp0+0x470>
     418:      	mov	x0, x22
     41c:      	mov	w1, wzr
     420:      	mov	w2, #0x5                ; =5
     424:      	b	0x470 <ltmp0+0x470>
     428:      	adrp	x2, 0x0 <ltmp0>
     42c:      	add	x2, x2, #0x0
     430:      	mov	x0, x22
     434:      	mov	w1, wzr
     438:      	mov	w3, #0x10               ; =16
     43c:      	bl	0x43c <ltmp0+0x43c>
     440:      	mov	w24, #0x3               ; =3
     444:      	b	0x454 <ltmp0+0x454>
     448:      	mov	w24, #0x4               ; =4
     44c:      	b	0x454 <ltmp0+0x454>
     450:      	mov	w24, #0x6               ; =6
     454:      	mov	x0, x22
     458:      	mov	w1, #0x1                ; =1
     45c:      	mov	w2, w24
     460:      	bl	0x460 <ltmp0+0x460>
     464:      	mov	x0, x22
     468:      	mov	w1, wzr
     46c:      	mov	w2, #0x8                ; =8
     470:      	bl	0x470 <ltmp0+0x470>
     474:      	mov	x0, x22
     478:      	mov	x1, x23
     47c:      	bl	0x47c <ltmp0+0x47c>
     480:      	ldr	x2, [x21, #0x10]
     484:      	mov	x0, x22
     488:      	mov	x1, x20
     48c:      	bl	0x48c <ltmp0+0x48c>
     490:      	mov	w1, #0x1                ; =1
     494:      	mov	x0, x22
     498:      	bl	0x498 <ltmp0+0x498>
     49c:      	mov	w23, w0
     4a0:      	cmp	w0, #0x2
     4a4:      	b.ne	0x2f4 <ltmp0+0x2f4>
     4a8:      	b	0x310 <ltmp0+0x310>
     4ac:      	mov	x0, x22
     4b0:      	mov	w1, wzr
     4b4:      	mov	w2, #0x9                ; =9
     4b8:      	b	0x470 <ltmp0+0x470>
     4bc:      	mov	x0, x22
     4c0:      	bl	0x4c0 <ltmp0+0x4c0>
     4c4:      	b	0x474 <ltmp0+0x474>
     4c8:      	mov	x0, x22
     4cc:      	mov	w1, wzr
     4d0:      	mov	w2, #0x10               ; =16
     4d4:      	b	0x470 <ltmp0+0x470>
     4d8:      	mov	x0, x22
     4dc:      	mov	w1, wzr
     4e0:      	mov	w2, #0x12               ; =18
     4e4:      	b	0x470 <ltmp0+0x470>
