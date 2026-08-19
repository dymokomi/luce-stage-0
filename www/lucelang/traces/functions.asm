
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/functions.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce.0.factorial():
       0:      	sub	sp, sp, #0x40
       4:      	stp	x20, x19, [sp, #0x20]
       8:      	mov	x19, x3
       c:      	cmp	x2, #0x2
      10:      	stp	x22, x21, [sp, #0x10]
      14:      	stp	x29, x30, [sp, #0x30]
      18:      	b.ge	0x3c <ltmp0+0x3c>
      1c:      	mov	w0, wzr
      20:      	mov	w8, #0x1                ; =1
      24:      	str	x8, [x19]
      28:      	ldp	x29, x30, [sp, #0x30]
      2c:      	ldp	x20, x19, [sp, #0x20]
      30:      	ldp	x22, x21, [sp, #0x10]
      34:      	add	sp, sp, #0x40
      38:      	ret
      3c:      	cmp	x1, #0x1
      40:      	b.ls	0x90 <ltmp0+0x90>
      44:      	mov	x20, x2
      48:      	sub	x1, x1, #0x1
      4c:      	sub	x2, x2, #0x1
      50:      	add	x3, sp, #0x8
      54:      	mov	x21, x0
      58:      	bl	0x0 <ltmp0>
      5c:      	cbnz	w0, 0xb0 <ltmp0+0xb0>
      60:      	ldr	x9, [sp, #0x8]
      64:      	mul	x8, x20, x9
      68:      	smulh	x9, x20, x9
      6c:      	cmp	x9, x8, asr #63
      70:      	b.ne	0xc0 <ltmp0+0xc0>
      74:      	mov	w0, wzr
      78:      	str	x8, [x19]
      7c:      	ldp	x29, x30, [sp, #0x30]
      80:      	ldp	x20, x19, [sp, #0x20]
      84:      	ldp	x22, x21, [sp, #0x10]
      88:      	add	sp, sp, #0x40
      8c:      	ret
      90:      	adrp	x2, 0x0 <ltmp0>
      94:      	add	x2, x2, #0x0
      98:      	mov	w1, #0x6                ; =6
      9c:      	mov	w3, #0x13               ; =19
      a0:      	mov	x19, x0
      a4:      	bl	0xa4 <ltmp0+0xa4>
      a8:      	mov	x0, x19
      ac:      	b	0xb4 <ltmp0+0xb4>
      b0:      	mov	x0, x21
      b4:      	mov	w1, wzr
      b8:      	mov	w2, #0xa                ; =10
      bc:      	b	0xe4 <ltmp0+0xe4>
      c0:      	adrp	x2, 0x0 <ltmp0>
      c4:      	add	x2, x2, #0x0
      c8:      	mov	x0, x21
      cc:      	mov	w1, wzr
      d0:      	mov	w3, #0x10               ; =16
      d4:      	bl	0xd4 <ltmp0+0xd4>
      d8:      	mov	x0, x21
      dc:      	mov	w1, wzr
      e0:      	mov	w2, #0xb                ; =11
      e4:      	bl	0xe4 <ltmp0+0xe4>
      e8:      	mov	w0, #0x1                ; =1
      ec:      	ldp	x29, x30, [sp, #0x30]
      f0:      	ldp	x20, x19, [sp, #0x20]
      f4:      	ldp	x22, x21, [sp, #0x10]
      f8:      	add	sp, sp, #0x40
      fc:      	ret

0000000000000100 <_luce_main>:
; luce_main():
     100:      	stp	x24, x23, [sp, #-0x40]!
     104:      	stp	x22, x21, [sp, #0x10]
     108:      	stp	x20, x19, [sp, #0x20]
     10c:      	stp	x29, x30, [sp, #0x30]
     110:      	add	x29, sp, #0x30
     114:      	sub	sp, sp, #0x70
     118:      	ldr	x8, [x0, #0x70]
     11c:      	ldr	x19, [x0]
     120:      	mov	x20, x0
     124:      	cbz	x8, 0x150 <_luce_main+0x50>
     128:      	mov	x0, x19
     12c:      	blr	x8
     130:      	mov	x23, x0
     134:      	adrp	x0, 0x0 <ltmp0>
     138:      	add	x0, x0, #0x0
     13c:      	mov	w1, #0x2                ; =2
     140:      	mov	w22, #0x2               ; =2
     144:      	bl	0x144 <_luce_main+0x44>
     148:      	cbnz	x0, 0x16c <_luce_main+0x6c>
     14c:      	b	0x320 <_luce_main+0x220>
     150:      	mov	w23, #0x100             ; =256
     154:      	adrp	x0, 0x0 <ltmp0>
     158:      	add	x0, x0, #0x0
     15c:      	mov	w1, #0x2                ; =2
     160:      	mov	w22, #0x2               ; =2
     164:      	bl	0x164 <_luce_main+0x64>
     168:      	cbz	x0, 0x320 <_luce_main+0x220>
     16c:      	ldp	x3, x4, [x20, #0x1b0]
     170:      	mov	x21, x0
     174:      	ldp	x5, x6, [x20, #0x1c0]
     178:      	ldr	x2, [x20, #0xe0]
     17c:      	ldp	x8, x9, [x20, #0xf8]
     180:      	ldr	x7, [x20, #0x1d0]
     184:      	ldur	q0, [x20, #0xe8]
     188:      	sub	sp, sp, #0x20
     18c:      	mov	x1, x19
     190:      	stp	x8, x9, [sp, #0x10]
     194:      	str	q0, [sp]
     198:      	bl	0x198 <_luce_main+0x98>
     19c:      	add	sp, sp, #0x20
     1a0:      	ldp	x2, x3, [x20, #0x180]
     1a4:      	mov	x0, x21
     1a8:      	ldp	x4, x5, [x20, #0x190]
     1ac:      	mov	x1, x19
     1b0:      	ldr	x6, [x20, #0x1a0]
     1b4:      	bl	0x1b4 <_luce_main+0xb4>
     1b8:      	ldp	x8, x9, [x20, #0x170]
     1bc:      	ldp	x2, x3, [x20, #0x140]
     1c0:      	ldp	x4, x5, [x20, #0x150]
     1c4:      	ldp	x6, x7, [x20, #0x160]
     1c8:      	stp	x8, x9, [sp, #-0x10]!
     1cc:      	mov	x0, x21
     1d0:      	mov	x1, x19
     1d4:      	bl	0x1d4 <_luce_main+0xd4>
     1d8:      	add	sp, sp, #0x10
     1dc:      	cmp	x23, #0x0
     1e0:      	b.le	0x37c <_luce_main+0x27c>
     1e4:      	sub	x22, sp, #0x20
     1e8:      	mov	sp, x22
     1ec:      	ldp	x2, x3, [x20, #0x20]
     1f0:      	mov	x0, x21
     1f4:      	mov	x1, x19
     1f8:      	mov	x4, x22
     1fc:      	bl	0x1fc <_luce_main+0xfc>
     200:      	cbnz	w0, 0x42c <_luce_main+0x32c>
     204:      	ldr	x8, [x22, #0x8]
     208:      	mov	w9, #0x2                ; =2
     20c:      	stur	xzr, [x29, #-0x60]
     210:      	sturb	w9, [x29, #-0x70]
     214:      	cmn	w8, #0x1
     218:      	b.eq	0x398 <_luce_main+0x298>
     21c:      	mov	w9, #0x70               ; =112
     220:      	ldr	x10, [x21, #0x60]
     224:      	umaddl	x9, w8, w9, x10
     228:      	lsr	x8, x8, #32
     22c:      	ldr	w10, [x9, #0x60]
     230:      	cmp	w10, w8
     234:      	b.ne	0x33c <_luce_main+0x23c>
     238:      	tbnz	w8, #0x0, 0x33c <_luce_main+0x23c>
     23c:      	ldr	x8, [x9, #0x10]
     240:      	adds	x2, x8, #0x1
     244:      	b.vs	0x3c0 <_luce_main+0x2c0>
     248:      	cmp	x23, #0x1
     24c:      	b.eq	0x3e8 <_luce_main+0x2e8>
     250:      	sub	x1, x23, #0x1
     254:      	sub	x3, x29, #0x58
     258:      	mov	x0, x21
     25c:      	bl	0x25c <_luce_main+0x15c>
     260:      	cbnz	w0, 0x400 <_luce_main+0x300>
     264:      	ldur	x8, [x29, #-0x58]
     268:      	sub	x1, x29, #0x70
     26c:      	sub	x2, x29, #0x88
     270:      	mov	x0, x21
     274:      	stur	x8, [x29, #-0x68]
     278:      	bl	0x278 <_luce_main+0x178>
     27c:      	cbnz	w0, 0x410 <_luce_main+0x310>
     280:      	ldp	x9, x10, [x29, #-0x80]
     284:      	ldur	q0, [x29, #-0x88]
     288:      	ldr	x8, [x20, #0x8]
     28c:      	ldurb	w11, [x29, #-0x87]
     290:      	stur	q0, [x29, #-0x50]
     294:      	stur	x10, [x29, #-0x40]
     298:      	cbz	x8, 0x354 <_luce_main+0x254>
     29c:      	sub	x12, x29, #0x88
     2a0:      	cmp	w11, #0xff
     2a4:      	ldr	x0, [x20]
     2a8:      	orr	x12, x12, #0x2
     2ac:      	csel	x2, x10, x11, eq
     2b0:      	csel	x1, x9, x12, eq
     2b4:      	blr	x8
     2b8:      	cmn	w0, #0x1
     2bc:      	b.eq	0x458 <_luce_main+0x358>
     2c0:      	cmp	w0, #0x2
     2c4:      	b.hs	0x354 <_luce_main+0x254>
     2c8:      	sub	x1, x29, #0x50
     2cc:      	sub	x2, x29, #0xa0
     2d0:      	mov	x0, x21
     2d4:      	bl	0x2d4 <_luce_main+0x1d4>
     2d8:      	mov	x0, x21
     2dc:      	mov	x1, x22
     2e0:      	bl	0x2e0 <_luce_main+0x1e0>
     2e4:      	mov	w1, wzr
     2e8:      	mov	x0, x21
     2ec:      	bl	0x2ec <_luce_main+0x1ec>
     2f0:      	mov	w22, w0
     2f4:      	cmp	w0, #0x2
     2f8:      	b.eq	0x318 <_luce_main+0x218>
     2fc:      	ldr	x20, [x20, #0x18]
     300:      	cbz	x20, 0x318 <_luce_main+0x218>
     304:      	mov	x0, x21
     308:      	bl	0x308 <_luce_main+0x208>
     30c:      	mov	x1, x0
     310:      	mov	x0, x19
     314:      	blr	x20
     318:      	mov	x0, x21
     31c:      	bl	0x31c <_luce_main+0x21c>
     320:      	mov	w0, w22
     324:      	sub	sp, x29, #0x30
     328:      	ldp	x29, x30, [sp, #0x30]
     32c:      	ldp	x20, x19, [sp, #0x20]
     330:      	ldp	x22, x21, [sp, #0x10]
     334:      	ldp	x24, x23, [sp], #0x40
     338:      	ret
     33c:      	adrp	x2, 0x0 <ltmp0>
     340:      	add	x2, x2, #0x0
     344:      	mov	x0, x21
     348:      	mov	w1, #0xd                ; =13
     34c:      	mov	w3, #0x16               ; =22
     350:      	b	0x3ac <_luce_main+0x2ac>
     354:      	adrp	x2, 0x0 <ltmp0>
     358:      	add	x2, x2, #0x0
     35c:      	mov	x0, x21
     360:      	mov	w1, #0x9                ; =9
     364:      	mov	w3, #0x18               ; =24
     368:      	bl	0x368 <_luce_main+0x268>
     36c:      	mov	x0, x21
     370:      	mov	w1, #0x1                ; =1
     374:      	mov	w2, #0x7                ; =7
     378:      	b	0x41c <_luce_main+0x31c>
     37c:      	adrp	x2, 0x0 <ltmp0>
     380:      	add	x2, x2, #0x0
     384:      	mov	x0, x21
     388:      	mov	w1, #0x6                ; =6
     38c:      	mov	w3, #0x13               ; =19
     390:      	bl	0x390 <_luce_main+0x290>
     394:      	b	0x42c <_luce_main+0x32c>
     398:      	adrp	x2, 0x0 <ltmp0>
     39c:      	add	x2, x2, #0x0
     3a0:      	mov	x0, x21
     3a4:      	mov	w1, #0xe                ; =14
     3a8:      	mov	w3, #0x15               ; =21
     3ac:      	bl	0x3ac <_luce_main+0x2ac>
     3b0:      	mov	x0, x21
     3b4:      	mov	w1, #0x1                ; =1
     3b8:      	mov	w2, #0x1                ; =1
     3bc:      	b	0x41c <_luce_main+0x31c>
     3c0:      	adrp	x2, 0x0 <ltmp0>
     3c4:      	add	x2, x2, #0x0
     3c8:      	mov	x0, x21
     3cc:      	mov	w1, wzr
     3d0:      	mov	w3, #0x10               ; =16
     3d4:      	bl	0x3d4 <_luce_main+0x2d4>
     3d8:      	mov	x0, x21
     3dc:      	mov	w1, #0x1                ; =1
     3e0:      	mov	w2, #0x3                ; =3
     3e4:      	b	0x41c <_luce_main+0x31c>
     3e8:      	adrp	x2, 0x0 <ltmp0>
     3ec:      	add	x2, x2, #0x0
     3f0:      	mov	x0, x21
     3f4:      	mov	w1, #0x6                ; =6
     3f8:      	mov	w3, #0x13               ; =19
     3fc:      	bl	0x3fc <_luce_main+0x2fc>
     400:      	mov	x0, x21
     404:      	mov	w1, #0x1                ; =1
     408:      	mov	w2, #0x4                ; =4
     40c:      	b	0x41c <_luce_main+0x31c>
     410:      	mov	x0, x21
     414:      	mov	w1, #0x1                ; =1
     418:      	mov	w2, #0x5                ; =5
     41c:      	bl	0x41c <_luce_main+0x31c>
     420:      	mov	x0, x21
     424:      	mov	x1, x22
     428:      	bl	0x428 <_luce_main+0x328>
     42c:      	ldr	x2, [x20, #0x10]
     430:      	mov	x0, x21
     434:      	mov	x1, x19
     438:      	bl	0x438 <_luce_main+0x338>
     43c:      	mov	w1, #0x1                ; =1
     440:      	mov	x0, x21
     444:      	bl	0x444 <_luce_main+0x344>
     448:      	mov	w22, w0
     44c:      	cmp	w0, #0x2
     450:      	b.ne	0x2fc <_luce_main+0x1fc>
     454:      	b	0x318 <_luce_main+0x218>
     458:      	mov	x0, x21
     45c:      	bl	0x45c <_luce_main+0x35c>
     460:      	b	0x420 <_luce_main+0x320>
