// Reads of the set-up lists (migration 51). A server from before migration 51 has no `places` table: `has` is false and
// every screen keeps its older form (a district typed, no GPS).
import { q, rpc, sha256Hex } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { useAsync } from '../../lib/useAsync';
import type { Place } from '../../lib/setup';

/** The districts of a state, and the blocks and villages of one district (a district can hold thousands of villages:
 *  only the chosen one is read). */
export function usePlaces(stateId: string, district: string) {
  const ds = useAsync(async () => {
    if (!stateId) return { has: true, rows: [] as Place[] };
    try {
      return { has: true, rows: await q(supabase.from('places').select('id,state_id,district,block,village').eq('state_id', stateId).is('block', null).order('district').limit(1000)) as unknown as Place[] };
    } catch { return { has: false, rows: [] as Place[] }; }
  }, [stateId]);
  const listed = (ds.data?.rows ?? []).find((p) => p.district.toLowerCase().replace(/[^a-z]/g, '') === district.toLowerCase().replace(/[^a-z]/g, ''))?.district ?? '';
  const inner = useAsync(async () => (stateId && listed
    ? await q(supabase.from('places').select('id,state_id,district,block,village').eq('state_id', stateId).eq('district', listed).not('block', 'is', null).order('block').limit(5000)) as unknown as Place[]
    : [] as Place[]), [stateId, listed]);
  return { has: ds.data?.has ?? true, loading: ds.loading, places: [...(ds.data?.rows ?? []), ...(inner.data ?? [])], reload: () => { void ds.reload(); void inner.reload(); } };
}

/** Whether the server has the set-up lists (migration 51); null while it is asked. */
export function useSetupServer() {
  const a = useAsync(() => q(supabase.from('places').select('id').limit(1)).then(() => true).catch(() => false), []);
  return a.data ?? null;
}

export const MAX_REFERENCE_BYTES = 15 * 1024 * 1024;
/** A crop's reference file (a source document of a market profile, or the crop's photo) goes to the private bucket
 *  `reference` at crop/<crop>/<first 16 of its SHA-256>.<ext> and is registered with its fingerprint (in the Audit log). */
export async function uploadReference(cropId: string, kind: 'profile_source' | 'crop_photo', file: File): Promise<{ id: string; storage_path: string; sha256: string; file_name: string | null }> {
  if (file.size > MAX_REFERENCE_BYTES) throw new Error(`file is larger than ${MAX_REFERENCE_BYTES / 1024 / 1024} MB`);
  const hash = await sha256Hex(file);
  const ext = (file.name.split('.').pop() ?? 'pdf').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 5) || 'pdf';
  const path = `crop/${cropId}/${hash.slice(0, 16)}.${ext}`;
  const up = await supabase.storage.from('reference').upload(path, file, { contentType: file.type || 'application/octet-stream', upsert: false });
  if (up.error && !/already exists|duplicate/i.test(up.error.message)) throw new Error(up.error.message);
  return rpc('register_reference_file', { p_crop: cropId, p_kind: kind, p_path: path, p_sha256: hash, p_name: file.name });
}

/** A link to look at a reference file for ten minutes (the bucket is private). */
export async function referenceUrl(path: string): Promise<string | null> {
  const r = await supabase.storage.from('reference').createSignedUrl(path, 600);
  return r.data?.signedUrl ?? null;
}
