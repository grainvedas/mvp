// Photo evidence (B6): upload to the private `evidence` bucket at <client>/<scope>/<footprint>/<file>, then register it
// with its SHA-256. Server-side re-checking of the hash is Phase 3 work (execution plan §5).
import { supabase } from '../lib/supabase';
import { rpc, sha256Hex } from '../lib/api';
import type { Footprint } from '../lib/types';

export async function uploadEvidence(rec: Footprint, file: File) {
  const hash = await sha256Hex(file);
  const ext = (file.name.split('.').pop() ?? 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '') || 'jpg';
  const path = `${rec.client_id}/${rec.scope_id}/${rec.id}/${hash.slice(0, 16)}.${ext}`;
  const up = await supabase.storage.from('evidence').upload(path, file, { contentType: file.type || 'image/jpeg', upsert: false });
  if (up.error) throw new Error(up.error.message);
  await rpc('register_attachment', { p_footprint: rec.id, p_kind: 'photo', p_path: path, p_sha256: hash });
  return path;
}
