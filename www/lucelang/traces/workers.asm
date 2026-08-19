
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/workers.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce.worker():
       0:      	cbz	x2, 0xc <ltmp0+0xc>
       4:      	mov	w0, #0x1                ; =1
       8:      	ret
       c:      	ldr	x9, [x3, #0x8]
      10:      	mul	x8, x9, x9
      14:      	smulh	x9, x9, x9
      18:      	cmp	x9, x8, asr #63
      1c:      	b.ne	0x34 <ltmp0+0x34>
      20:      	mov	w0, wzr
      24:      	mov	w9, #0x2                ; =2
      28:      	stp	x8, xzr, [x5, #0x8]
      2c:      	strb	w9, [x5]
      30:      	ret
      34:      	stp	x20, x19, [sp, #-0x20]!
      38:      	adrp	x2, 0x0 <ltmp0>
      3c:      	add	x2, x2, #0x0
      40:      	mov	x0, x1
      44:      	mov	x19, x1
      48:      	mov	w1, wzr
      4c:      	mov	w3, #0x10               ; =16
      50:      	stp	x29, x30, [sp, #0x10]
      54:      	bl	0x54 <ltmp0+0x54>
      58:      	mov	x0, x19
      5c:      	mov	w1, wzr
      60:      	mov	w2, #0x2                ; =2
      64:      	bl	0x64 <ltmp0+0x64>
      68:      	ldp	x29, x30, [sp, #0x10]
      6c:      	mov	w0, #0x1                ; =1
      70:      	ldp	x20, x19, [sp], #0x20
      74:      	ret

0000000000000078 <_luce_main>:
; luce_main():
      78:      	stp	x28, x27, [sp, #-0x60]!
      7c:      	stp	x26, x25, [sp, #0x10]
      80:      	stp	x24, x23, [sp, #0x20]
      84:      	stp	x22, x21, [sp, #0x30]
      88:      	stp	x20, x19, [sp, #0x40]
      8c:      	stp	x29, x30, [sp, #0x50]
      90:      	add	x29, sp, #0x50
      94:      	sub	sp, sp, #0xe0
      98:      	ldr	x8, [x0, #0x70]
      9c:      	ldr	x19, [x0]
      a0:      	mov	x20, x0
      a4:      	cbz	x8, 0xd0 <_luce_main+0x58>
      a8:      	mov	x0, x19
      ac:      	blr	x8
      b0:      	mov	x22, x0
      b4:      	adrp	x0, 0x0 <ltmp0>
      b8:      	add	x0, x0, #0x0
      bc:      	mov	w1, #0x2                ; =2
      c0:      	mov	w23, #0x2               ; =2
      c4:      	bl	0xc4 <_luce_main+0x4c>
      c8:      	cbnz	x0, 0xec <_luce_main+0x74>
      cc:      	b	0x330 <_luce_main+0x2b8>
      d0:      	mov	w22, #0x100             ; =256
      d4:      	adrp	x0, 0x0 <ltmp0>
      d8:      	add	x0, x0, #0x0
      dc:      	mov	w1, #0x2                ; =2
      e0:      	mov	w23, #0x2               ; =2
      e4:      	bl	0xe4 <_luce_main+0x6c>
      e8:      	cbz	x0, 0x330 <_luce_main+0x2b8>
      ec:      	ldp	x3, x4, [x20, #0x1b0]
      f0:      	mov	x21, x0
      f4:      	ldp	x5, x6, [x20, #0x1c0]
      f8:      	ldr	x2, [x20, #0xe0]
      fc:      	ldp	x8, x9, [x20, #0xf8]
     100:      	ldr	x7, [x20, #0x1d0]
     104:      	ldur	q0, [x20, #0xe8]
     108:      	sub	sp, sp, #0x20
     10c:      	mov	x1, x19
     110:      	stp	x8, x9, [sp, #0x10]
     114:      	str	q0, [sp]
     118:      	bl	0x118 <_luce_main+0xa0>
     11c:      	add	sp, sp, #0x20
     120:      	ldp	x2, x3, [x20, #0x180]
     124:      	mov	x0, x21
     128:      	ldp	x4, x5, [x20, #0x190]
     12c:      	mov	x1, x19
     130:      	ldr	x6, [x20, #0x1a0]
     134:      	bl	0x134 <_luce_main+0xbc>
     138:      	ldp	x8, x9, [x20, #0x170]
     13c:      	ldp	x2, x3, [x20, #0x140]
     140:      	ldp	x4, x5, [x20, #0x150]
     144:      	ldp	x6, x7, [x20, #0x160]
     148:      	stp	x8, x9, [sp, #-0x10]!
     14c:      	mov	x0, x21
     150:      	mov	x1, x19
     154:      	bl	0x154 <_luce_main+0xdc>
     158:      	add	sp, sp, #0x10
     15c:      	ldp	x2, x3, [x20, #0x108]
     160:      	adrp	x5, 0x0 <ltmp0>
     164:      	add	x5, x5, #0x0
     168:      	mov	x0, x21
     16c:      	mov	x1, x19
     170:      	mov	x4, x20
     174:      	mov	x6, x22
     178:      	bl	0x178 <_luce_main+0x100>
     17c:      	cmp	x22, #0x0
     180:      	b.le	0x394 <_luce_main+0x31c>
     184:      	sub	x22, sp, #0x20
     188:      	mov	sp, x22
     18c:      	ldp	x2, x3, [x20, #0x20]
     190:      	mov	x0, x21
     194:      	mov	x1, x19
     198:      	mov	x4, x22
     19c:      	bl	0x19c <_luce_main+0x124>
     1a0:      	cbnz	w0, 0x458 <_luce_main+0x3e0>
     1a4:      	mov	w9, #0x2                ; =2
     1a8:      	ldr	x8, [x22, #0x8]
     1ac:      	mov	w10, #0x6               ; =6
     1b0:      	sturb	w9, [x29, #-0x88]
     1b4:      	sturb	w9, [x29, #-0xe8]
     1b8:      	sub	x9, x29, #0x30
     1bc:      	cmn	w8, #0x1
     1c0:      	sturb	w10, [x9, #-0x100]
     1c4:      	sub	x9, x29, #0x20
     1c8:      	stur	xzr, [x29, #-0x78]
     1cc:      	sturb	w10, [x29, #-0xd0]
     1d0:      	stur	xzr, [x29, #-0xc0]
     1d4:      	stur	xzr, [x29, #-0xd8]
     1d8:      	stur	xzr, [x9, #-0x100]
     1dc:      	b.eq	0x3b0 <_luce_main+0x338>
     1e0:      	mov	w9, #0x70               ; =112
     1e4:      	ldr	x10, [x21, #0x60]
     1e8:      	umaddl	x9, w8, w9, x10
     1ec:      	lsr	x8, x8, #32
     1f0:      	ldr	w10, [x9, #0x60]
     1f4:      	cmp	w10, w8
     1f8:      	b.ne	0x354 <_luce_main+0x2dc>
     1fc:      	tbnz	w8, #0x0, 0x354 <_luce_main+0x2dc>
     200:      	ldr	x8, [x9, #0x10]
     204:      	adds	x8, x8, #0x2
     208:      	b.vs	0x3d8 <_luce_main+0x360>
     20c:      	sub	x2, x29, #0x88
     210:      	sub	x4, x29, #0xa0
     214:      	mov	x0, x21
     218:      	mov	x1, xzr
     21c:      	mov	w3, #0x1                ; =1
     220:      	stur	x8, [x29, #-0x80]
     224:      	bl	0x224 <_luce_main+0x1ac>
     228:      	cbnz	w0, 0x400 <_luce_main+0x388>
     22c:      	ldur	x24, [x29, #-0x98]
     230:      	sub	x1, x29, #0xd0
     234:      	sub	x2, x29, #0xb8
     238:      	mov	x0, x21
     23c:      	stur	x24, [x29, #-0xc8]
     240:      	bl	0x240 <_luce_main+0x1c8>
     244:      	cbnz	w0, 0x410 <_luce_main+0x398>
     248:      	ldur	x8, [x29, #-0xb0]
     24c:      	sub	x1, x29, #0xe8
     250:      	sub	x2, x29, #0x100
     254:      	mov	x0, x21
     258:      	stur	x8, [x29, #-0xe0]
     25c:      	bl	0x25c <_luce_main+0x1e4>
     260:      	cbnz	w0, 0x420 <_luce_main+0x3a8>
     264:      	ldp	x23, x25, [x29, #-0xf8]
     268:      	mov	x0, x21
     26c:      	ldur	q0, [x29, #-0x100]
     270:      	ldurb	w26, [x29, #-0xff]
     274:      	stur	q0, [x29, #-0x70]
     278:      	stur	x25, [x29, #-0x60]
     27c:      	bl	0x27c <_luce_main+0x204>
     280:      	ldr	x8, [x20, #0x8]
     284:      	cbz	x8, 0x36c <_luce_main+0x2f4>
     288:      	sub	x9, x29, #0x100
     28c:      	cmp	w26, #0xff
     290:      	ldr	x0, [x20]
     294:      	orr	x9, x9, #0x2
     298:      	csel	x2, x25, x26, eq
     29c:      	csel	x1, x23, x9, eq
     2a0:      	blr	x8
     2a4:      	mov	w23, w0
     2a8:      	mov	x0, x21
     2ac:      	bl	0x2ac <_luce_main+0x234>
     2b0:      	cmn	w23, #0x1
     2b4:      	b.eq	0x430 <_luce_main+0x3b8>
     2b8:      	cmp	w23, #0x2
     2bc:      	b.hs	0x36c <_luce_main+0x2f4>
     2c0:      	sub	x1, x29, #0x70
     2c4:      	sub	x2, x29, #0x118
     2c8:      	mov	x0, x21
     2cc:      	bl	0x2cc <_luce_main+0x254>
     2d0:      	sub	x8, x29, #0x28
     2d4:      	sub	x1, x29, #0x130
     2d8:      	mov	x0, x21
     2dc:      	stur	x24, [x8, #-0x100]
     2e0:      	bl	0x2e0 <_luce_main+0x268>
     2e4:      	cbnz	w0, 0x43c <_luce_main+0x3c4>
     2e8:      	mov	x0, x21
     2ec:      	mov	x1, x22
     2f0:      	bl	0x2f0 <_luce_main+0x278>
     2f4:      	mov	w1, wzr
     2f8:      	mov	x0, x21
     2fc:      	bl	0x2fc <_luce_main+0x284>
     300:      	mov	w23, w0
     304:      	cmp	w0, #0x2
     308:      	b.eq	0x328 <_luce_main+0x2b0>
     30c:      	ldr	x20, [x20, #0x18]
     310:      	cbz	x20, 0x328 <_luce_main+0x2b0>
     314:      	mov	x0, x21
     318:      	bl	0x318 <_luce_main+0x2a0>
     31c:      	mov	x1, x0
     320:      	mov	x0, x19
     324:      	blr	x20
     328:      	mov	x0, x21
     32c:      	bl	0x32c <_luce_main+0x2b4>
     330:      	mov	w0, w23
     334:      	sub	sp, x29, #0x50
     338:      	ldp	x29, x30, [sp, #0x50]
     33c:      	ldp	x20, x19, [sp, #0x40]
     340:      	ldp	x22, x21, [sp, #0x30]
     344:      	ldp	x24, x23, [sp, #0x20]
     348:      	ldp	x26, x25, [sp, #0x10]
     34c:      	ldp	x28, x27, [sp], #0x60
     350:      	ret
     354:      	adrp	x2, 0x0 <ltmp0>
     358:      	add	x2, x2, #0x0
     35c:      	mov	x0, x21
     360:      	mov	w1, #0xd                ; =13
     364:      	mov	w3, #0x16               ; =22
     368:      	b	0x3c4 <_luce_main+0x34c>
     36c:      	adrp	x2, 0x0 <ltmp0>
     370:      	add	x2, x2, #0x0
     374:      	mov	x0, x21
     378:      	mov	w1, #0x9                ; =9
     37c:      	mov	w3, #0x18               ; =24
     380:      	bl	0x380 <_luce_main+0x308>
     384:      	mov	x0, x21
     388:      	mov	w1, #0x1                ; =1
     38c:      	mov	w2, #0xa                ; =10
     390:      	b	0x448 <_luce_main+0x3d0>
     394:      	adrp	x2, 0x0 <ltmp0>
     398:      	add	x2, x2, #0x0
     39c:      	mov	x0, x21
     3a0:      	mov	w1, #0x6                ; =6
     3a4:      	mov	w3, #0x13               ; =19
     3a8:      	bl	0x3a8 <_luce_main+0x330>
     3ac:      	b	0x458 <_luce_main+0x3e0>
     3b0:      	adrp	x2, 0x0 <ltmp0>
     3b4:      	add	x2, x2, #0x0
     3b8:      	mov	x0, x21
     3bc:      	mov	w1, #0xe                ; =14
     3c0:      	mov	w3, #0x15               ; =21
     3c4:      	bl	0x3c4 <_luce_main+0x34c>
     3c8:      	mov	x0, x21
     3cc:      	mov	w1, #0x1                ; =1
     3d0:      	mov	w2, #0x1                ; =1
     3d4:      	b	0x448 <_luce_main+0x3d0>
     3d8:      	adrp	x2, 0x0 <ltmp0>
     3dc:      	add	x2, x2, #0x0
     3e0:      	mov	x0, x21
     3e4:      	mov	w1, wzr
     3e8:      	mov	w3, #0x10               ; =16
     3ec:      	bl	0x3ec <_luce_main+0x374>
     3f0:      	mov	x0, x21
     3f4:      	mov	w1, #0x1                ; =1
     3f8:      	mov	w2, #0x3                ; =3
     3fc:      	b	0x448 <_luce_main+0x3d0>
     400:      	mov	x0, x21
     404:      	mov	w1, #0x1                ; =1
     408:      	mov	w2, #0x4                ; =4
     40c:      	b	0x448 <_luce_main+0x3d0>
     410:      	mov	x0, x21
     414:      	mov	w1, #0x1                ; =1
     418:      	mov	w2, #0x7                ; =7
     41c:      	b	0x448 <_luce_main+0x3d0>
     420:      	mov	x0, x21
     424:      	mov	w1, #0x1                ; =1
     428:      	mov	w2, #0x8                ; =8
     42c:      	b	0x448 <_luce_main+0x3d0>
     430:      	mov	x0, x21
     434:      	bl	0x434 <_luce_main+0x3bc>
     438:      	b	0x44c <_luce_main+0x3d4>
     43c:      	mov	x0, x21
     440:      	mov	w1, #0x1                ; =1
     444:      	mov	w2, #0xf                ; =15
     448:      	bl	0x448 <_luce_main+0x3d0>
     44c:      	mov	x0, x21
     450:      	mov	x1, x22
     454:      	bl	0x454 <_luce_main+0x3dc>
     458:      	ldr	x2, [x20, #0x10]
     45c:      	mov	x0, x21
     460:      	mov	x1, x19
     464:      	bl	0x464 <_luce_main+0x3ec>
     468:      	mov	w1, #0x1                ; =1
     46c:      	mov	x0, x21
     470:      	bl	0x470 <_luce_main+0x3f8>
     474:      	mov	w23, w0
     478:      	cmp	w0, #0x2
     47c:      	b.ne	0x30c <_luce_main+0x294>
     480:      	b	0x328 <_luce_main+0x2b0>
