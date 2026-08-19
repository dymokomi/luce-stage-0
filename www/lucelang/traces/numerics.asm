
/Users/sedov/Dev/luciaos/www/lucelang/out/traces/numerics.o:	file format mach-o arm64

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
      4c:      	b	0x218 <ltmp0+0x218>
      50:      	mov	w23, #0x100             ; =256
      54:      	adrp	x0, 0x0 <ltmp0>
      58:      	add	x0, x0, #0x0
      5c:      	mov	w1, #0x2                ; =2
      60:      	mov	w22, #0x2               ; =2
      64:      	bl	0x64 <ltmp0+0x64>
      68:      	cbz	x0, 0x218 <ltmp0+0x218>
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
      e0:      	b.le	0x274 <ltmp0+0x274>
      e4:      	sub	x22, sp, #0x20
      e8:      	mov	sp, x22
      ec:      	ldp	x2, x3, [x20, #0x20]
      f0:      	mov	x0, x21
      f4:      	mov	x1, x19
      f8:      	mov	x4, x22
      fc:      	bl	0xfc <ltmp0+0xfc>
     100:      	cbnz	w0, 0x350 <ltmp0+0x350>
     104:      	ldr	x8, [x22, #0x8]
     108:      	mov	w9, #0x2                ; =2
     10c:      	stur	xzr, [x29, #-0x58]
     110:      	sturb	w9, [x29, #-0x68]
     114:      	cmn	w8, #0x1
     118:      	b.eq	0x290 <ltmp0+0x290>
     11c:      	mov	w9, #0x70               ; =112
     120:      	ldr	x10, [x21, #0x60]
     124:      	umaddl	x9, w8, w9, x10
     128:      	lsr	x8, x8, #32
     12c:      	ldr	w10, [x9, #0x60]
     130:      	cmp	w10, w8
     134:      	b.ne	0x234 <ltmp0+0x234>
     138:      	tbnz	w8, #0x0, 0x234 <ltmp0+0x234>
     13c:      	ldr	x8, [x9, #0x10]
     140:      	adds	x8, x8, #0x1
     144:      	b.vs	0x2b8 <ltmp0+0x2b8>
     148:      	cmp	x23, #0x1
     14c:      	b.eq	0x2e0 <ltmp0+0x2e0>
     150:      	mul	x9, x8, x8
     154:      	smulh	x8, x8, x8
     158:      	cmp	x8, x9, asr #63
     15c:      	b.ne	0x2fc <ltmp0+0x2fc>
     160:      	sub	x1, x29, #0x68
     164:      	sub	x2, x29, #0x80
     168:      	mov	x0, x21
     16c:      	stur	x9, [x29, #-0x60]
     170:      	bl	0x170 <ltmp0+0x170>
     174:      	cbnz	w0, 0x334 <ltmp0+0x334>
     178:      	ldp	x9, x10, [x29, #-0x78]
     17c:      	ldur	q0, [x29, #-0x80]
     180:      	ldr	x8, [x20, #0x8]
     184:      	ldurb	w11, [x29, #-0x7f]
     188:      	stur	q0, [x29, #-0x50]
     18c:      	stur	x10, [x29, #-0x40]
     190:      	cbz	x8, 0x24c <ltmp0+0x24c>
     194:      	sub	x12, x29, #0x80
     198:      	cmp	w11, #0xff
     19c:      	ldr	x0, [x20]
     1a0:      	orr	x12, x12, #0x2
     1a4:      	csel	x2, x10, x11, eq
     1a8:      	csel	x1, x9, x12, eq
     1ac:      	blr	x8
     1b0:      	cmn	w0, #0x1
     1b4:      	b.eq	0x37c <ltmp0+0x37c>
     1b8:      	cmp	w0, #0x2
     1bc:      	b.hs	0x24c <ltmp0+0x24c>
     1c0:      	sub	x1, x29, #0x50
     1c4:      	sub	x2, x29, #0x98
     1c8:      	mov	x0, x21
     1cc:      	bl	0x1cc <ltmp0+0x1cc>
     1d0:      	mov	x0, x21
     1d4:      	mov	x1, x22
     1d8:      	bl	0x1d8 <ltmp0+0x1d8>
     1dc:      	mov	w1, wzr
     1e0:      	mov	x0, x21
     1e4:      	bl	0x1e4 <ltmp0+0x1e4>
     1e8:      	mov	w22, w0
     1ec:      	cmp	w0, #0x2
     1f0:      	b.eq	0x210 <ltmp0+0x210>
     1f4:      	ldr	x20, [x20, #0x18]
     1f8:      	cbz	x20, 0x210 <ltmp0+0x210>
     1fc:      	mov	x0, x21
     200:      	bl	0x200 <ltmp0+0x200>
     204:      	mov	x1, x0
     208:      	mov	x0, x19
     20c:      	blr	x20
     210:      	mov	x0, x21
     214:      	bl	0x214 <ltmp0+0x214>
     218:      	mov	w0, w22
     21c:      	sub	sp, x29, #0x30
     220:      	ldp	x29, x30, [sp, #0x30]
     224:      	ldp	x20, x19, [sp, #0x20]
     228:      	ldp	x22, x21, [sp, #0x10]
     22c:      	ldp	x24, x23, [sp], #0x40
     230:      	ret
     234:      	adrp	x2, 0x0 <ltmp0>
     238:      	add	x2, x2, #0x0
     23c:      	mov	x0, x21
     240:      	mov	w1, #0xd                ; =13
     244:      	mov	w3, #0x16               ; =22
     248:      	b	0x2a4 <ltmp0+0x2a4>
     24c:      	adrp	x2, 0x0 <ltmp0>
     250:      	add	x2, x2, #0x0
     254:      	mov	x0, x21
     258:      	mov	w1, #0x9                ; =9
     25c:      	mov	w3, #0x18               ; =24
     260:      	bl	0x260 <ltmp0+0x260>
     264:      	mov	x0, x21
     268:      	mov	w1, #0x1                ; =1
     26c:      	mov	w2, #0x7                ; =7
     270:      	b	0x340 <ltmp0+0x340>
     274:      	adrp	x2, 0x0 <ltmp0>
     278:      	add	x2, x2, #0x0
     27c:      	mov	x0, x21
     280:      	mov	w1, #0x6                ; =6
     284:      	mov	w3, #0x13               ; =19
     288:      	bl	0x288 <ltmp0+0x288>
     28c:      	b	0x350 <ltmp0+0x350>
     290:      	adrp	x2, 0x0 <ltmp0>
     294:      	add	x2, x2, #0x0
     298:      	mov	x0, x21
     29c:      	mov	w1, #0xe                ; =14
     2a0:      	mov	w3, #0x15               ; =21
     2a4:      	bl	0x2a4 <ltmp0+0x2a4>
     2a8:      	mov	x0, x21
     2ac:      	mov	w1, #0x1                ; =1
     2b0:      	mov	w2, #0x1                ; =1
     2b4:      	b	0x340 <ltmp0+0x340>
     2b8:      	adrp	x2, 0x0 <ltmp0>
     2bc:      	add	x2, x2, #0x0
     2c0:      	mov	x0, x21
     2c4:      	mov	w1, wzr
     2c8:      	mov	w3, #0x10               ; =16
     2cc:      	bl	0x2cc <ltmp0+0x2cc>
     2d0:      	mov	x0, x21
     2d4:      	mov	w1, #0x1                ; =1
     2d8:      	mov	w2, #0x3                ; =3
     2dc:      	b	0x340 <ltmp0+0x340>
     2e0:      	adrp	x2, 0x0 <ltmp0>
     2e4:      	add	x2, x2, #0x0
     2e8:      	mov	x0, x21
     2ec:      	mov	w1, #0x6                ; =6
     2f0:      	mov	w3, #0x13               ; =19
     2f4:      	bl	0x2f4 <ltmp0+0x2f4>
     2f8:      	b	0x324 <ltmp0+0x324>
     2fc:      	adrp	x2, 0x0 <ltmp0>
     300:      	add	x2, x2, #0x0
     304:      	mov	x0, x21
     308:      	mov	w1, wzr
     30c:      	mov	w3, #0x10               ; =16
     310:      	bl	0x310 <ltmp0+0x310>
     314:      	mov	x0, x21
     318:      	mov	w1, wzr
     31c:      	mov	w2, #0x2                ; =2
     320:      	bl	0x320 <ltmp0+0x320>
     324:      	mov	x0, x21
     328:      	mov	w1, #0x1                ; =1
     32c:      	mov	w2, #0x4                ; =4
     330:      	b	0x340 <ltmp0+0x340>
     334:      	mov	x0, x21
     338:      	mov	w1, #0x1                ; =1
     33c:      	mov	w2, #0x5                ; =5
     340:      	bl	0x340 <ltmp0+0x340>
     344:      	mov	x0, x21
     348:      	mov	x1, x22
     34c:      	bl	0x34c <ltmp0+0x34c>
     350:      	ldr	x2, [x20, #0x10]
     354:      	mov	x0, x21
     358:      	mov	x1, x19
     35c:      	bl	0x35c <ltmp0+0x35c>
     360:      	mov	w1, #0x1                ; =1
     364:      	mov	x0, x21
     368:      	bl	0x368 <ltmp0+0x368>
     36c:      	mov	w22, w0
     370:      	cmp	w0, #0x2
     374:      	b.ne	0x1f4 <ltmp0+0x1f4>
     378:      	b	0x210 <ltmp0+0x210>
     37c:      	mov	x0, x21
     380:      	bl	0x380 <ltmp0+0x380>
     384:      	b	0x344 <ltmp0+0x344>
