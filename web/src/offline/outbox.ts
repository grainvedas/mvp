// Offline outbox (PRD §9 "Offline field capture"): a save made without a connection is kept on the phone and sent
// when the connection returns, oldest first, so footprint codes follow the order the lots were captured.
//
// Each queued save carries a client_ref (UUID). The server has a unique index on it (migration 21), so if a sync
// succeeds but the answer is lost, the retry is refused as a duplicate and the app picks up the record already made.
// Nothing is resolved silently: a save the database refuses stays in the outbox as "needs attention" with the
// database's own words, until the operator fixes it (opens it in the form again) or discards it.
import { supabase } from '../lib/supabase';
import { rpc } from '../lib/api';
import { toAppError } from '../lib/errors';
import type { Footprint } from '../lib/types';
import { uploadEvidence } from '../engine/evidence';
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
  error?: string;
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

/** Insert one queued save; a duplicate client_ref means an earlier attempt already made it. */
async function push(i: OutboxItem): Promise<Footprint> {
  const { data, error } = await supabase.from('footprints').insert({ ...i.row, client_ref: i.id }).select().single();
  if (!error) return data as Footprint;
  if (error.code === '23505' && /client_ref/.test(error.message)) {
    const again = await supabase.from('footprints').select('*').eq('client_ref', i.id).single();
    if (!again.error) return again.data as Footprint;
    throw again.error;
  }
  throw error;
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
      rec = await push(i);
    } catch (e) {
      const err = toAppError(e);
      if (err.kind === 'network' || err.kind === 'session') {       // still offline, or must sign in again: stop, keep order
        await saveItem({ ...i, state: 'queued', attempts: i.attempts + 1, error: err.message });
        break;
      }
      failed++;
      await saveItem({ ...i, state: 'failed', attempts: i.attempts + 1, error: err.message });
      continue;
    }
    let photoError: string | undefined;
    for (const f of i.files) {
      try { await uploadEvidence(rec, new File([f.blob], f.name, { type: f.type })); }
      catch (e) { photoError = (e as Error).message; }
    }
    if (i.split && rec.split_into_grades) {
      try { await rpc('split_grades', { p_run: rec.id }); } catch (e) { photoError = `grade lots not created: ${(e as Error).message}`; }
    }
    synced++;
    await saveItem({ ...i, state: 'synced', attempts: i.attempts + 1, error: undefined, photo_error: photoError,
      footprint_id: rec.id, footprint_code: rec.footprint_code, synced_at: new Date().toISOString(), files: [] });
  }
  const left = (await listOutbox(userId)).filter((i) => i.state === 'queued').length;
  return { synced, failed, left };
}
