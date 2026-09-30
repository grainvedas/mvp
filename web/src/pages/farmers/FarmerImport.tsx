// S11 Excel import: template → upload → dry run with row errors → import all rows or none (B4 app.import_farmers)
import { useState } from 'react';
import { Link } from 'react-router-dom';
import readXlsxFile from 'read-excel-file';
import writeXlsxFile from 'write-excel-file';
import { rpc } from '../../lib/api';
import { useAction } from '../../lib/useAsync';
import { useI18n } from '../../lib/i18n';
import { ErrorBox, Field } from '../../shell/ui';
import { useClientChoice } from './Farmers';

export const TEMPLATE_COLUMNS = ['name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres', 'notes'];
interface ImportResult { ok: boolean; dry_run: boolean; rows: number; inserted: number; errors: { row: number; field: string; message: string }[] }

/** First sheet → [{row, <header>: value}], headers normalised to snake_case. Exported for tests. */
export function rowsFromSheet(sheet: unknown[][]): Record<string, string | number>[] {
  if (!sheet.length) return [];
  const headers = sheet[0].map((h) => String(h ?? '').trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_|_$/g, ''));
  return sheet.slice(1)
    .map((r, i) => ({ r, i }))
    .filter(({ r }) => r.some((c) => c !== null && String(c).trim() !== ''))
    .map(({ r, i }) => {
      const o: Record<string, string | number> = { row: i + 2 };
      headers.forEach((h, j) => { if (h && r[j] !== null && r[j] !== undefined) o[h] = typeof r[j] === 'number' ? (r[j] as number) : String(r[j]).trim(); });
      return o;
    });
}

export function FarmerImport() {
  const { t } = useI18n();
  const { clientId, picker } = useClientChoice();
  const [rows, setRows] = useState<Record<string, string | number>[] | null>(null);
  const [fileName, setFileName] = useState('');
  const [result, setResult] = useState<ImportResult | null>(null);
  const act = useAction();

  const template = () => writeXlsxFile([
    TEMPLATE_COLUMNS.map((c) => ({ value: c, fontWeight: 'bold' as const })),
    ['Ram Kumar', 'Shri Shyam Lal', 'Bansi', 'Siddharthnagar', '9876543210', 2.5, ''].map((v) => ({ value: v })),
  ], { fileName: 'grainveda_farmers_template.xlsx' });

  const choose = (file: File | undefined) => act.run(async () => {
    setResult(null); setRows(null);
    if (!file) return;
    setFileName(file.name);
    const sheet = await readXlsxFile(file);
    const r = rowsFromSheet(sheet as unknown[][]);
    setRows(r);
    setResult(await rpc<ImportResult>('import_farmers', { p_client: clientId, p_rows: r, p_dry_run: true }));
  });
  const commit = () => act.run(async () => {
    setResult(await rpc<ImportResult>('import_farmers', { p_client: clientId, p_rows: rows, p_dry_run: false }));
    setRows(null);
  });

  return (
    <div className="card" style={{ maxWidth: 760 }}>
      <p className="small"><Link to="/farmers">{t('farmers.title')}</Link></p>
      <h1>{t('farmers.import')}</h1>
      {picker}
      <ol className="stack">
        <li><button type="button" className="secondary" onClick={() => void template()}>{t('import.template')}</button>
          <div className="muted small">Columns: {TEMPLATE_COLUMNS.join(', ')}. Extra columns are kept with the farmer.</div></li>
        <li><Field label={t('import.choose')} htmlFor="import-file">
          <input id="import-file" type="file" accept=".xlsx" onChange={(e) => void choose(e.target.files?.[0])} /></Field>
          {fileName && <div className="muted small">{fileName}</div>}</li>
      </ol>
      <ErrorBox error={act.error} />
      {result && result.dry_run && !result.ok && (
        <div data-testid="import-errors">
          <div className="alert error">{t('import.errors', { n: result.errors.length })}</div>
          <div className="table-wrap"><table>
            <thead><tr><th>{t('import.row')}</th><th>{t('import.column')}</th><th>{t('import.problem')}</th></tr></thead>
            <tbody>{result.errors.map((e, i) => <tr key={i}><td className="num">{e.row}</td><td>{e.field}</td><td>{e.message}</td></tr>)}</tbody>
          </table></div>
        </div>
      )}
      {result && result.dry_run && result.ok && rows && (
        <div className="stack">
          <div className="alert ok">{t('import.clean', { n: result.rows })}</div>
          <button onClick={commit} disabled={act.busy}>{t('import.go', { n: result.rows })}</button>
        </div>
      )}
      {result && !result.dry_run && result.ok && <div className="alert ok" data-testid="import-done">{t('import.done', { n: result.inserted })}</div>}
    </div>
  );
}
