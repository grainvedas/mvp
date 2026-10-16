// The prototype's pictograms (STAGE_REGISTRY, lines 503–520, and its menus). Decoration only: always drawn with
// aria-hidden, never the only carrier of a meaning.
import type { StageType } from '../lib/types';

export const STAGE_ICON: Record<StageType, string> = {
  procurement: '🌾', lot_inward: '📥', village_batch: '🏘️', warehouse: '🏬', milling: '⚙️', sorting: '🔀', grading: '📊', drying: '☀️', popping: '🔥',
  cleaning: '💧', blanching: '♨️', cold_storage: '❄️', packing: '📦', qc: '🔬', commercial: '📋', shipment: '🚢', qr_activation: '🔲',
};
export const stageIcon = (s: string) => STAGE_ICON[s as StageType] ?? '•';

/** Headings inside a stage form (form_schema[].section in the stage registry). */
export const SECTION_ICON: Record<string, string> = {
  farmer: '👨‍🌾', weighing: '⚖️', moisture: '💧', evidence: '📷', source: '📥', quality: '🔬', batch: '🏘️', input: '⬇️', output: '⬆️',
  grades: '📊', storage: '❄️', arrival: '🚚', stored: '🏬', retrieval: '📤', packing: '📦', sample: '🧪', readings: '🔬', lab: '🏷️', buyer: '🤝', quantity: '⚖️',
  transport: '🚚', documents: '📄',
  where: '📍', optional: '➕', payment: '💰',                 // migration 52: the farm-gate form
  mill: '🏭',                                                 // migration 53: Milling
  terms: '💱', papers: '🧾',                                  // migration 54: Commercial, Shipment
};
