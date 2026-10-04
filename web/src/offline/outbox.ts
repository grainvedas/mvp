// Offline outbox (PRD §9 "Offline field capture"): a save made without a connection is kept on the phone and sent
// when the connection returns, oldest first, so footprint codes follow the order the lots were captured.
//
// Each queued save carries a client_ref (UUID). The server has a unique index on it (migration 21), so if a sync
// succeeds but the answer is lost, the retry is refused as a duplicate and the app picks up the record already made.
// Nothing is resolved silently: a save the database refuses stays in the outbox as "needs attention" with the
// database's own words, until the operator fixes it (opens it in the form again) or discards it.
import { supabase } from '../lib/supabase';
import { rpc, within } from '../lib/api';
import { toAppError } from '../lib/errors';
import { reportError } from '../lib/errorLog';
import type { Footprint } from '../lib/types';
import { uploadEvidence, UPLOAD_WAIT_MS } from '../engine/evidence';
import { available, idbAll, idbDel, idbGet, idbPut } from './idb';

export type OutboxState = 'queued' | 'syncing' | 'failed' | 'synced';
export interface OutboxItem {
  id: string;                               // = footprints.client_ref
  seq: number;                              // capture order
  user_id: string;                          // app_users.id of the operator who captured it
  captured_at: string;
  scope_id: string; stage_type: string; stage_label: string; scope_label: string;
  summary: string;                          // "Ram Achal · 120 kg" — for the outbox list
  row: Record<string, unknown>;             // the footprints insert, without client_ref
  values: Record<string, unknown>;          // form values, to reopen the form if the database refuses it
  source: { id: string; footprint_code: string; qty_out: number } | null;
  split: boolean;                           // grading run marked "split into grade lots"
  files: { name: string; type: string; blob: Blob }[];
  state: OutboxState;
  attempts: number;
  error?: string;                           // the database's own words when it refused the save (state "failed")
  note?: 'network' | 'session' | 'photo';   // why a waiting save has not gone out yet; shown in the reader's language
  photo_error?: string;
  footprint_id?: string;
  footprint_code?: string;
  synced_at?: string;
}

type Listener = () => void;
const listeners = new Set<Listener>();
export function onOutboxChange(fn: Listener) { listeners.add(fn); return () => { listeners.delete(fn); }; }
const emit = () => listeners.forEach((f) => f());

let counter = 0;
export async function enqueue(item: Omit<OutboxItem, 'id' | 'seq' | 'captured_at' | 'state' | 'attempts'> & { id?: string }): Promise<OutboxItem> {
  if (!available()) throw new Error('This phone cannot store records offline (private browsing?).');
  const full: OutboxItem = { ...item, id: item.id ?? crypto.randomUUID(), seq: Date.now() * 1000 + (counter++ % 1000),
    captured_at: new Date().toISOString(), state: 'queued', attempts: 0 };
  await idbPut('outbox', full);
  emit();
  return full;
}

export async function listOutbox(userId?: string): Promise<OutboxItem[]> {
  if (!available()) return [];
  const all = await idbAll<OutboxItem>('outbox').catch(() => [] as OutboxItem[]);
  return all.filter((i) => !userId || i.user_id === userId).sort((a, b) => a.seq - b.seq);
}
export const getOutboxItem = (id: string) => idbGet<OutboxItem>('outbox', id);
export async function discard(id: string) { await idbDel('outbox', id); emit(); }
export async function clearSynced(userId: string) {
  for (const i of await listOutbox(userId)) if (i.state === 'synced') await idbDel('outbox', i.id);
  emit();
}

async function saveItem(i: OutboxItem) { await idbPut('outbox', i); emit(); }

/** A save that has had no answer for this long is stopped and treated as "no connection" (a dead link can hold a
 *  request for minutes). Safe because of the save id: if the server did store it, the retry finds it. */
export const SAVE_TIMEOUT_MS = 30_000;

/**
 * Store one record under a save id (footprints.client_ref, unique in the database: migration 21).
 * Every save goes through here, whether it is sent at once or was kept on the phone first, so a save whose answer was
 * lost on the way back is found again instead of being made a second time.
 */
