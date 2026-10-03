// Evidence (B6, PRD §9): a photo or document goes to the private `evidence` bucket at
// <client>/<scope>/<footprint>/<file>, then is registered with its SHA-256, which the server writes into the ledger
// (migration 27). The file name is its own fingerprint, so the same file cannot be stored twice under one record and
// a stored file is never overwritten (upsert: false).
import { supabase } from '../lib/supabase';
import { rpc, sha256Hex } from '../lib/api';
import { toAppError } from '../lib/errors';
import type { Footprint } from '../lib/types';

export const MAX_EVIDENCE_BYTES = 15 * 1024 * 1024;
/** A photo upload that has not finished after this long is given up for now and tried again later (15 MB at a slow
 *  field uplink needs about three minutes; a link that is dead needs forever). */
export const UPLOAD_WAIT_MS = 240_000;

export async function uploadEvidence(rec: Pick<Footprint, 'id' | 'client_id' | 'scope_id'>, file: File) {
  if (file.size > MAX_EVIDENCE_BYTES) throw new Error(`file is larger than ${MAX_EVIDENCE_BYTES / 1024 / 1024} MB`);
  const hash = await sha256Hex(file);
  const ext = (file.name.split('.').pop() ?? 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '') || 'jpg';
  const path = `${rec.client_id}/${rec.scope_id}/${rec.id}/${hash.slice(0, 16)}.${ext}`;
  const up = await supabase.storage.from('evidence').upload(path, file, { contentType: file.type || 'image/jpeg', upsert: false });
  // "already exists": an earlier attempt stored the file but the registration did not get through; register it now
  if (up.error && !/already exists|duplicate/i.test(up.error.message)) throw new Error(up.error.message);
  const kind = (file.type || 'image/jpeg').startsWith('image/') ? 'photo' : 'document';
  try { await rpc('register_attachment', { p_footprint: rec.id, p_kind: kind, p_path: path, p_sha256: hash }); }
  catch (e) {
    // 23505 on the path: an earlier attempt did register it and only the answer was lost. The file is in the ledger.
    if (toAppError(e).code !== '23505') throw e;
  }
  return path;
}
