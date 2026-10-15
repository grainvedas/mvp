// The GI tag in words (migration 49, brief G7: a bare "280" on the screen). "280", "GI 280", "GI Tag 280", "GI Tag No. 280"
// all read "GI Tag No. 280"; any other text is shown as it was typed. Whether a lot may carry it is the server's
// (app.lot_gi_status: every source from the crop's GI districts).
type T = (k: string, v?: Record<string, string | number>, f?: string) => string;

/** Pure: the number of a GI tag, or null when the text names none. */
export function giNumber(tag: string | null | undefined): string | null {
  const m = /^\s*(?:GI\b\.?\s*(?:tag\s*)?(?:no\.?\s*)?)?(\d{1,5})\s*$/i.exec(tag ?? '');
  return m ? m[1] : null;
}

export function giLabel(tag: string | null | undefined, t: T): string {
  const n = giNumber(tag);
  return n ? t('gi.label', { n }, `GI Tag No. ${n}`) : (tag ?? '');
}
