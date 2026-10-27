// Migration 71 (Part E1): the evidence pack as a document, in the reader's language, from the data the server kept when the
// pack was issued (app.ep_lot_data, app.ep_order_data). One model, drawn as an A4 PDF by lib/reportPdf.ts (the season
// report's writer: the verify QR on the cover, the footer on every page). A client order's pack has one section per scope.
// Wording (the brief): the title "Verified traceability statement: evidence pack"; the footer "This statement records what
// GrainVeda verified under its published protocol. It is not a quality, residue or Geographical Indication certificate.";
// never "certificate" otherwise; a release on the client's written acceptance is said as such, never "Passed".
// Pure: no fetch, no clock (the dates are the pack's).
import type { Block, ReportDoc, Section, Tone } from './reportModel';
import type { LotPack, PackData, PackHead } from './evidencePacks';
import { isOrderPack } from './evidencePacks';
import { date, dateTime, humanise, kg, num } from './format';

type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;
const pct = (v: number | null | undefined) => (v === null || v === undefined ? '—' : `${num(v, 1)} %`);
const txt = (v: unknown) => (v === null || v === undefined || v === '' ? '—' : String(v));
const n0 = (v: number | null | undefined) => Number(v ?? 0);
const short = (h: string | null | undefined) => (h ? `${h.slice(0, 16)}…` : '—');

/** Pure: a market's verdict as the pack says it; a release on the client's acceptance is said as such, never "Passed". */
export function packVerdict(verdict: string, accepted: boolean, t: T) {
  if (accepted) return t('rep.q.accepted');
  return t(`rep.v.${verdict}`, undefined, humanise(verdict));
}

/** Pure: what a pack is of, in words ("Shipment PRSDM-…-SH-0001"). */
export function subjectLine(kind: string, code: string, t: T) {
  return t(`ep.of.${kind}`, { code }, `${humanise(kind)} ${code}`);
}

