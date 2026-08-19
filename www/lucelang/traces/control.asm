
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/control.o:	file format mach-o arm64

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
      1c:      	sub	sp, sp, #0xa0
      20:      	ldr	x8, [x0, #0x70]
      24:      	ldr	x19, [x0]
      28:      	mov	x20, x0
      2c:      	cbz	x8, 0x1d8 <ltmp0+0x1d8>
      30:      	mov	x0, x19
      34:      	blr	x8
      38:      	cmp	x0, #0x1
      3c:      	cset	w22, lt
      40:      	adrp	x0, 0x0 <ltmp0>
      44:      	add	x0, x0, #0x0
      48:      	mov	w1, #0x1                ; =1
      4c:      	bl	0x4c <ltmp0+0x4c>
      50:      	cbz	x0, 0x1f0 <ltmp0+0x1f0>
      54:      	ldp	x3, x4, [x20, #0x1b0]
      58:      	mov	x21, x0
      5c:      	ldp	x5, x6, [x20, #0x1c0]
      60:      	ldr	x2, [x20, #0xe0]
      64:      	ldp	x8, x9, [x20, #0xf8]
      68:      	ldr	x7, [x20, #0x1d0]
      6c:      	ldur	q0, [x20, #0xe8]
      70:      	sub	sp, sp, #0x20
      74:      	mov	x1, x19
      78:      	stp	x8, x9, [sp, #0x10]
      7c:      	str	q0, [sp]
      80:      	bl	0x80 <ltmp0+0x80>
      84:      	add	sp, sp, #0x20
      88:      	ldp	x2, x3, [x20, #0x180]
      8c:      	mov	x0, x21
      90:      	ldp	x4, x5, [x20, #0x190]
      94:      	mov	x1, x19
      98:      	ldr	x6, [x20, #0x1a0]
      9c:      	bl	0x9c <ltmp0+0x9c>
      a0:      	ldp	x8, x9, [x20, #0x170]
      a4:      	ldp	x2, x3, [x20, #0x140]
      a8:      	ldp	x4, x5, [x20, #0x150]
      ac:      	ldp	x6, x7, [x20, #0x160]
      b0:      	stp	x8, x9, [sp, #-0x10]!
      b4:      	mov	x0, x21
      b8:      	mov	x1, x19
      bc:      	bl	0xbc <ltmp0+0xbc>
      c0:      	add	sp, sp, #0x10
      c4:      	cbnz	w22, 0x388 <ltmp0+0x388>
      c8:      	sub	x22, sp, #0x20
      cc:      	mov	sp, x22
      d0:      	ldp	x2, x3, [x20, #0x20]
      d4:      	mov	x0, x21
      d8:      	mov	x1, x19
      dc:      	mov	x4, x22
      e0:      	bl	0xe0 <ltmp0+0xe0>
      e4:      	cbnz	w0, 0x31c <ltmp0+0x31c>
      e8:      	ldr	x8, [x22, #0x8]
      ec:      	mov	w9, #0xff04             ; =65284
      f0:      	mov	w10, #0x70              ; =112
      f4:      	sturh	w9, [x29, #-0x88]
      f8:      	ldr	x12, [x21, #0x60]
      fc:      	mov	w11, #0x2               ; =2
     100:      	mov	w9, w8
     104:      	cmn	w8, #0x1
     108:      	sturb	w11, [x29, #-0xb8]
     10c:      	umaddl	x10, w9, w10, x12
     110:      	adrp	x9, 0x0 <ltmp0>
     114:      	add	x9, x9, #0x0
     118:      	stur	xzr, [x29, #-0xa8]
     11c:      	csel	x9, x9, x10, eq
     120:      	b.eq	0x2e8 <ltmp0+0x2e8>
     124:      	ldr	w10, [x10, #0x60]
     128:      	lsr	x8, x8, #32
     12c:      	cmp	w10, w8
     130:      	b.ne	0x348 <ltmp0+0x348>
     134:      	tbnz	w10, #0x0, 0x348 <ltmp0+0x348>
     138:      	ldr	x24, [x9, #0x10]
     13c:      	cmp	x24, #0x1
     140:      	b.lt	0x1f8 <ltmp0+0x1f8>
     144:      	ldr	x8, [x9]
     148:      	mov	x23, xzr
     14c:      	mov	x25, xzr
     150:      	add	x26, x8, #0x10
     154:      	add	x27, x8, #0x2
     158:      	b	0x170 <ltmp0+0x170>
     15c:      	add	x25, x25, #0x1
     160:      	add	x26, x26, #0x18
     164:      	add	x27, x27, #0x18
     168:      	cmp	x25, x24
     16c:      	b.ge	0x1fc <ltmp0+0x1fc>
     170:      	ldurb	w8, [x26, #-0xf]
     174:      	ldp	x9, x10, [x26, #-0x8]
     178:      	sub	x1, x29, #0x88
     17c:      	sub	x2, x29, #0xa0
     180:      	mov	x0, x21
     184:      	cmp	w8, #0xff
     188:      	csel	x9, x9, x27, eq
     18c:      	csel	x8, x10, x8, eq
     190:      	stp	x9, x8, [x29, #-0x80]
     194:      	bl	0x194 <ltmp0+0x194>
     198:      	cbnz	w0, 0x2d8 <ltmp0+0x2d8>
     19c:      	ldur	x8, [x29, #-0x98]
     1a0:      	cmp	x8, #0x2
     1a4:      	b.le	0x15c <ltmp0+0x15c>
     1a8:      	adds	x23, x23, #0x1
     1ac:      	b.vc	0x15c <ltmp0+0x15c>
     1b0:      	adrp	x2, 0x0 <ltmp0>
     1b4:      	add	x2, x2, #0x0
     1b8:      	mov	x0, x21
     1bc:      	mov	w1, wzr
     1c0:      	mov	w3, #0x10               ; =16
     1c4:      	bl	0x1c4 <ltmp0+0x1c4>
     1c8:      	mov	x0, x21
     1cc:      	mov	w1, wzr
     1d0:      	mov	w2, #0x17               ; =23
     1d4:      	b	0x30c <ltmp0+0x30c>
     1d8:      	mov	w22, wzr
     1dc:      	adrp	x0, 0x0 <ltmp0>
     1e0:      	add	x0, x0, #0x0
     1e4:      	mov	w1, #0x1                ; =1
     1e8:      	bl	0x1e8 <ltmp0+0x1e8>
     1ec:      	cbnz	x0, 0x54 <ltmp0+0x54>
     1f0:      	mov	w22, #0x2               ; =2
     1f4:      	b	0x2b4 <ltmp0+0x2b4>
     1f8:      	mov	x23, xzr
     1fc:      	sub	x1, x29, #0xb8
     200:      	sub	x2, x29, #0xd0
     204:      	mov	x0, x21
     208:      	stur	x23, [x29, #-0xb0]
     20c:      	bl	0x20c <ltmp0+0x20c>
     210:      	cbnz	w0, 0x3a4 <ltmp0+0x3a4>
     214:      	ldp	x9, x10, [x29, #-0xc8]
     218:      	ldur	q0, [x29, #-0xd0]
     21c:      	ldr	x8, [x20, #0x8]
     220:      	ldurb	w11, [x29, #-0xcf]
     224:      	stur	q0, [x29, #-0x70]
     228:      	stur	x10, [x29, #-0x60]
     22c:      	cbz	x8, 0x360 <ltmp0+0x360>
     230:      	sub	x12, x29, #0xd0
     234:      	cmp	w11, #0xff
     238:      	ldr	x0, [x20]
     23c:      	orr	x12, x12, #0x2
     240:      	csel	x2, x10, x11, eq
     244:      	csel	x1, x9, x12, eq
     248:      	blr	x8
     24c:      	cmn	w0, #0x1
     250:      	b.eq	0x3b4 <ltmp0+0x3b4>
     254:      	cmp	w0, #0x2
     258:      	b.hs	0x360 <ltmp0+0x360>
     25c:      	sub	x1, x29, #0x70
     260:      	sub	x2, x29, #0xe8
     264:      	mov	x0, x21
     268:      	bl	0x268 <ltmp0+0x268>
     26c:      	mov	x0, x21
     270:      	mov	x1, x22
     274:      	bl	0x274 <ltmp0+0x274>
     278:      	mov	w1, wzr
     27c:      	mov	x0, x21
     280:      	bl	0x280 <ltmp0+0x280>
     284:      	mov	w22, w0
     288:      	cmp	w0, #0x2
     28c:      	b.eq	0x2ac <ltmp0+0x2ac>
     290:      	ldr	x20, [x20, #0x18]
     294:      	cbz	x20, 0x2ac <ltmp0+0x2ac>
     298:      	mov	x0, x21
     29c:      	bl	0x29c <ltmp0+0x29c>
     2a0:      	mov	x1, x0
     2a4:      	mov	x0, x19
     2a8:      	blr	x20
     2ac:      	mov	x0, x21
     2b0:      	bl	0x2b0 <ltmp0+0x2b0>
     2b4:      	mov	w0, w22
     2b8:      	sub	sp, x29, #0x50
     2bc:      	ldp	x29, x30, [sp, #0x50]
     2c0:      	ldp	x20, x19, [sp, #0x40]
     2c4:      	ldp	x22, x21, [sp, #0x30]
     2c8:      	ldp	x24, x23, [sp, #0x20]
     2cc:      	ldp	x26, x25, [sp, #0x10]
     2d0:      	ldp	x28, x27, [sp], #0x60
     2d4:      	ret
     2d8:      	mov	x0, x21
     2dc:      	mov	w1, wzr
     2e0:      	mov	w2, #0x11               ; =17
     2e4:      	b	0x30c <ltmp0+0x30c>
     2e8:      	adrp	x2, 0x0 <ltmp0>
     2ec:      	add	x2, x2, #0x0
     2f0:      	mov	x0, x21
     2f4:      	mov	w1, #0xe                ; =14
     2f8:      	mov	w3, #0x15               ; =21
     2fc:      	bl	0x2fc <ltmp0+0x2fc>
     300:      	mov	x0, x21
     304:      	mov	w1, wzr
     308:      	mov	w2, #0x8                ; =8
     30c:      	bl	0x30c <ltmp0+0x30c>
     310:      	mov	x0, x21
     314:      	mov	x1, x22
     318:      	bl	0x318 <ltmp0+0x318>
     31c:      	ldr	x2, [x20, #0x10]
     320:      	mov	x0, x21
     324:      	mov	x1, x19
     328:      	bl	0x328 <ltmp0+0x328>
     32c:      	mov	w1, #0x1                ; =1
     330:      	mov	x0, x21
     334:      	bl	0x334 <ltmp0+0x334>
     338:      	mov	w22, w0
     33c:      	cmp	w0, #0x2
     340:      	b.ne	0x290 <ltmp0+0x290>
     344:      	b	0x2ac <ltmp0+0x2ac>
     348:      	adrp	x2, 0x0 <ltmp0>
     34c:      	add	x2, x2, #0x0
     350:      	mov	x0, x21
     354:      	mov	w1, #0xd                ; =13
     358:      	mov	w3, #0x16               ; =22
     35c:      	b	0x2fc <ltmp0+0x2fc>
     360:      	adrp	x2, 0x0 <ltmp0>
     364:      	add	x2, x2, #0x0
     368:      	mov	x0, x21
     36c:      	mov	w1, #0x9                ; =9
     370:      	mov	w3, #0x18               ; =24
     374:      	bl	0x374 <ltmp0+0x374>
     378:      	mov	x0, x21
     37c:      	mov	w1, wzr
     380:      	mov	w2, #0x23               ; =35
     384:      	b	0x30c <ltmp0+0x30c>
     388:      	adrp	x2, 0x0 <ltmp0>
     38c:      	add	x2, x2, #0x0
     390:      	mov	x0, x21
     394:      	mov	w1, #0x6                ; =6
     398:      	mov	w3, #0x13               ; =19
     39c:      	bl	0x39c <ltmp0+0x39c>
     3a0:      	b	0x31c <ltmp0+0x31c>
     3a4:      	mov	x0, x21
     3a8:      	mov	w1, wzr
     3ac:      	mov	w2, #0x21               ; =33
     3b0:      	b	0x30c <ltmp0+0x30c>
     3b4:      	mov	x0, x21
     3b8:      	bl	0x3b8 <ltmp0+0x3b8>
     3bc:      	b	0x310 <ltmp0+0x310>
