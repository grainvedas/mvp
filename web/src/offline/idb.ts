// Minimal promise wrapper over IndexedDB (no dependency). Two stores:
//   outbox  saves made without a connection, synced in capture order (PRD §9 offline field capture)
//   cache   last good answers the forms need to work offline (stage form, farmer list, verified incoming lots)
const DB_NAME = 'grainveda-offline';
const VERSION = 1;
export type StoreName = 'outbox' | 'cache';

let dbp: Promise<IDBDatabase> | null = null;

export function available(): boolean {
  try { return typeof indexedDB !== 'undefined' && indexedDB !== null; } catch { return false; }
}

function open(): Promise<IDBDatabase> {
  if (!dbp) {
    dbp = new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, VERSION);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains('outbox')) db.createObjectStore('outbox', { keyPath: 'id' });
        if (!db.objectStoreNames.contains('cache')) db.createObjectStore('cache');
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => { dbp = null; reject(req.error); };
    });
  }
  return dbp;
}

function tx<T>(store: StoreName, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return open().then((db) => new Promise<T>((resolve, reject) => {
    const t = db.transaction(store, mode);
    const r = fn(t.objectStore(store));
    t.oncomplete = () => resolve(r.result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
  }));
}

export const idbGet = <T>(store: StoreName, key: IDBValidKey) => tx<T | undefined>(store, 'readonly', (s) => s.get(key));
export const idbPut = (store: StoreName, value: unknown, key?: IDBValidKey) =>
  tx<IDBValidKey>(store, 'readwrite', (s) => (key === undefined ? s.put(value) : s.put(value, key)));
export const idbDel = (store: StoreName, key: IDBValidKey) => tx<undefined>(store, 'readwrite', (s) => s.delete(key));
export const idbAll = <T>(store: StoreName) => tx<T[]>(store, 'readonly', (s) => s.getAll());
export const idbClear = (store: StoreName) => tx<undefined>(store, 'readwrite', (s) => s.clear());
