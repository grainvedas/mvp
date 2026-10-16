// Migration 57 (Veda's G22, Part H 1: "Needs my action (2)" and "5 lot(s) waiting for you" read as a contradiction).
/** Pure: what waits at a stage, in two counts: the lots still to check in (they are also in "Needs my action") and the
 *  lots checked in, ready to record. Nothing when nothing waits. */
export function waitingSplit(t: (k: string, v?: Record<string, string | number>) => string, toCheck: number, ready: number): string {
  return [toCheck > 0 ? t('inc.n_to_check_in', { n: toCheck }) : '', ready > 0 ? t('inc.n_ready', { n: ready }) : ''].filter(Boolean).join(' · ');
}
