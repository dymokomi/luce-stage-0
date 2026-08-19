
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/text.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce_main():
       0:      	stp	x24, x23, [sp, #-0x40]!
       4:      	stp	x22, x21, [sp, #0x10]
       8:      	stp	x20, x19, [sp, #0x20]
       c:      	stp	x29, x30, [sp, #0x30]
      10:      	add	x29, sp, #0x30
      14:      	sub	sp, sp, #0xf0
      18:      	ldr	x8, [x0, #0x70]
      1c:      	ldr	x19, [x0]
      20:      	mov	x20, x0
      24:      	cbz	x8, 0x26c <ltmp0+0x26c>
      28:      	mov	x0, x19
      2c:      	blr	x8
      30:      	cmp	x0, #0x1
      34:      	cset	w22, lt
      38:      	adrp	x0, 0x0 <ltmp0>
      3c:      	add	x0, x0, #0x0
      40:      	mov	w1, #0x1                ; =1
      44:      	bl	0x44 <ltmp0+0x44>
      48:      	cbz	x0, 0x284 <ltmp0+0x284>
      4c:      	ldp	x3, x4, [x20, #0x1b0]
      50:      	mov	x21, x0
      54:      	ldp	x5, x6, [x20, #0x1c0]
      58:      	ldr	x2, [x20, #0xe0]
      5c:      	ldp	x8, x9, [x20, #0xf8]
      60:      	ldr	x7, [x20, #0x1d0]
      64:      	ldur	q0, [x20, #0xe8]
      68:      	sub	sp, sp, #0x20
      6c:      	mov	x1, x19
      70:      	stp	x8, x9, [sp, #0x10]
      74:      	str	q0, [sp]
      78:      	bl	0x78 <ltmp0+0x78>
      7c:      	add	sp, sp, #0x20
      80:      	ldp	x2, x3, [x20, #0x180]
      84:      	mov	x0, x21
      88:      	ldp	x4, x5, [x20, #0x190]
      8c:      	mov	x1, x19
      90:      	ldr	x6, [x20, #0x1a0]
      94:      	bl	0x94 <ltmp0+0x94>
      98:      	ldp	x8, x9, [x20, #0x170]
      9c:      	ldp	x2, x3, [x20, #0x140]
      a0:      	ldp	x4, x5, [x20, #0x150]
      a4:      	ldp	x6, x7, [x20, #0x160]
      a8:      	stp	x8, x9, [sp, #-0x10]!
      ac:      	mov	x0, x21
      b0:      	mov	x1, x19
      b4:      	bl	0xb4 <ltmp0+0xb4>
      b8:      	add	sp, sp, #0x10
      bc:      	cbnz	w22, 0x2cc <ltmp0+0x2cc>
      c0:      	sub	x22, sp, #0x20
      c4:      	mov	sp, x22
      c8:      	ldp	x2, x3, [x20, #0x20]
      cc:      	mov	x0, x21
      d0:      	mov	x1, x19
      d4:      	mov	x4, x22
      d8:      	bl	0xd8 <ltmp0+0xd8>
      dc:      	cbnz	w0, 0x33c <ltmp0+0x33c>
      e0:      	ldr	x8, [x22, #0x8]
      e4:      	mov	w9, #0x2                ; =2
      e8:      	stur	xzr, [x29, #-0x78]
      ec:      	sturb	w9, [x29, #-0x88]
      f0:      	mov	w9, #0xff04             ; =65284
      f4:      	cmn	w8, #0x1
      f8:      	sturh	w9, [x29, #-0xb8]
      fc:      	sturh	w9, [x29, #-0xd0]
     100:      	b.eq	0x2e8 <ltmp0+0x2e8>
     104:      	mov	w9, #0x70               ; =112
     108:      	ldr	x10, [x21, #0x60]
     10c:      	umaddl	x9, w8, w9, x10
     110:      	lsr	x8, x8, #32
     114:      	ldr	w10, [x9, #0x60]
     118:      	cmp	w10, w8
     11c:      	b.ne	0x28c <ltmp0+0x28c>
     120:      	tbnz	w8, #0x0, 0x28c <ltmp0+0x28c>
     124:      	ldr	x8, [x9, #0x10]
     128:      	sub	x1, x29, #0x88
     12c:      	sub	x2, x29, #0xa0
     130:      	mov	x0, x21
     134:      	stur	x8, [x29, #-0x80]
     138:      	bl	0x138 <ltmp0+0x138>
     13c:      	cbnz	w0, 0x310 <ltmp0+0x310>
     140:      	ldur	q0, [x29, #-0xa0]
     144:      	sub	x23, x29, #0x70
     148:      	ldur	x8, [x29, #-0x90]
     14c:      	sub	x9, x29, #0x50
     150:      	adrp	x10, 0x0 <ltmp0>
     154:      	add	x10, x10, #0x0
     158:      	str	q0, [x23, #0x20]
     15c:      	orr	x9, x9, #0x2
     160:      	mov	w12, #0xb               ; =11
     164:      	ldurb	w11, [x29, #-0x4f]
     168:      	ldur	x13, [x29, #-0x48]
     16c:      	stur	x8, [x29, #-0x40]
     170:      	sub	x1, x29, #0xb8
     174:      	sub	x2, x29, #0xd0
     178:      	sub	x3, x29, #0xe8
     17c:      	cmp	w11, #0xff
     180:      	mov	x0, x21
     184:      	stp	x10, x12, [x29, #-0xb0]
     188:      	csel	x9, x13, x9, eq
     18c:      	csel	x8, x8, x11, eq
     190:      	stp	x9, x8, [x29, #-0xc8]
     194:      	bl	0x194 <ltmp0+0x194>
     198:      	cbnz	w0, 0x320 <ltmp0+0x320>
     19c:      	ldur	q0, [x29, #-0xe8]
     1a0:      	ldur	x9, [x29, #-0xd8]
     1a4:      	ldr	x8, [x20, #0x8]
     1a8:      	str	q0, [x23]
     1ac:      	stur	x9, [x29, #-0x60]
     1b0:      	cbz	x8, 0x2a4 <ltmp0+0x2a4>
     1b4:      	ldurb	w9, [x29, #-0x6f]
     1b8:      	ldp	x11, x10, [x29, #-0x68]
     1bc:      	sub	x12, x29, #0x70
     1c0:      	ldr	x0, [x20]
     1c4:      	cmp	w9, #0xff
     1c8:      	orr	x12, x12, #0x2
     1cc:      	csel	x2, x10, x9, eq
     1d0:      	csel	x1, x11, x12, eq
     1d4:      	blr	x8
     1d8:      	cmn	w0, #0x1
     1dc:      	b.eq	0x368 <ltmp0+0x368>
     1e0:      	cmp	w0, #0x2
     1e4:      	b.hs	0x2a4 <ltmp0+0x2a4>
     1e8:      	sub	x1, x29, #0x70
     1ec:      	sub	x2, x29, #0x100
     1f0:      	mov	x0, x21
     1f4:      	bl	0x1f4 <ltmp0+0x1f4>
     1f8:      	sub	x1, x29, #0x50
     1fc:      	sub	x2, x29, #0x118
     200:      	mov	x0, x21
     204:      	bl	0x204 <ltmp0+0x204>
     208:      	mov	x0, x21
     20c:      	mov	x1, x22
     210:      	bl	0x210 <ltmp0+0x210>
     214:      	mov	w1, wzr
     218:      	mov	x0, x21
     21c:      	bl	0x21c <ltmp0+0x21c>
     220:      	mov	w22, w0
     224:      	cmp	w0, #0x2
     228:      	b.eq	0x248 <ltmp0+0x248>
     22c:      	ldr	x20, [x20, #0x18]
     230:      	cbz	x20, 0x248 <ltmp0+0x248>
     234:      	mov	x0, x21
     238:      	bl	0x238 <ltmp0+0x238>
     23c:      	mov	x1, x0
     240:      	mov	x0, x19
     244:      	blr	x20
     248:      	mov	x0, x21
     24c:      	bl	0x24c <ltmp0+0x24c>
     250:      	mov	w0, w22
     254:      	sub	sp, x29, #0x30
     258:      	ldp	x29, x30, [sp, #0x30]
     25c:      	ldp	x20, x19, [sp, #0x20]
     260:      	ldp	x22, x21, [sp, #0x10]
     264:      	ldp	x24, x23, [sp], #0x40
     268:      	ret
     26c:      	mov	w22, wzr
     270:      	adrp	x0, 0x0 <ltmp0>
     274:      	add	x0, x0, #0x0
     278:      	mov	w1, #0x1                ; =1
     27c:      	bl	0x27c <ltmp0+0x27c>
     280:      	cbnz	x0, 0x4c <ltmp0+0x4c>
     284:      	mov	w22, #0x2               ; =2
     288:      	b	0x250 <ltmp0+0x250>
     28c:      	adrp	x2, 0x0 <ltmp0>
     290:      	add	x2, x2, #0x0
     294:      	mov	x0, x21
     298:      	mov	w1, #0xd                ; =13
     29c:      	mov	w3, #0x16               ; =22
     2a0:      	b	0x2fc <ltmp0+0x2fc>
     2a4:      	adrp	x2, 0x0 <ltmp0>
     2a8:      	add	x2, x2, #0x0
     2ac:      	mov	x0, x21
     2b0:      	mov	w1, #0x9                ; =9
     2b4:      	mov	w3, #0x18               ; =24
     2b8:      	bl	0x2b8 <ltmp0+0x2b8>
     2bc:      	mov	x0, x21
     2c0:      	mov	w1, wzr
     2c4:      	mov	w2, #0x9                ; =9
     2c8:      	b	0x32c <ltmp0+0x32c>
     2cc:      	adrp	x2, 0x0 <ltmp0>
     2d0:      	add	x2, x2, #0x0
     2d4:      	mov	x0, x21
     2d8:      	mov	w1, #0x6                ; =6
     2dc:      	mov	w3, #0x13               ; =19
     2e0:      	bl	0x2e0 <ltmp0+0x2e0>
     2e4:      	b	0x33c <ltmp0+0x33c>
     2e8:      	adrp	x2, 0x0 <ltmp0>
     2ec:      	add	x2, x2, #0x0
     2f0:      	mov	x0, x21
     2f4:      	mov	w1, #0xe                ; =14
     2f8:      	mov	w3, #0x15               ; =21
     2fc:      	bl	0x2fc <ltmp0+0x2fc>
     300:      	mov	x0, x21
     304:      	mov	w1, wzr
     308:      	mov	w2, #0x1                ; =1
     30c:      	b	0x32c <ltmp0+0x32c>
     310:      	mov	x0, x21
     314:      	mov	w1, wzr
     318:      	mov	w2, #0x2                ; =2
     31c:      	b	0x32c <ltmp0+0x32c>
     320:      	mov	x0, x21
     324:      	mov	w1, wzr
     328:      	mov	w2, #0x6                ; =6
     32c:      	bl	0x32c <ltmp0+0x32c>
     330:      	mov	x0, x21
     334:      	mov	x1, x22
     338:      	bl	0x338 <ltmp0+0x338>
     33c:      	ldr	x2, [x20, #0x10]
     340:      	mov	x0, x21
     344:      	mov	x1, x19
     348:      	bl	0x348 <ltmp0+0x348>
     34c:      	mov	w1, #0x1                ; =1
     350:      	mov	x0, x21
     354:      	bl	0x354 <ltmp0+0x354>
     358:      	mov	w22, w0
     35c:      	cmp	w0, #0x2
     360:      	b.ne	0x22c <ltmp0+0x22c>
     364:      	b	0x248 <ltmp0+0x248>
     368:      	mov	x0, x21
     36c:      	bl	0x36c <ltmp0+0x36c>
     370:      	b	0x330 <ltmp0+0x330>
