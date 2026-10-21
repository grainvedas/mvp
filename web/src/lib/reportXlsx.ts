// Migration 63 (Part D3): the season report as an Excel file, one sheet per section, written from the same model as the
// PDF (lib/reportModel.ts). Each sheet starts with the title, the report's line and, for an interim report, "Interim:
// season not closed"; each ends with the statement's footer and the copy's words.
import writeXlsxFile from 'write-excel-file';
import type { Block, ReportDoc } from './reportModel';

type XCell = { value: string; fontWeight?: 'bold'; color?: string } | null;
const RED = '#B42318', GREEN = '#067647', GREY = '#5C615E';
const c = (v: string, bold = false, color?: string): XCell => (v === '' ? null : { value: v, ...(bold ? { fontWeight: 'bold' as const } : {}), ...(color ? { color } : {}) });

/** Pure: a sheet's name Excel accepts: at most 31 characters, none of []:*?/\, unique in the file. */
export function sheetName(title: string, taken: Set<string>) {
  let n = title.replace(/[[\]:*?/\\]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 31) || 'Sheet';
  let k = 2;
  while (taken.has(n)) { const suf = ` ${k++}`; n = `${n.slice(0, 31 - suf.length)}${suf}`; }
  taken.add(n);
  return n;
}

function rowsOf(b: Block): XCell[][] {
  if (b.kind === 'kv') return b.rows.map(([k, v]) => [c(k, true), c(v)]);
  if (b.kind === 'sub') return [[], [c(b.text, true)]];
  if (b.kind === 'text') return [[c(b.text, false, b.tone === 'danger' ? RED : b.tone === 'ok' ? GREEN : b.tone === 'muted' ? GREY : undefined)]];
  return [b.head.map((h) => c(h, true)), ...b.rows.map((r, i) => r.map((v) => c(v, false, b.tones?.[i] === 'danger' ? RED : undefined)))];
}

/** Pure: the sheets and their names. */
export function reportSheets(rd: ReportDoc) {
  const taken = new Set<string>();
  const top: XCell[][] = [[c(rd.title, true)], ...rd.lines.map((l) => [c(l)]), ...(rd.banner ? [[c(rd.banner, true, RED)]] : []), []];
  const foot: XCell[][] = [[], [c(rd.footer)], [c(rd.copyNote, true)]];
  const sheets = rd.sections.map((s) => [...top, [c(s.title, true)], ...s.blocks.flatMap(rowsOf), ...foot]);
  return { sheets, names: rd.sections.map((s) => sheetName(s.title, taken)) };
}

/** The report as an Excel file (bytes). */
export async function reportXlsx(rd: ReportDoc): Promise<Uint8Array> {
  const { sheets, names } = reportSheets(rd);
  const blob = await writeXlsxFile(sheets as never, { sheets: names }) as unknown as Blob;
  return new Uint8Array(await blob.arrayBuffer());
}
