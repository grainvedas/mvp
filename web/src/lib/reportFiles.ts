// Migration 63 (Part D3): making a report's files. For each copy the reader may make (the internal one only for its
// readers) and each language, the PDF and the Excel file are written from the data the server kept, stored, and their
// SHA-256 kept by the server. A file already kept is not made again, so an interrupted run is finished by running it again.
import type { Copy } from './exports';
import { translate } from './i18n';
import { reportContent, storeReportFile, fileKey, type Format, type Lang } from './reports';
import { reportDocument } from './reportModel';

export interface Step { copy: Copy; lang: Lang; format: Format; done: boolean }

export async function makeReportFiles(report: string, internal: boolean, have: Record<string, unknown> = {},
  onStep: (s: Step) => void = () => {}, origin = window.location.origin) {
  const [{ reportPdf }, { reportXlsx }] = await Promise.all([import('./reportPdf'), import('./reportXlsx')]);
  for (const copy of (internal ? ['shareable', 'internal'] : ['shareable']) as Copy[]) {
    const missing = (['en', 'hi'] as Lang[]).flatMap((lang) => (['pdf', 'xlsx'] as Format[]).map((format) => ({ lang, format })))
      .filter((x) => !(fileKey(copy, x.lang, x.format) in have));
    if (missing.length === 0) continue;
    const content = await reportContent(report, copy);
    for (const { lang, format } of missing) {
      onStep({ copy, lang, format, done: false });
      const rd = reportDocument(content.report, content.data, (k, v, f) => translate(lang, k, v, f), origin);
      const bytes = format === 'pdf' ? await reportPdf(rd, content.report.issued_at) : await reportXlsx(rd);
      await storeReportFile(report, copy, lang, format, bytes);
      onStep({ copy, lang, format, done: true });
    }
  }
}