export async function insertOnce(row: Record<string, unknown>, ref: string): Promise<Footprint> {
  const stop = new AbortController();
  const timer = setTimeout(() => stop.abort(), SAVE_TIMEOUT_MS);
  try {
    const { data, error } = await supabase.from('footprints').insert({ ...row, client_ref: ref }).select().abortSignal(stop.signal).single();
    if (!error) return data as Footprint;
    if (error.code === '23505' && /client_ref/.test(error.message)) {
      const again = await supabase.from('footprints').select('*').eq('client_ref', ref).abortSignal(stop.signal).single();
      if (!again.error) return again.data as Footprint;
      throw again.error;
    }
    throw error;
  } finally { clearTimeout(timer); }
}

/**
 * A save that waited on the phone carries the time it was captured (footprints.captured_at, migration 29); the server
 * accepts it within limits and dates the record by it. A server that does not have the column yet answers "unknown
 * column": the save is then sent as before, so an app deployed ahead of its database loses nothing.
 */
export async function insertWithCaptureTime(i: Pick<OutboxItem, 'row' | 'id' | 'captured_at'>): Promise<Footprint> {
  try { return await insertOnce({ ...i.row, captured_at: i.captured_at }, i.id); }
  catch (e) {
    const err = e as { code?: string; message?: string };
    if (err.code === 'PGRST204' && /captured_at/.test(err.message ?? '')) return insertOnce(i.row, i.id);
    throw e;
  }
}

/** "Milling: input (148) must equal …": the database's refusal already starts with the stage; do not print it twice. */
export function refusalText(stageLabel: string, message: string): string {
  const first = stageLabel.split(/[\s(]/)[0].toLowerCase();
  return first && message.toLowerCase().startsWith(`${first}:`) ? message : `${stageLabel}: ${message}`;
}

let running: Promise<{ synced: number; failed: number; left: number }> | null = null;

/** Send every queued save of this user, oldest first. Safe to call often; concurrent calls share one run. */
export function syncOutbox(userId: string) {
  if (!running) running = run(userId).finally(() => { running = null; });
  return running;
}

async function run(userId: string) {
  let synced = 0, failed = 0;
  const items = (await listOutbox(userId)).filter((i) => i.state === 'queued' || i.state === 'syncing');
  for (const i of items) {
    await saveItem({ ...i, state: 'syncing', attempts: i.attempts + 1 });
    let rec: Footprint;
    try {
      rec = await insertWithCaptureTime(i);
    } catch (e) {
      const err = toAppError(e);
      if (err.kind === 'network' || err.kind === 'session') {       // still offline, or must sign in again: stop, keep order
        await saveItem({ ...i, state: 'queued', attempts: i.attempts + 1, error: undefined, note: err.kind });
        break;
      }
      failed++;
      await saveItem({ ...i, state: 'failed', attempts: i.attempts + 1, error: err.message, note: undefined });
      reportError('sync_refused', refusalText(i.stage_label, err.message), `captured ${i.captured_at} · scope ${i.scope_label}`);   // the admin sees it too
      continue;
    }
    let photoError: string | undefined, photoLater = false;
    for (const f of i.files) {
      try { await within(UPLOAD_WAIT_MS, uploadEvidence(rec, new File([f.blob], f.name, { type: f.type }))); }
      catch (e) {
        const kind = toAppError(e).kind;
        if (kind === 'network' || kind === 'session') { photoLater = true; break; }
        photoError = (e as Error).message;                   // the server refused the file itself: retrying cannot help
      }
    }
    if (photoLater) {
      // The record is stored, its photo is not. The whole save keeps waiting with the photo; the next run finds the
      // record by its save id (nothing is made twice) and sends the photo then. Before, the photo was dropped here.
      await saveItem({ ...i, state: 'queued', attempts: i.attempts + 1, error: undefined, note: 'photo', footprint_id: rec.id, footprint_code: rec.footprint_code });
      break;
    }
    if (i.split && rec.split_into_grades) {
      // The save itself made the grade lots (migration 24). The call only creates them on a database without that
      // migration, so a dropped connection here is not a problem to report.
      try { await rpc('split_grades', { p_run: rec.id }); }
      catch (e) { if (toAppError(e).kind !== 'network') photoError = `grade lots not created: ${(e as Error).message}`; }
    }
    synced++;
    await saveItem({ ...i, state: 'synced', attempts: i.attempts + 1, error: undefined, note: undefined, photo_error: photoError,
      footprint_id: rec.id, footprint_code: rec.footprint_code, synced_at: new Date().toISOString(), files: [] });
  }
  const left = (await listOutbox(userId)).filter((i) => i.state === 'queued').length;
  return { synced, failed, left };
}
