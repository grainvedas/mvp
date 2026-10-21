// Migration 63 (Part D3): the season report as a document, in the reader's language, from the data the server kept when
// the report was issued. One model, written twice: as a PDF (lib/reportPdf.ts, A4) and as an Excel file (one sheet per
// section, lib/reportXlsx.ts), so both say the same. Pure: no fetch, no clock (the dates are the report's).
// Wording (the brief): the title "Verified traceability statement: season report", the footer "This statement records what
// GrainVeda verified under its published protocol. It is not a quality, residue or Geographical Indication certificate.";
// never "certificate" otherwise; an interim report says "Interim: season not closed" on every page.
import type { ReportData, ReportHead } from './reports';
import { date, dateTime, humanise, kg, num } from './format';

type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;
export type Tone = 'ok' | 'danger' | 'muted' | undefined;
export type Block =
  | { kind: 'kv'; rows: [string, string][] }
  | { kind: 'table'; head: string[]; rows: string[][]; tones?: (Tone | undefined)[] }
  | { kind: 'text'; text: string; tone?: Tone }
  | { kind: 'sub'; text: string };
export interface Section { key: string; title: string; blocks: Block[] }
export interface ReportDoc { title: string; ref: string; lines: string[]; banner: string | null; copyNote: string; footer: string;
  verifyUrl: string; verifyLabel: string; sections: Section[]; fileBase: string }

const pct = (v: number | null | undefined) => (v === null || v === undefined ? '—' : `${num(v, 1)} %`);
const txt = (v: unknown) => (v === null || v === undefined || v === '' ? '—' : String(v));
const of = (a: number, b: number) => (b ? Math.round((a / b) * 1000) / 10 : null);

/** Pure: the verdict as the report says it; a release on the client's acceptance is said as such, never "PASSED". */
export function verdictWord(v: string | null | undefined, accepted: boolean, t: T) {
  if (accepted) return t('rep.q.accepted');
  return v ? t(`rep.v.${v}`, undefined, humanise(v)) : '—';
}

