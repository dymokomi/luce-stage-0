/* The C side of the native engine's MIR binding (vendor/mir).
 *
 * Three jobs Zig cannot do directly against mir.h:
 *   - MIR_init is a static inline, so it needs a real symbol;
 *   - MIR's default error handler prints and exits the process, so
 *     errors are converted into a setjmp/longjmp recovery that the
 *     Zig side sees as a plain failure code;
 *   - walking the module DLIST uses header macros.
 *
 * The longjmp only ever crosses MIR's own C frames and the thin Zig
 * callback passed to luce_mir_protected, which holds no resources.
 * The jump buffer is only armed while luce_mir_protected is on the
 * stack; an MIR error reported outside that window (teardown, a
 * future misuse) prints and aborts instead of jumping into a dead
 * frame.  After a reported error the context's state is unknown, so
 * the caller abandons it — the normal MIR_finish teardown is
 * skipped, leaking the context once; an error here is a compiler bug
 * surfaced to the caller, not a runtime condition.
 */
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mir.h"
#include "mir-gen.h"

static _Thread_local jmp_buf luce_mir_recover;
static _Thread_local int luce_mir_armed = 0;
static _Thread_local char luce_mir_message[512];

static void MIR_NO_RETURN error_handler (MIR_error_type_t type, const char *format, ...) {
  va_list args;
  (void) type;
  va_start (args, format);
  vsnprintf (luce_mir_message, sizeof (luce_mir_message), format, args);
  va_end (args);
  if (!luce_mir_armed) {
    /* No live jump target: longjmp here would enter a dead frame.
     * This is a should-never-happen MIR error outside the protected
     * compile window — fail as loudly as MIR's own default would. */
    fprintf (stderr, "loom: MIR error outside compile: %s\n", luce_mir_message);
    abort ();
  }
  luce_mir_armed = 0;
  longjmp (luce_mir_recover, 1);
}

MIR_context_t luce_mir_init (void) { return MIR_init (); }

const char *luce_mir_error_text (void) { return luce_mir_message; }

/* Run `body` with MIR errors captured: returns 0 on success, 1 when
 * MIR reported an error (text via luce_mir_error_text). */
int luce_mir_protected (MIR_context_t ctx, void (*body) (void *payload), void *payload) {
  MIR_set_error_func (ctx, error_handler);
  if (setjmp (luce_mir_recover) != 0) return 1;
  luce_mir_armed = 1;
  body (payload);
  luce_mir_armed = 0;
  return 0;
}

void luce_mir_load_all (MIR_context_t ctx) {
  for (MIR_module_t module = DLIST_HEAD (MIR_module_t, *MIR_get_module_list (ctx));
       module != NULL; module = DLIST_NEXT (MIR_module_t, module))
    MIR_load_module (ctx, module);
}

/* The span of a generated function's machine code (the LUCE PATCH in
 * vendor/mir records the length beside the address).  NULL with
 * length 0 before generation. */
const void *luce_func_code (MIR_item_t item, size_t *length) {
  *length = item->u.func->machine_code_len;
  return item->u.func->machine_code;
}

/* mir.h declares MIR_get_global_item but this snapshot never defines
 * it; finding a function by name is a plain walk of the module items. */
MIR_item_t luce_mir_find_func (MIR_context_t ctx, const char *name) {
  for (MIR_module_t module = DLIST_HEAD (MIR_module_t, *MIR_get_module_list (ctx));
       module != NULL; module = DLIST_NEXT (MIR_module_t, module))
    for (MIR_item_t item = DLIST_HEAD (MIR_item_t, module->items); item != NULL;
         item = DLIST_NEXT (MIR_item_t, item))
      if (item->item_type == MIR_func_item && strcmp (MIR_item_name (ctx, item), name) == 0)
        return item;
  return NULL;
}