/** Pure: the sections of one lot or shipment (each a title and its blocks). */
export function lotSections(d: LotPack, t: T): Section[] {
  const stage = (s: string) => t(`stage.${s}`, undefined, humanise(s));
  const out: Section[] = [];
  const internal = d.internal;

  // Origin
  const o = d.origin;
  const gi = o.gi_status === 'gi' ? t('ep.gi.gi') : o.gi_status === 'non_gi' ? t('ep.gi.non_gi') : t('ep.gi.unknown');
  out.push({ key: 'origin', title: t('ep.s.origin'), blocks: [
    { kind: 'kv', rows: [
      [t('ep.o.farmers'), String(o.farmers)],
      [t('ep.o.gi_status'), gi],
      [t('ep.o.gi_share'), pct(o.gi_pct)],
      [t('ep.o.farm_verified'), `${pct(o.farm_verified_pct)}${o.farm_verified ? ` · ${t('ep.o.all_verified')}` : ''}`],
    ] },
    { kind: 'table', head: [t('rep.o.village'), t('rep.o.district'), t('rep.o.share'), t('rep.o.farmers_n')],
      rows: o.villages.map((v) => [v.village ?? t('rep.o.no_farm'), txt(v.district), pct(v.share_pct), String(v.farmers)]) },
    ...(o.districts.length > 1 ? [{ kind: 'table' as const, head: [t('rep.o.district'), t('rep.o.share')],
      rows: o.districts.map((x) => [txt(x.district), pct(x.share_pct)]) }] : []),
    ...(internal && o.farmer_list ? [{ kind: 'sub' as const, text: t('ep.o.farmer_list') },
      { kind: 'table' as const, head: [t('exp.c.farmer_code'), t('exp.c.farmer_name'), t('rep.o.village'), t('rep.o.district'), t('rep.o.share')],
        rows: o.farmer_list.map((f) => [f.code, f.name, txt(f.village), txt(f.district), pct(f.share_pct)]) }] : []),
    { kind: 'text', text: t('ep.o.shares_note'), tone: 'muted' },
  ] });

  // Mass balance
  const b = d.mass_balance;
  const mill = b.stages.find((x) => x.stage === 'milling' && x.outturn_pct !== undefined);
  const pack = b.stages.find((x) => x.stage === 'packing' && x.wastage_pct !== undefined);
  const qc = b.stages.find((x) => x.stage === 'qc');
  const lost = (x: LotPack['mass_balance']['stages'][number]) => n0(x.floor_loss_kg) + n0(x.closed_kg) + n0(x.written_off_kg);
  out.push({ key: 'balance', title: t('ep.s.balance'), blocks: [
    { kind: 'kv', rows: [[t('ep.b.flow'), `${kg(b.procured_kg)} → ${kg(b.sold_kg)} → ${kg(b.shipped_kg)}`]] },
    { kind: 'table', head: [t('exp.s.stage'), t('rep.b.in'), t('rep.b.out'), t('rep.b.byp'), t('ep.b.floor'), t('ep.b.transit')],
      rows: b.stages.map((x) => [`${x.pos ?? ''}${x.pos ? '. ' : ''}${stage(x.stage)}`, kg(x.in_kg ?? 0), kg(x.out_kg ?? 0),
        kg(n0(x.by_products_kg) + n0(x.other_kg)), kg(lost(x)), kg(x.transit_kg ?? 0)]) },
    ...(mill ? [{ kind: 'kv' as const, rows: [
      [t('ep.b.outturn'), t('ep.b.outturn_v', { pct: num(mill.outturn_pct, 1), ceiling: num(mill.ceiling_pct, 0) })],
      [t('exp.c.head_rice_kg'), kg(mill.head_rice_kg ?? 0)], [t('exp.c.broken_kg'), kg(mill.broken_kg ?? 0)],
      [t('exp.c.husk_kg'), kg(mill.husk_kg ?? 0)], [t('exp.c.bran_kg'), kg(mill.bran_kg ?? 0)],
    ] as [string, string][] }] : []),
    ...(mill?.over_ceiling ? [{ kind: 'text' as const, text: t('ep.b.over_ceiling', { ceiling: num(mill.ceiling_pct, 0) }), tone: 'danger' as const }] : []),
    ...(qc && n0(qc.sample_kg) > 0 ? [{ kind: 'kv' as const, rows: [[t('ep.b.sample'), kg(qc.sample_kg ?? 0)]] as [string, string][] }] : []),
    ...(pack ? [{ kind: 'kv' as const, rows: [[t('rep.p.wastage'), `${kg(pack.wastage_kg ?? 0)} · ${pct(pack.wastage_pct)}`]] as [string, string][] }] : []),
    { kind: 'text', text: b.sold_within_procured ? t('rep.b.check_ok', { sold: kg(b.sold_kg), procured: kg(b.procured_kg) })
        : t('rep.b.check_bad', { sold: kg(b.sold_kg), procured: kg(b.procured_kg) }), tone: b.sold_within_procured ? 'ok' : 'danger' },
  ] });

  // Quality
  out.push({ key: 'quality', title: t('ep.s.quality'), blocks: d.quality.length === 0 ? [{ kind: 'text', text: t('rep.none') }] : [
    { kind: 'table', head: [t('rep.q.lot'), t('ep.q.verdicts'), t('rep.q.lab'), t('rep.q.report'), t('rep.q.file')],
      rows: d.quality.map((q) => [`${q.code}${q.on ? ` · ${date(q.on)}` : ''}${q.sample ? ` · ${t('ep.q.sample', { code: q.sample })}` : ''}`,
        q.markets.map((m) => `${m.name}: ${packVerdict(m.verdict, q.accepted && m.verdict !== 'pass'
          && (!q.accepted_market || m.code === q.accepted_market || m.code.startsWith(q.accepted_market)), t)}`).join('; ') || '—',
        [q.lab, q.accreditation_no ? t('ep.q.accreditation', { no: q.accreditation_no }) : null].filter(Boolean).join(' · ') || '—',
        [q.report_no, q.report_date ? date(q.report_date) : null].filter(Boolean).join(' · ') || '—',
        q.files.length ? q.files.map((f) => `${t(`ep.file.${f.label}`, undefined, humanise(f.label))} ${short(f.sha256)}`).join('; ') : '—']) },
    ...(d.quality.some((q) => q.accepted) ? [{ kind: 'text' as const, text: t('rep.q.accepted_note'), tone: 'muted' as const }] : []),
  ] });

  // Documents
  const sh = d.documents.shipment;
  const docRows: [string, string][] = sh ? ([['invoice_no', sh.invoice_no], ['lr_no', sh.lr_no], ['eway_bill_no', sh.eway_bill_no], ['container_no', sh.container_no],
    ['seal_no', sh.seal_no], ['shipping_bill_no', sh.shipping_bill_no], ['bl_no', sh.bl_no]] as const)
    .filter(([, v]) => v).map(([k, v]) => [t(`bv.${k}`), String(v)] as [string, string]) : [];
  if (sh?.delivered) docRows.push([t('bv.delivered'), `${date(sh.delivered.on)} · ${kg(sh.delivered.received_kg)}`]);
  out.push({ key: 'documents', title: t('ep.s.documents'), blocks: [
    ...(sh ? [{ kind: 'sub' as const, text: t('ep.d.shipment', { code: sh.code }) }, docRows.length ? { kind: 'kv' as const, rows: docRows } : { kind: 'text' as const, text: t('rep.none') }] : []),
    ...(d.documents.export.length ? [{ kind: 'sub' as const, text: t('ep.d.export') }, { kind: 'table' as const, head: [t('ep.d.doc'), t('common.status'), t('ep.d.sha')],
      rows: d.documents.export.map((x) => [x.doc, t(`bv.doc_${x.status ?? 'missing'}`, undefined, humanise(x.status ?? 'missing')), short(x.sha256)]) }] : []),
    { kind: 'sub', text: t('ep.d.files') },
    d.documents.files.length ? { kind: 'table', head: [t('ep.d.doc'), t('ep.d.record'), t('ep.d.sha')],
      rows: d.documents.files.map((f) => [t(`ep.file.${f.label}`, undefined, humanise(f.label)), f.record, f.sha256]) } : { kind: 'text', text: t('rep.none') },
  ] });

  // Chain
  out.push({ key: 'chain', title: t('ep.s.chain'), blocks: [
    { kind: 'table', head: [t('exp.s.stage'), t('ep.c.records'), t('rep.ch.recorded'), t('rep.ch.verified'), t('ep.c.dates'), t('rep.ch.same'), t('ep.c.returns_flags')],
      rows: d.chain.map((x) => [`${x.pos ?? ''}${x.pos ? '. ' : ''}${stage(x.stage)}`, `${x.records}: ${x.codes.join(', ')}${x.records > x.codes.length ? ' …' : ''}`,
        `${(x.recorded_by ?? []).join(', ') || '—'}${x.client_staff ? ` · ${t('ep.c.client_staff', { n: x.client_staff })}` : ''}`,
        (x.verified_by ?? []).join(', ') || (x.stage === 'qr_activation' ? t('ep.c.sealed') : '—'),
        x.first_on === x.last_on ? date(x.first_on) : `${date(x.first_on)} – ${date(x.last_on)}`,
        x.same_person ? t('ep.c.same_n', { n: x.same_person }) : '0',
        [...x.returns.map((r) => t('ep.c.return', { code: r.code, reason: r.reason, status: t(`ep.st.${r.status}`, undefined, humanise(r.status)) })),
         ...x.flags.map((f) => t('ep.c.flag', { code: f.code, text: f.text, status: t(`badge.${f.status}`, undefined, humanise(f.status)) }))].join('; ') || '0']),
      tones: d.chain.map((x) => (x.same_person > 0 ? ('danger' as Tone) : undefined)) },
  ] });

  // Packs
  const p = d.packs;
  out.push({ key: 'packs', title: t('ep.s.packs'), blocks: [
    { kind: 'kv', rows: [[t('ep.p.count'), String(p.count)]] },
    p.batches.length ? { kind: 'table', head: [t('exp.c.batch_code'), t('exp.c.packs'), t('ep.p.sizes'), t('rep.p.serials'), t('rep.p.packed_on'), t('exp.s.best_before')],
      rows: p.batches.map((x) => [x.batch_code, `${x.packs} · ${kg(x.kg)}`, txt(x.sizes), x.ranges.join('; '), date(x.packed_on),
        x.best_before ? date(x.best_before) : t('exp.bb_old')]) } : { kind: 'text', text: t('rep.none') },
    ...(p.old_data ? [{ kind: 'text' as const, text: t('ep.p.old_data'), tone: 'muted' as const }] : []),
    ...(p.scanned?.length ? [{ kind: 'sub' as const, text: t('ep.p.scanned', { n: p.scanned.length }) }, { kind: 'text' as const, text: p.scanned.join(', ') }] : []),
  ] });

  // Sale (the internal copy, where the scope records prices)
  if (internal && d.price) {
    out.push({ key: 'price', title: t('ep.s.price'), blocks: [{ kind: 'kv', rows: [
      [t('rep.sa.price'), d.price.price_per_kg ? `${num(d.price.price_per_kg)} ${d.price.currency ?? ''}/kg`.trim() : '—'],
      [t('ep.pr.total'), d.price.total_value ? `${num(d.price.total_value)} ${d.price.currency ?? ''}`.trim() : '—'],
      [t('ep.pr.incoterms'), txt(d.price.incoterms)],
    ] }] });
  }

  // Verification (the lot's)
  const v = d.verification;
  out.push({ key: 'ledger', title: t('ep.s.ledger'), blocks: [
    ...(v.seal ? [{ kind: 'kv' as const, rows: [[t('ep.v.seal'), `${v.seal.qr_code} · ${dateTime(v.seal.sealed_at)}`], [t('ep.v.seal_hash'), v.seal.ledger_hash]] as [string, string][] }] : []),
    v.blocks.length ? { kind: 'table', head: [t('exp.s.stage'), t('ep.d.record'), t('ep.v.block'), t('ep.v.hash')],
      rows: v.blocks.map((x) => [stage(x.stage), x.code, `#${x.seq} · ${t(`ep.ev.${x.event}`, undefined, humanise(x.event))}`, x.hash]) } : { kind: 'text', text: t('rep.none') },
    ...(v.procurement_blocks ? [{ kind: 'text' as const, text: t('ep.v.procurement_blocks', { n: v.procurement_blocks }), tone: 'muted' as const }] : []),
  ] });
  return out;
}

