
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/journey.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce_main():
       0:      	stp	x24, x23, [sp, #-0x40]!
       4:      	stp	x22, x21, [sp, #0x10]
       8:      	stp	x20, x19, [sp, #0x20]
       c:      	stp	x29, x30, [sp, #0x30]
      10:      	add	x29, sp, #0x30
      14:      	sub	sp, sp, #0x70
      18:      	ldr	x8, [x0, #0x70]
      1c:      	ldr	x19, [x0]
      20:      	mov	x20, x0
      24:      	cbz	x8, 0x50 <ltmp0+0x50>
      28:      	mov	x0, x19
      2c:      	blr	x8
      30:      	mov	x23, x0
      34:      	adrp	x0, 0x0 <ltmp0>
      38:      	add	x0, x0, #0x0
      3c:      	mov	w1, #0x2                ; =2
      40:      	mov	w22, #0x2               ; =2
      44:      	bl	0x44 <ltmp0+0x44>
      48:      	cbnz	x0, 0x6c <ltmp0+0x6c>
      4c:      	b	0x21c <ltmp0+0x21c>
      50:      	mov	w23, #0x100             ; =256
      54:      	adrp	x0, 0x0 <ltmp0>
      58:      	add	x0, x0, #0x0
      5c:      	mov	w1, #0x2                ; =2
      60:      	mov	w22, #0x2               ; =2
      64:      	bl	0x64 <ltmp0+0x64>
      68:      	cbz	x0, 0x21c <ltmp0+0x21c>
      6c:      	ldp	x3, x4, [x20, #0x1b0]
      70:      	mov	x21, x0
      74:      	ldp	x5, x6, [x20, #0x1c0]
      78:      	ldr	x2, [x20, #0xe0]
      7c:      	ldp	x8, x9, [x20, #0xf8]
      80:      	ldr	x7, [x20, #0x1d0]
      84:      	ldur	q0, [x20, #0xe8]
      88:      	sub	sp, sp, #0x20
      8c:      	mov	x1, x19
      90:      	stp	x8, x9, [sp, #0x10]
      94:      	str	q0, [sp]
      98:      	bl	0x98 <ltmp0+0x98>
      9c:      	add	sp, sp, #0x20
      a0:      	ldp	x2, x3, [x20, #0x180]
      a4:      	mov	x0, x21
      a8:      	ldp	x4, x5, [x20, #0x190]
      ac:      	mov	x1, x19
      b0:      	ldr	x6, [x20, #0x1a0]
      b4:      	bl	0xb4 <ltmp0+0xb4>
      b8:      	ldp	x8, x9, [x20, #0x170]
      bc:      	ldp	x2, x3, [x20, #0x140]
      c0:      	ldp	x4, x5, [x20, #0x150]
      c4:      	ldp	x6, x7, [x20, #0x160]
      c8:      	stp	x8, x9, [sp, #-0x10]!
      cc:      	mov	x0, x21
      d0:      	mov	x1, x19
      d4:      	bl	0xd4 <ltmp0+0xd4>
      d8:      	add	sp, sp, #0x10
      dc:      	cmp	x23, #0x0
      e0:      	b.le	0x278 <ltmp0+0x278>
      e4:      	sub	x22, sp, #0x20
      e8:      	mov	sp, x22
      ec:      	ldp	x2, x3, [x20, #0x20]
      f0:      	mov	x0, x21
      f4:      	mov	x1, x19
      f8:      	mov	x4, x22
      fc:      	bl	0xfc <ltmp0+0xfc>
     100:      	cbnz	w0, 0x32c <ltmp0+0x32c>
     104:      	ldr	x8, [x22, #0x8]
     108:      	mov	w9, #0x2                ; =2
     10c:      	stur	xzr, [x29, #-0x58]
     110:      	sturb	w9, [x29, #-0x68]
     114:      	cmn	w8, #0x1
     118:      	b.eq	0x294 <ltmp0+0x294>
     11c:      	mov	w9, #0x70               ; =112
     120:      	ldr	x10, [x21, #0x60]
     124:      	umaddl	x9, w8, w9, x10
     128:      	lsr	x8, x8, #32
     12c:      	ldr	w10, [x9, #0x60]
     130:      	cmp	w10, w8
     134:      	b.ne	0x238 <ltmp0+0x238>
     138:      	tbnz	w8, #0x0, 0x238 <ltmp0+0x238>
     13c:      	cmp	x23, #0x1
     140:      	b.eq	0x2bc <ltmp0+0x2bc>
     144:      	ldr	x8, [x9, #0x10]
     148:      	mov	x9, #0x4000000000000000 ; =4611686018427387904
     14c:      	cmn	x8, x9
     150:      	b.mi	0x2d8 <ltmp0+0x2d8>
     154:      	lsl	x8, x8, #1
     158:      	mov	w9, #0xa                ; =10
     15c:      	sub	x1, x29, #0x68
     160:      	sub	x2, x29, #0x80
     164:      	mov	x0, x21
     168:      	cmp	x8, #0xa
     16c:      	csel	x8, x8, x9, lt
     170:      	stur	x8, [x29, #-0x60]
     174:      	bl	0x174 <ltmp0+0x174>
     178:      	cbnz	w0, 0x310 <ltmp0+0x310>
     17c:      	ldp	x9, x10, [x29, #-0x78]
     180:      	ldur	q0, [x29, #-0x80]
     184:      	ldr	x8, [x20, #0x8]
     188:      	ldurb	w11, [x29, #-0x7f]
     18c:      	stur	q0, [x29, #-0x50]
     190:      	stur	x10, [x29, #-0x40]
     194:      	cbz	x8, 0x250 <ltmp0+0x250>
     198:      	sub	x12, x29, #0x80
     19c:      	cmp	w11, #0xff
     1a0:      	ldr	x0, [x20]
     1a4:      	orr	x12, x12, #0x2
     1a8:      	csel	x2, x10, x11, eq
     1ac:      	csel	x1, x9, x12, eq
     1b0:      	blr	x8
     1b4:      	cmn	w0, #0x1
     1b8:      	b.eq	0x358 <ltmp0+0x358>
     1bc:      	cmp	w0, #0x2
     1c0:      	b.hs	0x250 <ltmp0+0x250>
     1c4:      	sub	x1, x29, #0x50
     1c8:      	sub	x2, x29, #0x98
     1cc:      	mov	x0, x21
     1d0:      	bl	0x1d0 <ltmp0+0x1d0>
     1d4:      	mov	x0, x21
     1d8:      	mov	x1, x22
     1dc:      	bl	0x1dc <ltmp0+0x1dc>
     1e0:      	mov	w1, wzr
     1e4:      	mov	x0, x21
     1e8:      	bl	0x1e8 <ltmp0+0x1e8>
     1ec:      	mov	w22, w0
     1f0:      	cmp	w0, #0x2
     1f4:      	b.eq	0x214 <ltmp0+0x214>
     1f8:      	ldr	x20, [x20, #0x18]
     1fc:      	cbz	x20, 0x214 <ltmp0+0x214>
     200:      	mov	x0, x21
     204:      	bl	0x204 <ltmp0+0x204>
     208:      	mov	x1, x0
     20c:      	mov	x0, x19
     210:      	blr	x20
     214:      	mov	x0, x21
     218:      	bl	0x218 <ltmp0+0x218>
     21c:      	mov	w0, w22
     220:      	sub	sp, x29, #0x30
     224:      	ldp	x29, x30, [sp, #0x30]
     228:      	ldp	x20, x19, [sp, #0x20]
     22c:      	ldp	x22, x21, [sp, #0x10]
     230:      	ldp	x24, x23, [sp], #0x40
     234:      	ret
     238:      	adrp	x2, 0x0 <ltmp0>
     23c:      	add	x2, x2, #0x0
     240:      	mov	x0, x21
     244:      	mov	w1, #0xd                ; =13
     248:      	mov	w3, #0x16               ; =22
     24c:      	b	0x2a8 <ltmp0+0x2a8>
     250:      	adrp	x2, 0x0 <ltmp0>
     254:      	add	x2, x2, #0x0
     258:      	mov	x0, x21
     25c:      	mov	w1, #0x9                ; =9
     260:      	mov	w3, #0x18               ; =24
     264:      	bl	0x264 <ltmp0+0x264>
     268:      	mov	x0, x21
     26c:      	mov	w1, #0x1                ; =1
     270:      	mov	w2, #0x6                ; =6
     274:      	b	0x31c <ltmp0+0x31c>
     278:      	adrp	x2, 0x0 <ltmp0>
     27c:      	add	x2, x2, #0x0
     280:      	mov	x0, x21
     284:      	mov	w1, #0x6                ; =6
     288:      	mov	w3, #0x13               ; =19
     28c:      	bl	0x28c <ltmp0+0x28c>
     290:      	b	0x32c <ltmp0+0x32c>
     294:      	adrp	x2, 0x0 <ltmp0>
     298:      	add	x2, x2, #0x0
     29c:      	mov	x0, x21
     2a0:      	mov	w1, #0xe                ; =14
     2a4:      	mov	w3, #0x15               ; =21
     2a8:      	bl	0x2a8 <ltmp0+0x2a8>
     2ac:      	mov	x0, x21
     2b0:      	mov	w1, #0x1                ; =1
     2b4:      	mov	w2, #0x1                ; =1
     2b8:      	b	0x31c <ltmp0+0x31c>
     2bc:      	adrp	x2, 0x0 <ltmp0>
     2c0:      	add	x2, x2, #0x0
     2c4:      	mov	x0, x21
     2c8:      	mov	w1, #0x6                ; =6
     2cc:      	mov	w3, #0x13               ; =19
     2d0:      	bl	0x2d0 <ltmp0+0x2d0>
     2d4:      	b	0x300 <ltmp0+0x300>
     2d8:      	adrp	x2, 0x0 <ltmp0>
     2dc:      	add	x2, x2, #0x0
     2e0:      	mov	x0, x21
     2e4:      	mov	w1, wzr
     2e8:      	mov	w3, #0x10               ; =16
     2ec:      	bl	0x2ec <ltmp0+0x2ec>
     2f0:      	mov	x0, x21
     2f4:      	mov	w1, wzr
     2f8:      	mov	w2, #0x2                ; =2
     2fc:      	bl	0x2fc <ltmp0+0x2fc>
     300:      	mov	x0, x21
     304:      	mov	w1, #0x1                ; =1
     308:      	mov	w2, #0x3                ; =3
     30c:      	b	0x31c <ltmp0+0x31c>
     310:      	mov	x0, x21
     314:      	mov	w1, #0x1                ; =1
     318:      	mov	w2, #0x4                ; =4
     31c:      	bl	0x31c <ltmp0+0x31c>
     320:      	mov	x0, x21
     324:      	mov	x1, x22
     328:      	bl	0x328 <ltmp0+0x328>
     32c:      	ldr	x2, [x20, #0x10]
     330:      	mov	x0, x21
     334:      	mov	x1, x19
     338:      	bl	0x338 <ltmp0+0x338>
     33c:      	mov	w1, #0x1                ; =1
     340:      	mov	x0, x21
     344:      	bl	0x344 <ltmp0+0x344>
     348:      	mov	w22, w0
     34c:      	cmp	w0, #0x2
     350:      	b.ne	0x1f8 <ltmp0+0x1f8>
     354:      	b	0x214 <ltmp0+0x214>
     358:      	mov	x0, x21
     35c:      	bl	0x35c <ltmp0+0x35c>
     360:      	b	0x320 <ltmp0+0x320>
