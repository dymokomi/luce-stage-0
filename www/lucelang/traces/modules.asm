
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/modules.o:	file format mach-o arm64

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
      4c:      	b	0x210 <ltmp0+0x210>
      50:      	mov	w23, #0x100             ; =256
      54:      	adrp	x0, 0x0 <ltmp0>
      58:      	add	x0, x0, #0x0
      5c:      	mov	w1, #0x2                ; =2
      60:      	mov	w22, #0x2               ; =2
      64:      	bl	0x64 <ltmp0+0x64>
      68:      	cbz	x0, 0x210 <ltmp0+0x210>
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
      e0:      	b.le	0x26c <ltmp0+0x26c>
      e4:      	sub	x22, sp, #0x20
      e8:      	mov	sp, x22
      ec:      	ldp	x2, x3, [x20, #0x20]
      f0:      	mov	x0, x21
      f4:      	mov	x1, x19
      f8:      	mov	x4, x22
      fc:      	bl	0xfc <ltmp0+0xfc>
     100:      	cbnz	w0, 0x320 <ltmp0+0x320>
     104:      	ldr	x8, [x22, #0x8]
     108:      	mov	w9, #0x2                ; =2
     10c:      	stur	xzr, [x29, #-0x58]
     110:      	sturb	w9, [x29, #-0x68]
     114:      	cmn	w8, #0x1
     118:      	b.eq	0x288 <ltmp0+0x288>
     11c:      	mov	w9, #0x70               ; =112
     120:      	ldr	x10, [x21, #0x60]
     124:      	umaddl	x9, w8, w9, x10
     128:      	lsr	x8, x8, #32
     12c:      	ldr	w10, [x9, #0x60]
     130:      	cmp	w10, w8
     134:      	b.ne	0x22c <ltmp0+0x22c>
     138:      	tbnz	w8, #0x0, 0x22c <ltmp0+0x22c>
     13c:      	cmp	x23, #0x1
     140:      	b.eq	0x2b0 <ltmp0+0x2b0>
     144:      	ldr	x8, [x9, #0x10]
     148:      	mov	x9, #0x4000000000000000 ; =4611686018427387904
     14c:      	cmn	x8, x9
     150:      	b.mi	0x2cc <ltmp0+0x2cc>
     154:      	lsl	x8, x8, #1
     158:      	sub	x1, x29, #0x68
     15c:      	sub	x2, x29, #0x80
     160:      	mov	x0, x21
     164:      	stur	x8, [x29, #-0x60]
     168:      	bl	0x168 <ltmp0+0x168>
     16c:      	cbnz	w0, 0x304 <ltmp0+0x304>
     170:      	ldp	x9, x10, [x29, #-0x78]
     174:      	ldur	q0, [x29, #-0x80]
     178:      	ldr	x8, [x20, #0x8]
     17c:      	ldurb	w11, [x29, #-0x7f]
     180:      	stur	q0, [x29, #-0x50]
     184:      	stur	x10, [x29, #-0x40]
     188:      	cbz	x8, 0x244 <ltmp0+0x244>
     18c:      	sub	x12, x29, #0x80
     190:      	cmp	w11, #0xff
     194:      	ldr	x0, [x20]
     198:      	orr	x12, x12, #0x2
     19c:      	csel	x2, x10, x11, eq
     1a0:      	csel	x1, x9, x12, eq
     1a4:      	blr	x8
     1a8:      	cmn	w0, #0x1
     1ac:      	b.eq	0x34c <ltmp0+0x34c>
     1b0:      	cmp	w0, #0x2
     1b4:      	b.hs	0x244 <ltmp0+0x244>
     1b8:      	sub	x1, x29, #0x50
     1bc:      	sub	x2, x29, #0x98
     1c0:      	mov	x0, x21
     1c4:      	bl	0x1c4 <ltmp0+0x1c4>
     1c8:      	mov	x0, x21
     1cc:      	mov	x1, x22
     1d0:      	bl	0x1d0 <ltmp0+0x1d0>
     1d4:      	mov	w1, wzr
     1d8:      	mov	x0, x21
     1dc:      	bl	0x1dc <ltmp0+0x1dc>
     1e0:      	mov	w22, w0
     1e4:      	cmp	w0, #0x2
     1e8:      	b.eq	0x208 <ltmp0+0x208>
     1ec:      	ldr	x20, [x20, #0x18]
     1f0:      	cbz	x20, 0x208 <ltmp0+0x208>
     1f4:      	mov	x0, x21
     1f8:      	bl	0x1f8 <ltmp0+0x1f8>
     1fc:      	mov	x1, x0
     200:      	mov	x0, x19
     204:      	blr	x20
     208:      	mov	x0, x21
     20c:      	bl	0x20c <ltmp0+0x20c>
     210:      	mov	w0, w22
     214:      	sub	sp, x29, #0x30
     218:      	ldp	x29, x30, [sp, #0x30]
     21c:      	ldp	x20, x19, [sp, #0x20]
     220:      	ldp	x22, x21, [sp, #0x10]
     224:      	ldp	x24, x23, [sp], #0x40
     228:      	ret
     22c:      	adrp	x2, 0x0 <ltmp0>
     230:      	add	x2, x2, #0x0
     234:      	mov	x0, x21
     238:      	mov	w1, #0xd                ; =13
     23c:      	mov	w3, #0x16               ; =22
     240:      	b	0x29c <ltmp0+0x29c>
     244:      	adrp	x2, 0x0 <ltmp0>
     248:      	add	x2, x2, #0x0
     24c:      	mov	x0, x21
     250:      	mov	w1, #0x9                ; =9
     254:      	mov	w3, #0x18               ; =24
     258:      	bl	0x258 <ltmp0+0x258>
     25c:      	mov	x0, x21
     260:      	mov	w1, wzr
     264:      	mov	w2, #0x5                ; =5
     268:      	b	0x310 <ltmp0+0x310>
     26c:      	adrp	x2, 0x0 <ltmp0>
     270:      	add	x2, x2, #0x0
     274:      	mov	x0, x21
     278:      	mov	w1, #0x6                ; =6
     27c:      	mov	w3, #0x13               ; =19
     280:      	bl	0x280 <ltmp0+0x280>
     284:      	b	0x320 <ltmp0+0x320>
     288:      	adrp	x2, 0x0 <ltmp0>
     28c:      	add	x2, x2, #0x0
     290:      	mov	x0, x21
     294:      	mov	w1, #0xe                ; =14
     298:      	mov	w3, #0x15               ; =21
     29c:      	bl	0x29c <ltmp0+0x29c>
     2a0:      	mov	x0, x21
     2a4:      	mov	w1, wzr
     2a8:      	mov	w2, #0x1                ; =1
     2ac:      	b	0x310 <ltmp0+0x310>
     2b0:      	adrp	x2, 0x0 <ltmp0>
     2b4:      	add	x2, x2, #0x0
     2b8:      	mov	x0, x21
     2bc:      	mov	w1, #0x6                ; =6
     2c0:      	mov	w3, #0x13               ; =19
     2c4:      	bl	0x2c4 <ltmp0+0x2c4>
     2c8:      	b	0x2f4 <ltmp0+0x2f4>
     2cc:      	adrp	x2, 0x0 <ltmp0>
     2d0:      	add	x2, x2, #0x0
     2d4:      	mov	x0, x21
     2d8:      	mov	w1, wzr
     2dc:      	mov	w3, #0x10               ; =16
     2e0:      	bl	0x2e0 <ltmp0+0x2e0>
     2e4:      	mov	x0, x21
     2e8:      	mov	w1, #0x1                ; =1
     2ec:      	mov	w2, #0x2                ; =2
     2f0:      	bl	0x2f0 <ltmp0+0x2f0>
     2f4:      	mov	x0, x21
     2f8:      	mov	w1, wzr
     2fc:      	mov	w2, #0x2                ; =2
     300:      	b	0x310 <ltmp0+0x310>
     304:      	mov	x0, x21
     308:      	mov	w1, wzr
     30c:      	mov	w2, #0x3                ; =3
     310:      	bl	0x310 <ltmp0+0x310>
     314:      	mov	x0, x21
     318:      	mov	x1, x22
     31c:      	bl	0x31c <ltmp0+0x31c>
     320:      	ldr	x2, [x20, #0x10]
     324:      	mov	x0, x21
     328:      	mov	x1, x19
     32c:      	bl	0x32c <ltmp0+0x32c>
     330:      	mov	w1, #0x1                ; =1
     334:      	mov	x0, x21
     338:      	bl	0x338 <ltmp0+0x338>
     33c:      	mov	w22, w0
     340:      	cmp	w0, #0x2
     344:      	b.ne	0x1ec <ltmp0+0x1ec>
     348:      	b	0x208 <ltmp0+0x208>
     34c:      	mov	x0, x21
     350:      	bl	0x350 <ltmp0+0x350>
     354:      	b	0x314 <ltmp0+0x314>
