
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/structures.o:	file format mach-o arm64

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
      2c:      	cbz	x8, 0x58 <ltmp0+0x58>
      30:      	mov	x0, x20
      34:      	blr	x8
      38:      	mov	x24, x0
      3c:      	adrp	x0, 0x0 <ltmp0>
      40:      	add	x0, x0, #0x0
      44:      	mov	w1, #0x2                ; =2
      48:      	mov	w23, #0x2               ; =2
      4c:      	bl	0x4c <ltmp0+0x4c>
      50:      	cbnz	x0, 0x74 <ltmp0+0x74>
      54:      	b	0x304 <ltmp0+0x304>
      58:      	mov	w24, #0x100             ; =256
      5c:      	adrp	x0, 0x0 <ltmp0>
      60:      	add	x0, x0, #0x0
      64:      	mov	w1, #0x2                ; =2
      68:      	mov	w23, #0x2               ; =2
      6c:      	bl	0x6c <ltmp0+0x6c>
      70:      	cbz	x0, 0x304 <ltmp0+0x304>
      74:      	ldp	x3, x4, [x21, #0x1b0]
      78:      	mov	x22, x0
      7c:      	ldp	x5, x6, [x21, #0x1c0]
      80:      	ldr	x2, [x21, #0xe0]
      84:      	ldp	x8, x9, [x21, #0xf8]
      88:      	ldr	x7, [x21, #0x1d0]
      8c:      	ldur	q0, [x21, #0xe8]
      90:      	sub	sp, sp, #0x20
      94:      	mov	x1, x20
      98:      	stp	x8, x9, [sp, #0x10]
      9c:      	str	q0, [sp]
      a0:      	bl	0xa0 <ltmp0+0xa0>
      a4:      	add	sp, sp, #0x20
      a8:      	ldp	x2, x3, [x21, #0x180]
      ac:      	mov	x0, x22
      b0:      	ldp	x4, x5, [x21, #0x190]
      b4:      	mov	x1, x20
      b8:      	ldr	x6, [x21, #0x1a0]
      bc:      	bl	0xbc <ltmp0+0xbc>
      c0:      	ldp	x8, x9, [x21, #0x170]
      c4:      	ldp	x2, x3, [x21, #0x140]
      c8:      	ldp	x4, x5, [x21, #0x150]
      cc:      	ldp	x6, x7, [x21, #0x160]
      d0:      	stp	x8, x9, [sp, #-0x10]!
      d4:      	mov	x0, x22
      d8:      	mov	x1, x20
      dc:      	bl	0xdc <ltmp0+0xdc>
      e0:      	add	sp, sp, #0x10
      e4:      	cmp	x24, #0x0
      e8:      	b.le	0x364 <ltmp0+0x364>
      ec:      	sub	x23, sp, #0x20
      f0:      	mov	sp, x23
      f4:      	ldp	x2, x3, [x21, #0x20]
      f8:      	mov	x0, x22
      fc:      	mov	x1, x20
     100:      	mov	x4, x23
     104:      	bl	0x104 <ltmp0+0x104>
     108:      	cbnz	w0, 0x42c <ltmp0+0x42c>
     10c:      	mov	w8, #0x5                ; =5
     110:      	mov	w9, #0x2                ; =2
     114:      	str	xzr, [x19, #0x90]
     118:      	sturb	w8, [x29, #-0xb8]
     11c:      	mov	w8, #0xff04             ; =65284
     120:      	strh	w8, [x19, #0xb0]
     124:      	adrp	x8, 0x0 <ltmp0>
     128:      	add	x8, x8, #0x0
     12c:      	str	x8, [x19, #0xb8]
     130:      	ldr	x8, [x23, #0x8]
     134:      	stur	x9, [x29, #-0xa8]
     138:      	cmn	w8, #0x1
     13c:      	strb	w9, [x19, #0x80]
     140:      	strb	w9, [x19, #0x98]
     144:      	str	xzr, [x19, #0xa8]
     148:      	strb	w9, [x19, #0x50]
     14c:      	str	xzr, [x19, #0x60]
     150:      	b.eq	0x380 <ltmp0+0x380>
     154:      	mov	w9, #0x70               ; =112
     158:      	ldr	x10, [x22, #0x60]
     15c:      	umaddl	x9, w8, w9, x10
     160:      	lsr	x8, x8, #32
     164:      	ldr	w10, [x9, #0x60]
     168:      	cmp	w10, w8
     16c:      	b.ne	0x324 <ltmp0+0x324>
     170:      	tbnz	w8, #0x0, 0x324 <ltmp0+0x324>
     174:      	ldr	x8, [x9, #0x10]
     178:      	mov	w9, #0x2                ; =2
     17c:      	add	x1, x19, #0x80
     180:      	add	x3, x19, #0x68
     184:      	mov	x0, x22
     188:      	mov	w2, #0x2                ; =2
     18c:      	str	x8, [x19, #0x88]
     190:      	str	x9, [x19, #0xa0]
     194:      	bl	0x194 <ltmp0+0x194>
     198:      	cbnz	w0, 0x3a8 <ltmp0+0x3a8>
     19c:      	ldur	q0, [x19, #0x68]
     1a0:      	ldr	x8, [x19, #0x78]
     1a4:      	add	x25, x19, #0xb0
     1a8:      	cmp	x24, #0x1
     1ac:      	str	q0, [x25, #0x30]
     1b0:      	stur	x8, [x29, #-0x90]
     1b4:      	b.eq	0x3b8 <ltmp0+0x3b8>
     1b8:      	ldur	x8, [x29, #-0x98]
     1bc:      	mov	w9, #0x2                ; =2
     1c0:      	stur	xzr, [x29, #-0x60]
     1c4:      	sturb	w9, [x29, #-0x70]
     1c8:      	ldr	x10, [x8, #0x8]
     1cc:      	sturb	w9, [x29, #-0x58]
     1d0:      	stur	xzr, [x29, #-0x48]
     1d4:      	adds	x9, x10, #0x3
     1d8:      	b.vs	0x3d4 <ltmp0+0x3d4>
     1dc:      	ldr	x8, [x8, #0x20]
     1e0:      	adds	x8, x8, #0x4
     1e4:      	b.vs	0x3dc <ltmp0+0x3dc>
     1e8:      	sub	x1, x29, #0x70
     1ec:      	sub	x3, x29, #0x88
     1f0:      	mov	x0, x22
     1f4:      	mov	w2, #0x2                ; =2
     1f8:      	stur	x9, [x29, #-0x68]
     1fc:      	stur	x8, [x29, #-0x50]
     200:      	bl	0x200 <ltmp0+0x200>
     204:      	cbnz	w0, 0x3fc <ltmp0+0x3fc>
     208:      	ldur	x9, [x29, #-0x80]
     20c:      	mov	w8, #0x5                ; =5
     210:      	mov	w12, #0x2               ; =2
     214:      	sturb	w8, [x29, #-0xb8]
     218:      	ldr	x10, [x9, #0x8]
     21c:      	ldr	x11, [x9, #0x20]
     220:      	stp	x9, x12, [x29, #-0xb0]
     224:      	adds	x8, x10, x11
     228:      	b.vs	0x458 <ltmp0+0x458>
     22c:      	add	x1, x19, #0x50
     230:      	add	x2, x19, #0x38
     234:      	mov	x0, x22
     238:      	str	x8, [x19, #0x58]
     23c:      	bl	0x23c <ltmp0+0x23c>
     240:      	cbnz	w0, 0x480 <ltmp0+0x480>
     244:      	ldp	x9, x10, [x19, #0x40]
     248:      	ldur	q0, [x19, #0x38]
     24c:      	ldr	x8, [x21, #0x8]
     250:      	ldrb	w11, [x19, #0x39]
     254:      	str	q0, [x25]
     258:      	str	x10, [x19, #0xc0]
     25c:      	cbz	x8, 0x33c <ltmp0+0x33c>
     260:      	add	x12, x19, #0x38
     264:      	cmp	w11, #0xff
     268:      	ldr	x0, [x21]
     26c:      	orr	x12, x12, #0x2
     270:      	csel	x2, x10, x11, eq
     274:      	csel	x1, x9, x12, eq
     278:      	blr	x8
     27c:      	cmn	w0, #0x1
     280:      	b.eq	0x490 <ltmp0+0x490>
     284:      	cmp	w0, #0x2
     288:      	b.hs	0x33c <ltmp0+0x33c>
     28c:      	add	x1, x19, #0xb0
     290:      	add	x2, x19, #0x20
     294:      	mov	x0, x22
     298:      	bl	0x298 <ltmp0+0x298>
     29c:      	sub	x1, x29, #0xb8
     2a0:      	add	x2, x19, #0x8
     2a4:      	mov	x0, x22
     2a8:      	bl	0x2a8 <ltmp0+0x2a8>
     2ac:      	add	x1, x19, #0x68
     2b0:      	sub	x2, x29, #0xa0
     2b4:      	mov	x0, x22
     2b8:      	bl	0x2b8 <ltmp0+0x2b8>
     2bc:      	mov	x0, x22
     2c0:      	mov	x1, x23
     2c4:      	bl	0x2c4 <ltmp0+0x2c4>
     2c8:      	mov	w1, wzr
     2cc:      	mov	x0, x22
     2d0:      	bl	0x2d0 <ltmp0+0x2d0>
     2d4:      	mov	w23, w0
     2d8:      	cmp	w0, #0x2
     2dc:      	b.eq	0x2fc <ltmp0+0x2fc>
     2e0:      	ldr	x21, [x21, #0x18]
     2e4:      	cbz	x21, 0x2fc <ltmp0+0x2fc>
     2e8:      	mov	x0, x22
     2ec:      	bl	0x2ec <ltmp0+0x2ec>
     2f0:      	mov	x1, x0
     2f4:      	mov	x0, x20
     2f8:      	blr	x21
     2fc:      	mov	x0, x22
     300:      	bl	0x300 <ltmp0+0x300>
     304:      	mov	w0, w23
     308:      	sub	sp, x29, #0x40
     30c:      	ldp	x29, x30, [sp, #0x40]
     310:      	ldp	x20, x19, [sp, #0x30]
     314:      	ldp	x22, x21, [sp, #0x20]
     318:      	ldp	x24, x23, [sp, #0x10]
     31c:      	ldp	x26, x25, [sp], #0x50
     320:      	ret
     324:      	adrp	x2, 0x0 <ltmp0>
     328:      	add	x2, x2, #0x0
     32c:      	mov	x0, x22
     330:      	mov	w1, #0xd                ; =13
     334:      	mov	w3, #0x16               ; =22
     338:      	b	0x394 <ltmp0+0x394>
     33c:      	adrp	x2, 0x0 <ltmp0>
     340:      	add	x2, x2, #0x0
     344:      	mov	x0, x22
     348:      	mov	w1, #0x9                ; =9
     34c:      	mov	w3, #0x18               ; =24
     350:      	bl	0x350 <ltmp0+0x350>
     354:      	mov	x0, x22
     358:      	mov	w1, wzr
     35c:      	mov	w2, #0x11               ; =17
     360:      	b	0x41c <ltmp0+0x41c>
     364:      	adrp	x2, 0x0 <ltmp0>
     368:      	add	x2, x2, #0x0
     36c:      	mov	x0, x22
     370:      	mov	w1, #0x6                ; =6
     374:      	mov	w3, #0x13               ; =19
     378:      	bl	0x378 <ltmp0+0x378>
     37c:      	b	0x42c <ltmp0+0x42c>
     380:      	adrp	x2, 0x0 <ltmp0>
     384:      	add	x2, x2, #0x0
     388:      	mov	x0, x22
     38c:      	mov	w1, #0xe                ; =14
     390:      	mov	w3, #0x15               ; =21
     394:      	bl	0x394 <ltmp0+0x394>
     398:      	mov	x0, x22
     39c:      	mov	w1, wzr
     3a0:      	mov	w2, #0x1                ; =1
     3a4:      	b	0x41c <ltmp0+0x41c>
     3a8:      	mov	x0, x22
     3ac:      	mov	w1, wzr
     3b0:      	mov	w2, #0x3                ; =3
     3b4:      	b	0x41c <ltmp0+0x41c>
     3b8:      	adrp	x2, 0x0 <ltmp0>
     3bc:      	add	x2, x2, #0x0
     3c0:      	mov	x0, x22
     3c4:      	mov	w1, #0x6                ; =6
     3c8:      	mov	w3, #0x13               ; =19
     3cc:      	bl	0x3cc <ltmp0+0x3cc>
     3d0:      	b	0x410 <ltmp0+0x410>
     3d4:      	mov	w24, #0x3               ; =3
     3d8:      	b	0x3e0 <ltmp0+0x3e0>
     3dc:      	mov	w24, #0x7               ; =7
     3e0:      	adrp	x2, 0x0 <ltmp0>
     3e4:      	add	x2, x2, #0x0
     3e8:      	mov	x0, x22
     3ec:      	mov	w1, wzr
     3f0:      	mov	w3, #0x10               ; =16
     3f4:      	bl	0x3f4 <ltmp0+0x3f4>
     3f8:      	b	0x400 <ltmp0+0x400>
     3fc:      	mov	w24, #0x8               ; =8
     400:      	mov	x0, x22
     404:      	mov	w1, #0x1                ; =1
     408:      	mov	w2, w24
     40c:      	bl	0x40c <ltmp0+0x40c>
     410:      	mov	x0, x22
     414:      	mov	w1, wzr
     418:      	mov	w2, #0x8                ; =8
     41c:      	bl	0x41c <ltmp0+0x41c>
     420:      	mov	x0, x22
     424:      	mov	x1, x23
     428:      	bl	0x428 <ltmp0+0x428>
     42c:      	ldr	x2, [x21, #0x10]
     430:      	mov	x0, x22
     434:      	mov	x1, x20
     438:      	bl	0x438 <ltmp0+0x438>
     43c:      	mov	w1, #0x1                ; =1
     440:      	mov	x0, x22
     444:      	bl	0x444 <ltmp0+0x444>
     448:      	mov	w23, w0
     44c:      	cmp	w0, #0x2
     450:      	b.ne	0x2e0 <ltmp0+0x2e0>
     454:      	b	0x2fc <ltmp0+0x2fc>
     458:      	adrp	x2, 0x0 <ltmp0>
     45c:      	add	x2, x2, #0x0
     460:      	mov	x0, x22
     464:      	mov	w1, wzr
     468:      	mov	w3, #0x10               ; =16
     46c:      	bl	0x46c <ltmp0+0x46c>
     470:      	mov	x0, x22
     474:      	mov	w1, wzr
     478:      	mov	w2, #0xe                ; =14
     47c:      	b	0x41c <ltmp0+0x41c>
     480:      	mov	x0, x22
     484:      	mov	w1, wzr
     488:      	mov	w2, #0xf                ; =15
     48c:      	b	0x41c <ltmp0+0x41c>
     490:      	mov	x0, x22
     494:      	bl	0x494 <ltmp0+0x494>
     498:      	b	0x420 <ltmp0+0x420>