function lotHeaderRows(h: LotPack['header'], t: T): [string, string][] {
  return [
    [t('ep.h.scope'), [h.scope, h.state].filter(Boolean).join(' · ')],
    [t('ep.h.lot'), `${h.lot}${h.qr_code ? ` · QR ${h.qr_code}` : ''}`],
    ...(h.sealed_at ? [[t('ep.h.sealed'), dateTime(h.sealed_at)] as [string, string]] : []),
    ...(h.shipment ? [[t('ep.h.shipment'), `${h.shipment}${h.dispatch_date ? ` · ${date(h.dispatch_date)}` : ''}`] as [string, string]] : []),
    ...(h.sale ? [[t('ep.h.sale'), h.sale] as [string, string]] : []),
    ...(h.data_note === 'practice_old_data' ? [[t('exp.h.data_note'), t('scope.old_data')] as [string, string]] : []),
  ];
}

function buyerRows(h: { buyer: string | null; buyer_country: string | null; market: string | null; market_name: string | null; destination_country: string | null;
  order_no: string | null; invoice_no: string | null; client_order?: string | null }, t: T): [string, string][] {
  const rows: [string, string][] = [];
  if (h.buyer) rows.push([t('exp.c.buyer'), `${h.buyer}${h.buyer_country ? ` · ${h.buyer_country}` : ''}`]);
  if (h.market) rows.push([t('exp.c.market'), `${t(`exp.mkt.${h.market}`, undefined, h.market)}${h.market === 'export' && h.market_name ? ` · ${h.market_name}` : ''}${h.destination_country ? ` · ${h.destination_country}` : ''}`]);
  if (h.order_no) rows.push([t('exp.c.order_no'), h.order_no]);
  if (h.invoice_no) rows.push([t('exp.c.invoice_no'), h.invoice_no]);
  if (h.client_order) rows.push([t('ep.h.client_order'), h.client_order]);
  return rows;
}

