
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/bindings.o:	file format mach-o arm64

Disassembly of section __TEXT,__text:

0000000000000000 <ltmp0>:
; luce_main():
       0:      	stp	x22, x21, [sp, #-0x30]!
       4:      	stp	x20, x19, [sp, #0x10]
       8:      	stp	x29, x30, [sp, #0x20]
       c:      	add	x29, sp, #0x20
      10:      	sub	sp, sp, #0x70
      14:      	ldr	x8, [x0, #0x70]
      18:      	ldr	x19, [x0]
      1c:      	mov	x20, x0
      20:      	cbz	x8, 0x1f0 <ltmp0+0x1f0>
      24:      	mov	x0, x19
      28:      	blr	x8
      2c:      	cmp	x0, #0x1
      30:      	cset	w22, lt
      34:      	adrp	x0, 0x0 <ltmp0>
      38:      	add	x0, x0, #0x0
      3c:      	mov	w1, #0x1                ; =1
      40:      	bl	0x40 <ltmp0+0x40>
      44:      	cbz	x0, 0x208 <ltmp0+0x208>
      48:      	ldp	x3, x4, [x20, #0x1b0]
      4c:      	mov	x21, x0
      50:      	ldp	x5, x6, [x20, #0x1c0]
      54:      	ldr	x2, [x20, #0xe0]
      58:      	ldp	x8, x9, [x20, #0xf8]
      5c:      	ldr	x7, [x20, #0x1d0]
      60:      	ldur	q0, [x20, #0xe8]
      64:      	sub	sp, sp, #0x20
      68:      	mov	x1, x19
      6c:      	stp	x8, x9, [sp, #0x10]
      70:      	str	q0, [sp]
      74:      	bl	0x74 <ltmp0+0x74>
      78:      	add	sp, sp, #0x20
      7c:      	ldp	x2, x3, [x20, #0x180]
      80:      	mov	x0, x21
      84:      	ldp	x4, x5, [x20, #0x190]
      88:      	mov	x1, x19
      8c:      	ldr	x6, [x20, #0x1a0]
      90:      	bl	0x90 <ltmp0+0x90>
      94:      	ldp	x8, x9, [x20, #0x170]
      98:      	ldp	x2, x3, [x20, #0x140]
      9c:      	ldp	x4, x5, [x20, #0x150]
      a0:      	ldp	x6, x7, [x20, #0x160]
      a4:      	stp	x8, x9, [sp, #-0x10]!
      a8:      	mov	x0, x21
      ac:      	mov	x1, x19
      b0:      	bl	0xb0 <ltmp0+0xb0>
      b4:      	add	sp, sp, #0x10
      b8:      	cbnz	w22, 0x264 <ltmp0+0x264>
      bc:      	sub	x22, sp, #0x20
      c0:      	mov	sp, x22
      c4:      	ldp	x2, x3, [x20, #0x20]
      c8:      	mov	x0, x21
      cc:      	mov	x1, x19
      d0:      	mov	x4, x22
      d4:      	bl	0xd4 <ltmp0+0xd4>
      d8:      	cbnz	w0, 0x2ec <ltmp0+0x2ec>
      dc:      	ldr	x8, [x22, #0x8]
      e0:      	mov	w9, #0x2                ; =2
      e4:      	stur	xzr, [x29, #-0x48]
      e8:      	sturb	w9, [x29, #-0x58]
      ec:      	cmn	w8, #0x1
      f0:      	b.eq	0x280 <ltmp0+0x280>
      f4:      	mov	w9, #0x70               ; =112
      f8:      	ldr	x10, [x21, #0x60]
      fc:      	umaddl	x9, w8, w9, x10
     100:      	lsr	x8, x8, #32
     104:      	ldr	w10, [x9, #0x60]
     108:      	cmp	w10, w8
     10c:      	b.ne	0x224 <ltmp0+0x224>
     110:      	tbnz	w8, #0x0, 0x224 <ltmp0+0x224>
     114:      	ldr	x8, [x9, #0x10]
     118:      	adds	x8, x8, #0x2
     11c:      	b.vs	0x2a8 <ltmp0+0x2a8>
     120:      	sub	x1, x29, #0x58
     124:      	sub	x2, x29, #0x70
     128:      	mov	x0, x21
     12c:      	stur	x8, [x29, #-0x50]
     130:      	bl	0x130 <ltmp0+0x130>
     134:      	cbnz	w0, 0x2d0 <ltmp0+0x2d0>
     138:      	ldp	x9, x10, [x29, #-0x68]
     13c:      	ldur	q0, [x29, #-0x70]
     140:      	ldr	x8, [x20, #0x8]
     144:      	ldurb	w11, [x29, #-0x6f]
     148:      	stur	q0, [x29, #-0x40]
     14c:      	stur	x10, [x29, #-0x30]
     150:      	cbz	x8, 0x23c <ltmp0+0x23c>
     154:      	sub	x12, x29, #0x70
     158:      	cmp	w11, #0xff
     15c:      	ldr	x0, [x20]
     160:      	orr	x12, x12, #0x2
     164:      	csel	x2, x10, x11, eq
     168:      	csel	x1, x9, x12, eq
     16c:      	blr	x8
     170:      	cmn	w0, #0x1
     174:      	b.eq	0x318 <ltmp0+0x318>
     178:      	cmp	w0, #0x2
     17c:      	b.hs	0x23c <ltmp0+0x23c>
     180:      	sub	x1, x29, #0x40
     184:      	sub	x2, x29, #0x88
     188:      	mov	x0, x21
     18c:      	bl	0x18c <ltmp0+0x18c>
     190:      	mov	x0, x21
     194:      	mov	x1, x22
     198:      	bl	0x198 <ltmp0+0x198>
     19c:      	mov	w1, wzr
     1a0:      	mov	x0, x21
     1a4:      	bl	0x1a4 <ltmp0+0x1a4>
     1a8:      	mov	w22, w0
     1ac:      	cmp	w0, #0x2
     1b0:      	b.eq	0x1d0 <ltmp0+0x1d0>
     1b4:      	ldr	x20, [x20, #0x18]
     1b8:      	cbz	x20, 0x1d0 <ltmp0+0x1d0>
     1bc:      	mov	x0, x21
     1c0:      	bl	0x1c0 <ltmp0+0x1c0>
     1c4:      	mov	x1, x0
     1c8:      	mov	x0, x19
     1cc:      	blr	x20
     1d0:      	mov	x0, x21
     1d4:      	bl	0x1d4 <ltmp0+0x1d4>
     1d8:      	mov	w0, w22
     1dc:      	sub	sp, x29, #0x20
     1e0:      	ldp	x29, x30, [sp, #0x20]
     1e4:      	ldp	x20, x19, [sp, #0x10]
     1e8:      	ldp	x22, x21, [sp], #0x30
     1ec:      	ret
     1f0:      	mov	w22, wzr
     1f4:      	adrp	x0, 0x0 <ltmp0>
     1f8:      	add	x0, x0, #0x0
     1fc:      	mov	w1, #0x1                ; =1
     200:      	bl	0x200 <ltmp0+0x200>
     204:      	cbnz	x0, 0x48 <ltmp0+0x48>
     208:      	mov	w22, #0x2               ; =2
     20c:      	mov	w0, w22
     210:      	sub	sp, x29, #0x20
     214:      	ldp	x29, x30, [sp, #0x20]
     218:      	ldp	x20, x19, [sp, #0x10]
     21c:      	ldp	x22, x21, [sp], #0x30
     220:      	ret
     224:      	adrp	x2, 0x0 <ltmp0>
     228:      	add	x2, x2, #0x0
     22c:      	mov	x0, x21
     230:      	mov	w1, #0xd                ; =13
     234:      	mov	w3, #0x16               ; =22
     238:      	b	0x294 <ltmp0+0x294>
     23c:      	adrp	x2, 0x0 <ltmp0>
     240:      	add	x2, x2, #0x0
     244:      	mov	x0, x21
     248:      	mov	w1, #0x9                ; =9
     24c:      	mov	w3, #0x18               ; =24
     250:      	bl	0x250 <ltmp0+0x250>
     254:      	mov	x0, x21
     258:      	mov	w1, wzr
     25c:      	mov	w2, #0xc                ; =12
     260:      	b	0x2dc <ltmp0+0x2dc>
     264:      	adrp	x2, 0x0 <ltmp0>
     268:      	add	x2, x2, #0x0
     26c:      	mov	x0, x21
     270:      	mov	w1, #0x6                ; =6
     274:      	mov	w3, #0x13               ; =19
     278:      	bl	0x278 <ltmp0+0x278>
     27c:      	b	0x2ec <ltmp0+0x2ec>
     280:      	adrp	x2, 0x0 <ltmp0>
     284:      	add	x2, x2, #0x0
     288:      	mov	x0, x21
     28c:      	mov	w1, #0xe                ; =14
     290:      	mov	w3, #0x15               ; =21
     294:      	bl	0x294 <ltmp0+0x294>
     298:      	mov	x0, x21
     29c:      	mov	w1, wzr
     2a0:      	mov	w2, #0x1                ; =1
     2a4:      	b	0x2dc <ltmp0+0x2dc>
     2a8:      	adrp	x2, 0x0 <ltmp0>
     2ac:      	add	x2, x2, #0x0
     2b0:      	mov	x0, x21
     2b4:      	mov	w1, wzr
     2b8:      	mov	w3, #0x10               ; =16
     2bc:      	bl	0x2bc <ltmp0+0x2bc>
     2c0:      	mov	x0, x21
     2c4:      	mov	w1, wzr
     2c8:      	mov	w2, #0x5                ; =5
     2cc:      	b	0x2dc <ltmp0+0x2dc>
     2d0:      	mov	x0, x21
     2d4:      	mov	w1, wzr
     2d8:      	mov	w2, #0xa                ; =10
     2dc:      	bl	0x2dc <ltmp0+0x2dc>
     2e0:      	mov	x0, x21
     2e4:      	mov	x1, x22
     2e8:      	bl	0x2e8 <ltmp0+0x2e8>
     2ec:      	ldr	x2, [x20, #0x10]
     2f0:      	mov	x0, x21
     2f4:      	mov	x1, x19
     2f8:      	bl	0x2f8 <ltmp0+0x2f8>
     2fc:      	mov	w1, #0x1                ; =1
     300:      	mov	x0, x21
     304:      	bl	0x304 <ltmp0+0x304>
     308:      	mov	w22, w0
     30c:      	cmp	w0, #0x2
     310:      	b.ne	0x1b4 <ltmp0+0x1b4>
     314:      	b	0x1d0 <ltmp0+0x1d0>
     318:      	mov	x0, x21
     31c:      	bl	0x31c <ltmp0+0x31c>
     320:      	b	0x2e0 <ltmp0+0x2e0>
