import { useCallback, useEffect, useState } from 'react';
import { useAuth } from '../auth/AuthProvider';
import { listOutbox, onOutboxChange, syncOutbox, type OutboxItem } from './outbox';

export function useOnline() {
  const [online, setOnline] = useState(() => (typeof navigator === 'undefined' ? true : navigator.onLine));
  useEffect(() => {
    const up = () => setOnline(true), down = () => setOnline(false);
    window.addEventListener('online', up); window.addEventListener('offline', down);
    return () => { window.removeEventListener('online', up); window.removeEventListener('offline', down); };
  }, []);
  return online;
}

/** How often waiting saves are tried again while the browser says there is a network (a weak link, or a sign-in token
 *  that could not be renewed on the first try, both pass by themselves). */
export const RETRY_MS = 20_000;

/** The signed-in user's outbox, live. Syncs by itself when the connection returns and every RETRY_MS while items wait. */
export function useOutbox({ autoSync = false } = {}) {
  const { ctx } = useAuth();
  const userId = ctx?.user?.id ?? '';
  const online = useOnline();
  const [items, setItems] = useState<OutboxItem[]>([]);
  const refresh = useCallback(() => { if (userId) void listOutbox(userId).then(setItems); }, [userId]);
  useEffect(() => { refresh(); return onOutboxChange(refresh); }, [refresh]);
  const sync = useCallback(() => (userId ? syncOutbox(userId) : Promise.resolve({ synced: 0, failed: 0, left: 0 })), [userId]);
  const waiting = items.filter((i) => i.state === 'queued' || i.state === 'syncing').length;
  useEffect(() => {
    if (!autoSync || !online || !userId || waiting === 0) return;
    void sync();
    const t = window.setInterval(() => void sync(), RETRY_MS);
    return () => window.clearInterval(t);
  }, [autoSync, online, userId, waiting, sync]);
  return {
    online, items, sync, refresh, waiting,
    failed: items.filter((i) => i.state === 'failed').length,
    synced: items.filter((i) => i.state === 'synced'),
  };
}