/** The evidence pack as a document: the header (with the verify QR beside it), the sections, the verification. */
export function packDocument(head: PackHead, d: PackData, t: T, origin: string): ReportDoc {
  const verifyUrl = `${origin}/d/${head.ref}`;
  const version = t('ep.version', { n: head.version });
  const copyRows: [string, string][] = [
    [t('rep.c.ref'), head.ref], [t('rep.c.version'), version],
    [t('rep.c.issued'), `${dateTime(head.issued_at)}${head.issued_by ? ` · ${head.issued_by}` : ''}${head.auto ? ` · ${t('ep.auto')}` : ''}`],
    [t('rep.c.issued_to'), head.issued_to],
    [t('rep.c.copy'), t(d.internal ? 'exp.copy_internal' : 'exp.copy_shareable')],
  ];
  const sections: Section[] = [];
  let lines: string[];
  if (isOrderPack(d)) {
    const h = d.header;
    const states = [...new Set(d.scopes.map((s) => s.state).filter(Boolean))].join(', ');
    // the GI tag only where every part earned it (the parts of an order share their GI status)
    const lots = d.scopes.flatMap((s) => s.lots);
    const gi = lots.length > 0 && lots.every((l) => l.origin.gi_status === 'gi') && h.gi_tag ? ` · ${h.gi_tag}` : '';
    sections.push({ key: 'header', title: t('ep.s.header'), blocks: [{ kind: 'kv', rows: [
      [t('rep.c.client'), h.client], [t('rep.c.crop'), `${h.crop}${gi}`],
      [t('ep.h.subject'), subjectLine('order', h.client_order, t)],
      [t('ep.h.scopes'), t('ep.h.scopes_v', { n: d.scopes.length, states })],
      ...buyerRows({ ...h, order_no: h.order_no, client_order: null }, t),
      ...copyRows,
    ] }] });
    d.scopes.forEach((s, si) => {
      const blocks: Block[] = [{ kind: 'kv', rows: [[t('rep.c.season'), s.season], [t('rep.c.state'), txt(s.state)], [t('ep.h.parts'), String(s.lots.length)]] }];
      s.lots.forEach((lot, i) => {
        blocks.push({ kind: 'sub', text: t('ep.part', { n: i + 1, code: lot.header.shipment ?? lot.header.sale ?? lot.header.top }) });
        blocks.push({ kind: 'kv', rows: [...lotHeaderRows(lot.header, t), ...(lot.header.invoice_no ? [[t('exp.c.invoice_no'), lot.header.invoice_no] as [string, string]] : [])] });
        for (const sec of lotSections({ ...lot, internal: d.internal }, t)) {
          blocks.push({ kind: 'sub', text: sec.title });
          blocks.push(...sec.blocks);
        }
      });
      sections.push({ key: `scope-${si + 1}`, title: t('ep.s.scope', { scope: s.scope, state: s.state ?? '' }), blocks });
    });
    lines = [`${h.client} · ${h.crop}${gi} · ${subjectLine('order', h.client_order, t)}`,
      `${version} · ${head.ref} · ${date(head.issued_at)}`];
  } else {
    const h = d.header;
    const kind = d.kind ?? head.subject_kind;
    const giEarned = d.origin.gi_status === 'gi';
    sections.push({ key: 'header', title: t('ep.s.header'), blocks: [{ kind: 'kv', rows: [
      [t('rep.c.client'), h.client], [t('rep.c.crop'), `${h.crop}${giEarned && h.gi_tag ? ` · ${h.gi_tag}` : ''}`],
      [t('rep.c.season'), h.season],
      [t('ep.h.subject'), subjectLine(kind, head.subject_code, t)],
      ...lotHeaderRows(h, t),
      ...(kind === 'shipment' ? buyerRows(h, t) : []),
      ...copyRows,
    ] }] });
    sections.push(...lotSections(d, t));
    lines = [`${h.client} · ${h.crop}${giEarned && h.gi_tag ? ` · ${h.gi_tag}` : ''} · ${h.season} · ${[h.geography, h.state].filter(Boolean).join(', ')}`,
      `${subjectLine(kind, head.subject_code, t)} · ${version} · ${head.ref} · ${date(head.issued_at)}`];
  }
  sections.push({ key: 'verification', title: t('ep.s.verification'), blocks: [{ kind: 'kv', rows: [
    [t('rep.c.ref'), head.ref], [t('rep.v.url'), verifyUrl], [t('ep.v.data_hash'), head.data_hash],
  ] }, { kind: 'text', text: t('ep.v.how'), tone: 'muted' }] });
  return {
    title: t('ep.title'), ref: head.ref, lines,
    banner: null,   // a pack's files are the same whenever they are made: its state (valid, superseded) is on the verify page
    copyNote: d.internal ? t('exp.footer_internal') : t('rep.copy_shareable'),
    footer: t('rep.footer'), verifyUrl, verifyLabel: t('rep.v.qr'), sections,
    fileBase: `grainveda-evidence-pack-${head.ref}-${d.internal ? 'internal' : 'shareable'}`,
  };
}