export function reportDocument(head: ReportHead, d: ReportData, t: T, origin: string): ReportDoc {
  const c = d.cover;
  const stage = (s: string) => t(`stage.${s}`, undefined, humanise(s));
  const kind = head.final ? t('rep.final_v', { n: head.version }) : t('rep.interim_n', { n: head.version });
  const verifyUrl = `${origin}/d/${head.ref}`;
  const sections: Section[] = [];

  // Cover
  sections.push({ key: 'cover', title: t('rep.s.cover'), blocks: [{ kind: 'kv', rows: [
    [t('rep.c.client'), txt(c.client)],
    [t('rep.c.crop'), c.crop],
    [t('rep.c.gi_tag'), c.gi_earned && c.gi_tag ? c.gi_tag : t('rep.c.gi_not_earned')],
    [t('rep.c.season'), c.season],
    [t('rep.c.scope'), [c.scope_code, c.geography].filter(Boolean).join(' · ')],
    [t('rep.c.state'), txt(c.state)],
    [t('rep.c.area'), c.districts.length ? c.districts.join(', ') : '—'],
    [t('rep.c.delivery_model'), c.delivery_model ? t(`rep.dm.${c.delivery_model}`, undefined, c.delivery_model) : t('rep.c.not_recorded')],
    [t('rep.c.period'), `${date(head.period_from ?? c.period_from)} – ${date(head.period_to ?? c.period_to)}`],
    [t('rep.c.version'), kind],
    [t('rep.c.ref'), head.ref],
    [t('rep.c.kind'), head.final ? t('rep.final') : t('rep.interim')],
    [t('rep.c.issued'), `${dateTime(head.issued_at)}${head.issued_by ? ` · ${head.issued_by}` : ''}`],
    [t('rep.c.issued_to'), head.issued_to],
    [t('rep.c.copy'), t(d.copy === 'internal' ? 'exp.copy_internal' : 'exp.copy_shareable')],
    ...(c.data_note === 'practice_old_data' ? [[t('exp.h.data_note'), t('scope.old_data')] as [string, string]] : []),
  ] }] });

  // Headline figures
  const h = d.headline;
  sections.push({ key: 'headline', title: t('rep.s.headline'), blocks: [
    { kind: 'kv', rows: [
      [t('rep.h.flow'), `${kg(h.procured_kg)} → ${kg(h.packed_kg)} → ${kg(h.sold_kg)} → ${kg(h.shipped_kg)}`],
      [t('rep.h.farmers'), t('rep.h.farmers_v', { n: h.farmers, m: h.villages })],
      [t('rep.h.gi_share'), pct(h.gi_pct)],
      [t('rep.h.farm_verified'), pct(h.farm_verified_pct)],
      [t('rep.h.packs_released'), t('rep.h.packs_released_v', { n: h.packs_released, old: h.packs_released_old, held: h.packs_held })],
      [t('rep.h.sealed'), String(h.sealed_lots)],
      [t('rep.h.scans'), String(h.scans)],
      [t('rep.h.copy_flags'), String(h.copy_flags)],
      [t('rep.h.recalls'), String(h.recalls)],
    ] },
    { kind: 'sub', text: t('rep.h.qc_title') },
    { kind: 'table', head: [t('rep.q.market'), t('rep.q.lots'), t('rep.q.passed'), t('rep.q.failed'), t('rep.q.accepted_n'), t('rep.q.pending'), t('rep.q.pass_rate')],
      rows: h.qc.filter((q) => q.lots > 0).map((q) => [t(`exp.mkt.${q.market}`, undefined, q.market), String(q.lots), String(q.passed), String(q.failed),
        String(q.accepted), String(q.pending), pct(q.pass_pct)]) },
  ] });

  // Mass balance
  const b = d.balance;
  const m = b.milling;
  const balRows = b.stages.map((x) => [`${x.pos}. ${stage(x.stage)}`, kg(x.kg_in), kg(x.handed_on_kg), kg(Number(x.by_products_kg) + Number(x.other_kg)),
    kg(Number(x.floor_loss_kg) + Number(x.transit_loss_kg)), pct(of(Number(x.floor_loss_kg) + Number(x.transit_loss_kg), Number(x.kg_in))),
    kg(Number(x.closed_kg) + Number(x.written_off_kg ?? 0)), kg(x.left_kg), x.balanced ? t('exp.s.balanced') : kg(x.difference_kg)]);
  sections.push({ key: 'balance', title: t('rep.s.balance'), blocks: [
    { kind: 'table', head: [t('exp.s.stage'), t('rep.b.in'), t('rep.b.out'), t('rep.b.byp'), t('rep.b.loss'), t('rep.b.loss_pct'), t('rep.b.closed'),
      t('exp.s.left'), t('exp.s.difference')], rows: balRows, tones: b.stages.map((x) => (x.balanced ? undefined : 'danger')) },
    ...(m && m.records > 0 ? [{ kind: 'kv' as const, rows: [
      [t('rep.b.milling_in'), kg(m.in_kg)],
      [t('exp.c.head_rice_kg'), `${kg(m.head_rice_kg)} · ${pct(of(m.head_rice_kg, m.in_kg))}`],
      [t('exp.c.broken_kg'), `${kg(m.broken_kg)} · ${pct(of(m.broken_kg, m.in_kg))}`],
      [t('exp.c.husk_kg'), `${kg(m.husk_kg)} · ${pct(of(m.husk_kg, m.in_kg))}`],
      [t('exp.c.bran_kg'), `${kg(m.bran_kg)} · ${pct(of(m.bran_kg, m.in_kg))}`],
      [t('exp.c.floor_loss_kg'), `${kg(m.floor_loss_kg)} · ${pct(of(m.floor_loss_kg, m.in_kg))}`],
    ] as [string, string][] }] : []),
    ...(Number(b.written_off_kg) > 0 ? [{ kind: 'text' as const, text: t('rep.b.written_off', { kg: kg(b.written_off_kg) }) }] : []),
    { kind: 'text', text: b.check.ok ? t('rep.b.check_ok', { sold: kg(b.check.sold_kg), procured: kg(b.check.procured_kg) })
        : t('rep.b.check_bad', { sold: kg(b.check.sold_kg), procured: kg(b.check.procured_kg) }), tone: b.check.ok ? 'ok' : 'danger' },
    ...(b.differences > 0 ? [{ kind: 'text' as const, text: t('rep.b.differences', { n: b.differences }), tone: 'danger' as const }] : []),
    { kind: 'text', text: t('exp.s.balance_note'), tone: 'muted' },
  ] });

  // Origin
  const o = d.origin;
  sections.push({ key: 'origin', title: t('rep.s.origin'), blocks: [
    { kind: 'kv', rows: [[t('rep.o.farmers'), String(o.farmers)], [t('rep.h.gi_share'), pct(o.gi_pct)], [t('rep.h.farm_verified'), pct(o.farm_verified_pct)]] },
    { kind: 'table', head: [t('rep.o.village'), t('rep.o.district'), t('rep.o.kg'), t('rep.o.share'), t('rep.o.farmers_n')],
      rows: o.villages.map((v) => [v.village ?? t('rep.o.no_farm'), txt(v.district), kg(v.kg), pct(v.pct), String(v.farmers)]) },
    ...(o.farmer_list ? [{ kind: 'sub' as const, text: t('rep.o.farmer_list') },
      { kind: 'table' as const, head: [t('exp.c.farmer_code'), t('exp.c.farmer_name'), t('rep.o.village'), t('rep.o.district'), t('rep.o.kg'), t('rep.o.lots')],
        rows: o.farmer_list.map((f) => [f.code, f.name, txt(f.village), txt(f.district), kg(f.kg), String(f.lots)]) }] : []),
  ] });

  // Quality
  const unit = (k: string) => d.units[k] ?? (k.endsWith('_pct') ? '%' : '');
  sections.push({ key: 'quality', title: t('rep.s.quality'), blocks: d.quality.length === 0 ? [{ kind: 'text', text: t('rep.none') }] : [
    { kind: 'table', head: [t('rep.q.lot'), t('rep.q.date'), t('exp.mkt.domestic'), t('exp.mkt.export'), t('rep.q.readings'), t('rep.q.lab'), t('rep.q.report'), t('rep.q.file')],
      rows: d.quality.map((q) => [q.code, date(q.on), verdictWord(q.domestic, q.accepted === 'domestic', t), verdictWord(q.export, q.accepted === 'export', t),
        Object.entries(q.readings ?? {}).map(([k, v]) => `${t(`qp.${k}`, undefined, humanise(k.replace(/_(pct|ppb|ppm|kg|mm)$/, '')))} ${String(v)}${unit(k) ? ` ${unit(k)}` : ''}`).join('; ') || '—',
        [q.lab, q.lab_accreditation].filter(Boolean).join(' · ') || '—', [q.report_no, q.report_date ? date(q.report_date) : null].filter(Boolean).join(' · ') || '—',
        q.files ? q.files.split(' ').map((h) => `${h.slice(0, 12)}…`).join(' ') : '—']) },
    ...(d.quality.some((q) => q.accepted) ? [{ kind: 'text' as const, text: t('rep.q.accepted_note'), tone: 'muted' as const }] : []),
  ] });

  // Packing
  const nw = (v: string | null) => (v === 'pass' ? t('rep.p.nw_pass') : v === 'fail' ? t('rep.p.nw_fail') : t('rep.p.nw_none'));
  sections.push({ key: 'packing', title: t('rep.s.packing'), blocks: d.packing.length === 0 ? [{ kind: 'text', text: t('rep.none') }] : [
    { kind: 'table', head: [t('exp.c.batch_code'), t('exp.c.packs'), t('exp.s.by_size'), t('rep.p.serials'), t('rep.p.packed_on'), t('exp.s.best_before'),
      t('rep.p.net_weight'), t('rep.p.wastage'), t('exp.s.void')],
      rows: d.packing.map((p) => [p.batch_code, String(p.packs), txt(p.by_size), `${p.first} – ${p.last}`, date(p.packed_on),
        p.best_before === 'not_recorded' || !p.best_before ? t('exp.bb_old') : date(p.best_before), nw(p.net_weight),
        p.wastage_kg === null || p.wastage_kg === undefined ? '—' : `${kg(p.wastage_kg)} · ${pct(p.wastage_pct)}`, String(p.void)]) },
  ] });

  // Sales and shipments
  const podWord = (p: string, delivered: string | null) => (delivered ? t('rep.s.delivered_on', { on: date(delivered) })
    : p === 'attached' ? t('rep.s.pod_attached') : p === 'awaiting' ? t('rep.s.pod_awaiting') : t('rep.s.not_confirmed'));
  const internal = d.copy === 'internal';
  sections.push({ key: 'sales', title: t('rep.s.sales'), blocks: d.sales.length === 0 ? [{ kind: 'text', text: t('rep.none') }] : [
    { kind: 'table', head: [t('rep.sa.order'), t('exp.c.buyer'), t('exp.c.market'), t('exp.c.order_no'), t('exp.c.packs'), t('rep.o.kg'),
      ...(internal ? [t('rep.sa.price')] : [])],
      rows: d.sales.map((s) => [s.code, txt(s.buyer), [s.market ? t(`exp.mkt.${s.market}`, undefined, s.market) : null, s.country].filter(Boolean).join(' · ') || '—',
        txt(s.order_no), txt(s.packs), kg(s.kg), ...(internal ? [s.price_per_kg ? `${num(s.price_per_kg)} ${s.currency ?? ''}/kg`.trim() : '—'] : [])]) },
    { kind: 'sub', text: t('rep.sa.shipments') },
    { kind: 'table', head: [t('rep.sa.shipment'), t('rep.sa.order'), t('rep.o.kg'), t('exp.c.invoice_no'), t('exp.c.dispatch_date'), t('rep.sa.delivery'), t('rep.sa.qr')],
      rows: d.sales.flatMap((s) => s.shipments.map((x) => [x.code, s.code, kg(x.kg), txt(x.invoice_no), x.dispatch_date ? date(x.dispatch_date) : '—',
        podWord(x.pod, x.delivered_on), txt(x.sealed)])) },
    ...(internal ? [] : [{ kind: 'text' as const, text: t('rep.sa.no_prices'), tone: 'muted' as const }]),
  ] });

  // QR
  const q = d.qr;
  sections.push({ key: 'qr', title: t('rep.s.qr'), blocks: [
    { kind: 'table', head: [t('exp.c.batch_code'), t('exp.s.released'), t('exp.s.released_old'), t('exp.s.held'), t('exp.s.void')],
      rows: q.batches.map((x) => [x.batch_code, String(x.released), String(x.old_data), String(x.held), String(x.void)]) },
    { kind: 'sub', text: t('rep.qr.scans') },
    q.scans_by_city.length ? { kind: 'table', head: [t('rep.qr.city'), t('rep.qr.country'), t('rep.qr.n')],
      rows: q.scans_by_city.map((x) => [x.city || t('rep.qr.unknown'), x.country || '—', String(x.scans)]) } : { kind: 'text', text: t('rep.none') },
    { kind: 'sub', text: t('rep.qr.flags') },
    q.copy_flags.length ? { kind: 'table', head: [t('rep.qr.serial'), t('rep.qr.kind'), t('common.status'), t('rep.qr.raised'), t('rep.qr.outcome')],
      rows: q.copy_flags.map((x) => [x.serial, t(`rep.qr.k.${x.kind}`, undefined, humanise(x.kind)), t(`rep.qr.st.${x.status}`, undefined, humanise(x.status)),
        date(x.raised_at), txt(x.reason)]) } : { kind: 'text', text: t('rep.none') },
    { kind: 'sub', text: t('rep.qr.releases') },
    q.releases.length ? { kind: 'table', head: ['QR', t('common.status'), t('rep.qr.reason'), t('rep.q.date')],
      rows: q.releases.map((x) => [x.qr_code, t(`rep.qr.r.${x.status}`, undefined, humanise(x.status)), txt(x.reason), date(x.at)]) } : { kind: 'text', text: t('rep.none') },
  ] });

  // Chain and integrity
  sections.push({ key: 'chain', title: t('rep.s.chain'), blocks: [
    { kind: 'table', head: [t('exp.s.stage'), t('exp.s.records'), t('rep.ch.recorded'), t('rep.ch.verified'), t('rep.ch.same'), t('rep.ch.returns'), t('rep.ch.flags'),
      t('rep.ch.warnings'), t('rep.ch.manager')],
      rows: d.chain.map((x) => [`${x.pos}. ${stage(x.stage)}`, String(x.records), x.recorded_by.join(', ') || '—', x.verified_by.join(', ') || '—',
        String(x.same_person), x.returns.length ? x.returns.map((r) => `${r.code}: ${r.reason}`).join('; ') : '0',
        x.flags.length ? x.flags.map((f) => `${f.code}: ${f.text} (${t(`badge.${f.status}`, undefined, f.status)})`).join('; ') : '0', String(x.warnings),
        x.manager_records.length ? x.manager_records.map((r) => `${r.code}: ${r.reason}`).join('; ') : '0']) },
  ] });

  // Ledger
  const l = d.ledger;
  sections.push({ key: 'ledger', title: t('rep.s.ledger'), blocks: [{ kind: 'kv', rows: [
    [t('rep.l.last_check'), l.last_check ? `${dateTime(l.last_check.at)} · ${l.last_check.ok ? t('rep.l.ok', { n: l.last_check.blocks }) : t('rep.l.bad', { problem: l.last_check.problem ?? '' })}` : t('rep.l.never')],
    [t('rep.l.blocks'), String(l.blocks)],
    [t('rep.l.first'), txt(l.first_hash)],
    [t('rep.l.last'), txt(l.last_hash)],
  ] }] });

  // Open items (what the close carried over, or what is open now)
  const oi = d.open_items;
  const cl = d.closure;
  const open: [string, string][] = [];
  if (cl) {
    for (const f of cl.answers?.flags ?? []) open.push([t('rep.oi.flag_carried', { code: f.code ?? '' }), f.reason]);
    for (const p of cl.answers?.pod ?? []) open.push([t('rep.oi.awaiting_pod', { code: p.code ?? '' }), p.reason]);
    for (const p of cl.answers?.packs ?? []) open.push([t('rep.oi.packs_written', { batch: p.batch_code ?? '', n: p.held ?? 0 }), p.reason]);
    for (const x of cl.answers?.balance ?? []) open.push([t('rep.oi.balance', { stage: stage(x.stage ?? ''), kg: kg(x.difference_kg) }), x.reason]);
    for (const w of cl.written_off) open.push([t('rep.oi.written_off', { code: w.code, kg: kg(w.kg) }), w.reason.replace(/^Written off at close: /, '')]);
  } else {
    for (const f of oi.flags) open.push([t('rep.oi.flag_open', { code: f.code }), f.text]);
    for (const c2 of oi.awaiting_pod) open.push([t('rep.oi.no_delivery', { code: c2 }), '—']);
    if (oi.pending) open.push([t('rep.oi.pending'), String(oi.pending)]);
    if (oi.lab_hold) open.push([t('rep.oi.lab_hold'), String(oi.lab_hold)]);
    if (oi.packs_held) open.push([t('rep.oi.packs_held'), String(oi.packs_held)]);
  }
  sections.push({ key: 'open_items', title: t('rep.s.open_items'), blocks: [
    ...(cl ? [{ kind: 'kv' as const, rows: [
      [t('rep.oi.closed'), t('rep.oi.closed_v', { v: cl.version, by: cl.confirmed_by ?? '—', at: dateTime(cl.confirmed_at), req: cl.requested_by ?? '—' })] as [string, string]] }] : []),
    open.length ? { kind: 'kv', rows: open } : { kind: 'text', text: t('rep.oi.none') },
  ] });

  // Verification
  sections.push({ key: 'verification', title: t('rep.s.verification'), blocks: [{ kind: 'kv', rows: [
    [t('rep.c.ref'), head.ref], [t('rep.v.url'), verifyUrl], [t('rep.v.data_hash'), head.data_hash],
  ] }, { kind: 'text', text: t('rep.v.how'), tone: 'muted' }] });

  return {
    title: t('rep.title'), ref: head.ref,
    lines: [`${c.client} · ${c.crop}${c.gi_earned && c.gi_tag ? ` · ${c.gi_tag}` : ''} · ${c.season} · ${[c.geography, c.state].filter(Boolean).join(', ')}`,
      `${kind} · ${head.ref} · ${date(head.issued_at)}`],
    banner: head.final ? null : t('rep.interim'),
    copyNote: d.copy === 'internal' ? t('exp.footer_internal') : t('rep.copy_shareable'),
    footer: t('rep.footer'), verifyUrl, verifyLabel: t('rep.v.qr'), sections,
    fileBase: `grainveda-season-report-${head.ref}-${d.copy}`,
  };
}
