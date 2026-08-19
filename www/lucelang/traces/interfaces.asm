
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/interfaces.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce_main():
       0:      	stp	x26, x25, [sp, #-0x50]!
       4:      	stp	x24, x23, [sp, #0x10]
       8:      	stp	x22, x21, [sp, #0x20]
       c:      	stp	x20, x19, [sp, #0x30]
      10:      	stp	x29, x30, [sp, #0x40]
      14:      	add	x29, sp, #0x40
      18:      	sub	sp, sp, #0x170
      1c:      	mov	x19, sp
      20:      	ldr	x8, [x0, #0x70]
      24:      	ldr	x20, [x0]
      28:      	mov	x21, x0
      2c:      	cbz	x8, 0x32c <ltmp0+0x32c>
      30:      	mov	x0, x20
      34:      	blr	x8
      38:      	mov	x24, x0
      3c:      	adrp	x0, 0x0 <ltmp0>
      40:      	add	x0, x0, #0x0
      44:      	mov	w1, #0x3                ; =3
      48:      	bl	0x48 <ltmp0+0x48>
      4c:      	cbz	x0, 0x344 <ltmp0+0x344>
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
      c4:      	b.le	0x3a4 <ltmp0+0x3a4>
      c8:      	sub	x23, sp, #0x20
      cc:      	mov	sp, x23
      d0:      	ldp	x2, x3, [x21, #0x20]
      d4:      	mov	x0, x22
      d8:      	mov	x1, x20
      dc:      	mov	x4, x23
      e0:      	bl	0xe0 <ltmp0+0xe0>
      e4:      	cbnz	w0, 0x4a0 <ltmp0+0x4a0>
      e8:      	mov	w8, #0xff04             ; =65284
      ec:      	adrp	x9, 0x0 <ltmp0>
      f0:      	add	x9, x9, #0x0
      f4:      	sturh	w8, [x29, #-0xa0]
      f8:      	mov	w8, #0x1                ; =1
      fc:      	mov	w10, #0x5               ; =5
     100:      	str	x8, [x19, #0xd8]
     104:      	ldr	x8, [x23, #0x8]
     108:      	stur	x9, [x29, #-0x98]
     10c:      	mov	w9, #0x2                ; =2
     110:      	cmn	w8, #0x1
     114:      	sturb	w9, [x29, #-0xb8]
     118:      	stur	xzr, [x29, #-0xa8]
     11c:      	strb	w10, [x19, #0xc8]
     120:      	strb	w9, [x19, #0x80]
     124:      	str	xzr, [x19, #0x90]
     128:      	strb	w9, [x19, #0x50]
     12c:      	str	xzr, [x19, #0x60]
     130:      	strb	w10, [x19, #0x8]
     134:      	str	x9, [x19, #0x18]
     138:      	b.eq	0x3c0 <ltmp0+0x3c0>
     13c:      	mov	w9, #0x70               ; =112
     140:      	ldr	x10, [x22, #0x60]
     144:      	umaddl	x9, w8, w9, x10
     148:      	lsr	x8, x8, #32
     14c:      	ldr	w10, [x9, #0x60]
     150:      	cmp	w10, w8
     154:      	b.ne	0x34c <ltmp0+0x34c>
     158:      	tbnz	w8, #0x0, 0x34c <ltmp0+0x34c>
     15c:      	ldr	x8, [x9, #0x10]
     160:      	adds	x8, x8, #0x4
     164:      	b.vs	0x3e8 <ltmp0+0x3e8>
     168:      	sub	x1, x29, #0xb8
     16c:      	sub	x3, x29, #0xd0
     170:      	mov	x0, x22
     174:      	mov	w2, #0x1                ; =1
     178:      	stur	x8, [x29, #-0xb0]
     17c:      	bl	0x17c <ltmp0+0x17c>
     180:      	cbnz	w0, 0x410 <ltmp0+0x410>
     184:      	add	x25, x19, #0xb0
     188:      	ldur	x8, [x29, #-0xc0]
     18c:      	add	x1, x19, #0xc8
     190:      	ldr	q0, [x25, #0x30]
     194:      	add	x2, x19, #0xb0
     198:      	mov	x0, x22
     19c:      	stur	x8, [x29, #-0x50]
     1a0:      	str	q0, [x25, #0xa0]
     1a4:      	ldur	x9, [x29, #-0x58]
     1a8:      	str	x9, [x19, #0xd0]
     1ac:      	bl	0x1ac <ltmp0+0x1ac>
     1b0:      	cbnz	w0, 0x420 <ltmp0+0x420>
     1b4:      	ldr	q0, [x25]
     1b8:      	ldr	x10, [x19, #0xc0]
     1bc:      	mov	w8, #0x1                ; =1
     1c0:      	add	x9, x19, #0x80
     1c4:      	add	x1, x19, #0x80
     1c8:      	add	x3, x19, #0x68
     1cc:      	mov	x0, x22
     1d0:      	mov	w2, #0x2                ; =2
     1d4:      	str	x8, [x19, #0x88]
     1d8:      	stur	q0, [x9, #0x18]
     1dc:      	stur	x10, [x9, #0x28]
     1e0:      	bl	0x1e0 <ltmp0+0x1e0>
     1e4:      	cbnz	w0, 0x430 <ltmp0+0x430>
     1e8:      	ldp	x8, x9, [x19, #0x70]
     1ec:      	cmp	x24, #0x1
     1f0:      	ldur	q0, [x19, #0x68]
     1f4:      	str	q0, [x25, #0x80]
     1f8:      	stur	x9, [x29, #-0x70]
     1fc:      	b.eq	0x440 <ltmp0+0x440>
     200:      	ldr	x9, [x8, #0x8]
     204:      	cmp	x9, #0x1
     208:      	b.ne	0x364 <ltmp0+0x364>
     20c:      	cmp	x24, #0x2
     210:      	b.eq	0x45c <ltmp0+0x45c>
     214:      	ldr	x8, [x8, #0x20]
     218:      	add	x1, x19, #0x50
     21c:      	add	x2, x19, #0x38
     220:      	mov	x0, x22
     224:      	ldr	x8, [x8, #0x8]
     228:      	str	x8, [x19, #0x58]
     22c:      	bl	0x22c <ltmp0+0x22c>
     230:      	cbnz	w0, 0x4cc <ltmp0+0x4cc>
     234:      	ldp	x9, x10, [x19, #0x40]
     238:      	ldur	q0, [x19, #0x38]
     23c:      	ldr	x8, [x21, #0x8]
     240:      	ldrb	w11, [x19, #0x39]
     244:      	str	q0, [x25, #0x60]
     248:      	stur	x10, [x29, #-0x90]
     24c:      	cbz	x8, 0x37c <ltmp0+0x37c>
     250:      	add	x12, x19, #0x38
     254:      	cmp	w11, #0xff
     258:      	ldr	x0, [x21]
     25c:      	orr	x12, x12, #0x2
     260:      	csel	x2, x10, x11, eq
     264:      	csel	x1, x9, x12, eq
     268:      	blr	x8
     26c:      	cmn	w0, #0x1
     270:      	b.eq	0x4dc <ltmp0+0x4dc>
     274:      	cmp	w0, #0x2
     278:      	b.hs	0x37c <ltmp0+0x37c>
     27c:      	sub	x1, x29, #0xa0
     280:      	add	x2, x19, #0x20
     284:      	mov	x0, x22
     288:      	bl	0x288 <ltmp0+0x288>
     28c:      	ldur	x8, [x29, #-0x78]
     290:      	add	x1, x19, #0x8
     294:      	mov	x0, x22
     298:      	str	x8, [x19, #0x10]
     29c:      	bl	0x29c <ltmp0+0x29c>
     2a0:      	cbnz	w0, 0x4e8 <ltmp0+0x4e8>
     2a4:      	add	x1, x19, #0x68
     2a8:      	sub	x2, x29, #0x80
     2ac:      	mov	x0, x22
     2b0:      	bl	0x2b0 <ltmp0+0x2b0>
     2b4:      	sub	x1, x29, #0xd0
     2b8:      	sub	x2, x29, #0x60
     2bc:      	mov	x0, x22
     2c0:      	bl	0x2c0 <ltmp0+0x2c0>
     2c4:      	mov	x0, x22
     2c8:      	mov	x1, x23
     2cc:      	bl	0x2cc <ltmp0+0x2cc>
     2d0:      	mov	w1, wzr
     2d4:      	mov	x0, x22
     2d8:      	bl	0x2d8 <ltmp0+0x2d8>
     2dc:      	mov	w23, w0
     2e0:      	cmp	w0, #0x2
     2e4:      	b.eq	0x304 <ltmp0+0x304>
     2e8:      	ldr	x21, [x21, #0x18]
     2ec:      	cbz	x21, 0x304 <ltmp0+0x304>
     2f0:      	mov	x0, x22
     2f4:      	bl	0x2f4 <ltmp0+0x2f4>
     2f8:      	mov	x1, x0
     2fc:      	mov	x0, x20
     300:      	blr	x21
     304:      	mov	x0, x22
     308:      	bl	0x308 <ltmp0+0x308>
     30c:      	mov	w0, w23
     310:      	sub	sp, x29, #0x40
     314:      	ldp	x29, x30, [sp, #0x40]
     318:      	ldp	x20, x19, [sp, #0x30]
     31c:      	ldp	x22, x21, [sp, #0x20]
     320:      	ldp	x24, x23, [sp, #0x10]
     324:      	ldp	x26, x25, [sp], #0x50
     328:      	ret
     32c:      	mov	w24, #0x100             ; =256
     330:      	adrp	x0, 0x0 <ltmp0>
     334:      	add	x0, x0, #0x0
     338:      	mov	w1, #0x3                ; =3
     33c:      	bl	0x33c <ltmp0+0x33c>
     340:      	cbnz	x0, 0x50 <ltmp0+0x50>
     344:      	mov	w23, #0x2               ; =2
     348:      	b	0x30c <ltmp0+0x30c>
     34c:      	adrp	x2, 0x0 <ltmp0>
     350:      	add	x2, x2, #0x0
     354:      	mov	x0, x22
     358:      	mov	w1, #0xd                ; =13
     35c:      	mov	w3, #0x16               ; =22
     360:      	b	0x3d4 <ltmp0+0x3d4>
     364:      	adrp	x2, 0x0 <ltmp0>
     368:      	add	x2, x2, #0x0
     36c:      	mov	x0, x22
     370:      	mov	w1, #0xe                ; =14
     374:      	mov	w3, #0x15               ; =21
     378:      	b	0x470 <ltmp0+0x470>
     37c:      	adrp	x2, 0x0 <ltmp0>
     380:      	add	x2, x2, #0x0
     384:      	mov	x0, x22
     388:      	mov	w1, #0x9                ; =9
     38c:      	mov	w3, #0x18               ; =24
     390:      	bl	0x390 <ltmp0+0x390>
     394:      	mov	x0, x22
     398:      	mov	w1, #0x1                ; =1
     39c:      	mov	w2, #0xd                ; =13
     3a0:      	b	0x490 <ltmp0+0x490>
     3a4:      	adrp	x2, 0x0 <ltmp0>
     3a8:      	add	x2, x2, #0x0
     3ac:      	mov	x0, x22
     3b0:      	mov	w1, #0x6                ; =6
     3b4:      	mov	w3, #0x13               ; =19
     3b8:      	bl	0x3b8 <ltmp0+0x3b8>
     3bc:      	b	0x4a0 <ltmp0+0x4a0>
     3c0:      	adrp	x2, 0x0 <ltmp0>
     3c4:      	add	x2, x2, #0x0
     3c8:      	mov	x0, x22
     3cc:      	mov	w1, #0xe                ; =14
     3d0:      	mov	w3, #0x15               ; =21
     3d4:      	bl	0x3d4 <ltmp0+0x3d4>
     3d8:      	mov	x0, x22
     3dc:      	mov	w1, #0x1                ; =1
     3e0:      	mov	w2, #0x1                ; =1
     3e4:      	b	0x490 <ltmp0+0x490>
     3e8:      	adrp	x2, 0x0 <ltmp0>
     3ec:      	add	x2, x2, #0x0
     3f0:      	mov	x0, x22
     3f4:      	mov	w1, wzr
     3f8:      	mov	w3, #0x10               ; =16
     3fc:      	bl	0x3fc <ltmp0+0x3fc>
     400:      	mov	x0, x22
     404:      	mov	w1, #0x1                ; =1
     408:      	mov	w2, #0x3                ; =3
     40c:      	b	0x490 <ltmp0+0x490>
     410:      	mov	x0, x22
     414:      	mov	w1, #0x1                ; =1
     418:      	mov	w2, #0x4                ; =4
     41c:      	b	0x490 <ltmp0+0x490>
     420:      	mov	x0, x22
     424:      	mov	w1, #0x1                ; =1
     428:      	mov	w2, #0x7                ; =7
     42c:      	b	0x490 <ltmp0+0x490>
     430:      	mov	x0, x22
     434:      	mov	w1, #0x1                ; =1
     438:      	mov	w2, #0x8                ; =8
     43c:      	b	0x490 <ltmp0+0x490>
     440:      	adrp	x2, 0x0 <ltmp0>
     444:      	add	x2, x2, #0x0
     448:      	mov	x0, x22
     44c:      	mov	w1, #0x6                ; =6
     450:      	mov	w3, #0x13               ; =19
     454:      	bl	0x454 <ltmp0+0x454>
     458:      	b	0x484 <ltmp0+0x484>
     45c:      	adrp	x2, 0x0 <ltmp0>
     460:      	add	x2, x2, #0x0
     464:      	mov	x0, x22
     468:      	mov	w1, #0x6                ; =6
     46c:      	mov	w3, #0x13               ; =19
     470:      	bl	0x470 <ltmp0+0x470>
     474:      	mov	x0, x22
     478:      	mov	w1, wzr
     47c:      	mov	w2, #0x1                ; =1
     480:      	bl	0x480 <ltmp0+0x480>
     484:      	mov	x0, x22
     488:      	mov	w1, #0x1                ; =1
     48c:      	mov	w2, #0xa                ; =10
     490:      	bl	0x490 <ltmp0+0x490>
     494:      	mov	x0, x22
     498:      	mov	x1, x23
     49c:      	bl	0x49c <ltmp0+0x49c>
     4a0:      	ldr	x2, [x21, #0x10]
     4a4:      	mov	x0, x22
     4a8:      	mov	x1, x20
     4ac:      	bl	0x4ac <ltmp0+0x4ac>
     4b0:      	mov	w1, #0x1                ; =1
     4b4:      	mov	x0, x22
     4b8:      	bl	0x4b8 <ltmp0+0x4b8>
     4bc:      	mov	w23, w0
     4c0:      	cmp	w0, #0x2
     4c4:      	b.ne	0x2e8 <ltmp0+0x2e8>
     4c8:      	b	0x304 <ltmp0+0x304>
     4cc:      	mov	x0, x22
     4d0:      	mov	w1, #0x1                ; =1
     4d4:      	mov	w2, #0xb                ; =11
     4d8:      	b	0x490 <ltmp0+0x490>
     4dc:      	mov	x0, x22
     4e0:      	bl	0x4e0 <ltmp0+0x4e0>
     4e4:      	b	0x494 <ltmp0+0x494>
     4e8:      	mov	x0, x22
     4ec:      	mov	w1, #0x1                ; =1
     4f0:      	mov	w2, #0x12               ; =18
     4f4:      	b	0x490 <ltmp0+0x490>
