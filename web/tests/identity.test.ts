// Identity layer (migrations 31–33): the pure rules the people screens share. Everything that decides ACCESS is in the
// database (tests/23–27); what is held here shapes what is typed, what is shown, and which screen and menu a person gets.
import { describe, expect, it } from 'vitest';
import { countdown, filterPeople, last4, masked, onThem, onUs, progress, safeFileName, skipsStatutory, stagesAfter, taskCode, taskState,
  validAadhaar, validAccount, validIfsc, validPan, waitingOn, type DirectoryFilter, type DirectoryPerson, type Task } from '../src/lib/people';
import { firstScreen } from '../src/pages/Home';
import { scopeChoices, worksInOneScope } from '../src/shell/scope';
import { NAV, roleWord, type NavWho } from '../src/shell/Layout';
import { sessionExpired, SESSION_HOURS } from '../src/auth/AuthProvider';
import { NO_RIGHTS, type Can } from '../src/lib/types';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';

describe('identity numbers: checked in full on the device, sent as the last four only', () => {
  it('PAN: five letters, four digits, one letter; case and spaces around are forgiven', () => {
    expect(validPan('ABCDE1234F')).toBe(true);
    expect(validPan(' abcde1234f ')).toBe(true);
    for (const bad of ['ABCDE1234', 'ABCD12345F', 'ABCDE12345', '1BCDE1234F', 'ABCDE1234FF', '']) expect(validPan(bad), bad).toBe(false);
  });
  it('Aadhaar: twelve digits with a Verhoeff check digit; one mistyped digit is caught', () => {
    for (const ok of ['499118665246', '2345 6789 0124', '2341-2341-2346']) expect(validAadhaar(ok), ok).toBe(true);
    // every single-digit slip of a valid number is refused: that is what the check digit is for
    const good = '499118665246';
    for (let i = 0; i < 12; i++) for (let d = 0; d < 10; d++) {
      if (String(d) === good[i]) continue;
      const slip = good.slice(0, i) + d + good.slice(i + 1);
      expect(validAadhaar(slip), slip).toBe(false);
    }
    for (const bad of ['123456789012', '049911866524', '49911866524', '4991186652461', 'abcdefghijkl', '']) expect(validAadhaar(bad), bad).toBe(false);
  });
  it('IFSC and account number', () => {
    expect(validIfsc('HDFC0001234')).toBe(true);
    expect(validIfsc('sbin0abc123')).toBe(true);
    for (const bad of ['HDFC1001234', 'HDF00012345', 'HDFC000123', 'HDFC00012345']) expect(validIfsc(bad), bad).toBe(false);
    expect(validAccount('123456789')).toBe(true);
    expect(validAccount('1234 5678 9012 345678')).toBe(true);
    for (const bad of ['12345678', '1234567890123456789', '12345678A', '']) expect(validAccount(bad), bad).toBe(false);
  });
  it('only the last four characters leave the device, and they are shown masked', () => {
    expect(last4('ABCDE1234F')).toBe('234F');
    expect(last4('2345 6789 0124')).toBe('0124');
    expect(last4('abcde1234f')).toBe('234F');
    expect(last4('12-34')).toBe('1234');
    expect(masked('234F')).toBe('•••• 234F');
    expect(masked(null)).toBe('—');
    expect(masked('')).toBe('—');
  });
  it('a file name is made safe for a storage path and keeps its extension', () => {
    expect(safeFileName('PAN card (front).PNG')).toBe('pan-card-front.png');
    expect(safeFileName('आधार.pdf')).toBe('file.pdf');
    // whatever a name carries, what comes out is letters, digits and hyphens, with at most one short extension
    for (const hostile of ['../../etc/passwd', '..\\..\\boot.ini', 'a/b/c.png', '.htaccess', 'x\u0000y.pdf', '   ', 'नाम', 'a.b.c.d.e', 'C:\\fakepath\\card.JPG']) {
      expect(safeFileName(hostile), hostile).toMatch(/^[a-z0-9]+(-[a-z0-9]+)*(\.[a-z0-9]{1,5})?$/);
    }
    expect(safeFileName('noextension')).toBe('noextension');
    expect(safeFileName('a'.repeat(80) + '.jpeg')).toBe('a'.repeat(40) + '.jpeg');
    expect(safeFileName('x.tar.gz!!')).toBe('x-tar.gz');
  });
});

const task = (seq: number, owner: Task['owner'], status: Task['status'] = 'pending'): Task =>
  ({ id: `t${seq}`, seq, code: `c${seq}`, title: `T${seq}`, owner, due_on: '2026-10-10', statutory: false, kind: 'other', status, done_at: null, note: null });

describe('the joiner\'s checklist', () => {
  it('statutory tasks are for full-time employees only (the form\'s hint mirrors app.stamp_tasks)', () => {
    expect(skipsStatutory('full_time')).toBe(false);
    for (const t of ['intern', 'contract', 'consultant'] as const) expect(skipsStatutory(t)).toBe(true);
    expect(skipsStatutory('')).toBe(false);
    expect(skipsStatutory(null)).toBe(false);
  });
  it('a hire\'s own steps are open unless they wait for another (migration 37, B2); HR\'s and IT\'s are "ours"', () => {
    const tasks = [task(1, 'hire', 'done'), task(2, 'hire'), task(3, 'hire'), task(4, 'hr'), task(5, 'it'), task(6, 'hire')];
    // no dependency (the default): every pending step of the hire is open at once, in any order
    expect(tasks.map((t) => taskState(tasks, t))).toEqual(['done', 'open', 'open', 'ours', 'ours', 'open']);
    // a step that waits for another stays locked until that one is done
    const dep = tasks.map((t) => (t.seq === 6 ? { ...t, depends_on: [tasks[1].code] } : t));
    expect(taskState(dep, dep[5])).toBe('locked');
    const done2 = dep.map((t) => (t.seq === 2 ? { ...t, status: 'done' as const } : t));
    expect(taskState(done2, done2[5])).toBe('open');
    // HR's task done is done, whoever owns it
    expect(taskState(tasks, task(4, 'hr', 'done'))).toBe('done');
  });
  it('progress', () => {
    expect(progress([])).toEqual({ total: 0, done: 0, pct: 100 });
    expect(progress([{ status: 'done' }, { status: 'pending' }, { status: 'pending' }])).toEqual({ total: 3, done: 1, pct: 33 });
    expect(progress([{ status: 'done' }, { status: 'done' }])).toEqual({ total: 2, done: 2, pct: 100 });
  });
  it('the countdown to the first day has a wording for every case, in both languages', () => {
    expect(countdown(null)).toEqual({ key: 'join.unknown', n: 0 });
    expect(countdown(undefined)).toEqual({ key: 'join.unknown', n: 0 });
    expect(countdown(0)).toEqual({ key: 'join.today', n: 0 });
    expect(countdown(1)).toEqual({ key: 'join.tomorrow', n: 1 });
    expect(countdown(5)).toEqual({ key: 'join.in_days', n: 5 });
    expect(countdown(-3)).toEqual({ key: 'join.days_ago', n: 3 });
    for (const d of [null, 0, 1, 5, -3]) for (const prefix of ['', 'mine.']) for (const dict of [en, hi] as Record<string, string>[]) {
      expect(dict[`${prefix}${countdown(d).key}`], `${prefix}${countdown(d).key}`).toBeTruthy();
    }
  });
  it('whose turn it is: everyone with a step due by today; if nobody is late, whoever owns the next step', () => {
    expect(waitingOn({ blocked_by: 'hire', waiting_on: ['hr', 'hire'] })).toEqual(['hire', 'hr']);          // a fixed order
    expect(waitingOn({ blocked_by: 'hire', waiting_on: [] })).toEqual(['hire']);
    expect(waitingOn({ blocked_by: 'hire' })).toEqual(['hire']);                                           // a server before `waiting_on`
    expect(waitingOn({ blocked_by: null, waiting_on: [] })).toEqual([]);
    // the fault this was added for: the joiner owns the NEXT step, HR has one overdue. It is waiting on us too.
    const row = { blocked_by: 'hire' as const, waiting_on: ['hire', 'hr'] as Task['owner'][] };
    expect(onUs(row)).toBe(true);
    expect(onThem(row)).toBe(true);
    expect(onUs({ blocked_by: 'hire', waiting_on: [] })).toBe(false);
    expect(onThem({ blocked_by: 'it', waiting_on: [] })).toBe(false);
    expect(onUs({ blocked_by: 'it', waiting_on: [] })).toBe(true);
  });
  it('a task added in the template builder gets a code from its title, unique within the template', () => {
    expect(taskCode('Collect ID card', [])).toBe('collect_id_card');
    expect(taskCode('Collect ID card', ['collect_id_card'])).toBe('collect_id_card_2');
    expect(taskCode('Collect ID card', ['collect_id_card', 'collect_id_card_2'])).toBe('collect_id_card_3');
    expect(taskCode('परिचय पत्र', [])).toBe('task');
    expect(taskCode('X', [])).toBe('x_task');
    expect(taskCode('a'.repeat(60), []).length).toBeLessThanOrEqual(32);
  });
});

const who = (over: Partial<DirectoryPerson>): DirectoryPerson => ({ id: 'p', name: 'P', email: null, phone: null, status: 'active', system_role: 'operational', external: false,
  join_date: null, has_login: true, org: { employment_type: 'full_time', designation_band: null, department: null, job_title: null }, assignments: [], elsewhere: 0, unassigned: true, ...over });
const asg = (client_id: string | null, state_id: string | null) => ({ id: `${client_id}-${state_id}`, lens: 'scope' as const, op_role: 'operator' as const, scope_id: 's', client_id, client_name: null,
  state_id, state_name: null, label: '', scope_status: 'active', stages: [], posting: null, season_code: null, ends_on: null, lapsed: false, active: true, created_at: '', ended_at: null,
  end_reason: null, created_by: null, can_end: false });
const all: DirectoryFilter = { text: '', client: '', state: '', status: '', unassigned: false, kind: 'employees' };

describe('the directory: client and state are two independent lenses', () => {
  const people = [
    who({ id: 'a', name: 'Asha', assignments: [asg('c1', 'up')], unassigned: false }),
    who({ id: 'b', name: 'Bala', assignments: [asg('c1', 'as')], unassigned: false, org: { employment_type: 'contract', designation_band: null, department: 'Quality', job_title: 'Lab Associate' } }),
    who({ id: 'c', name: 'Chand', assignments: [asg('c2', 'up')], unassigned: false, status: 'suspended' }),
    who({ id: 'd', name: 'Dev', email: 'dev@example.test' }),
    who({ id: 'e', name: 'Buyer', external: true, assignments: [asg('c1', null)], unassigned: false }),
  ];
  const ids = (f: Partial<DirectoryFilter>) => filterPeople(people, { ...all, ...f }).map((p) => p.id).join('');
  it('employees and client logins are two lists', () => {
    expect(ids({})).toBe('abcd');
    expect(ids({ kind: 'client_logins' })).toBe('e');
  });
  it('each lens alone, and both together (the same client in another state is a different answer)', () => {
    expect(ids({ client: 'c1' })).toBe('ab');
    expect(ids({ state: 'up' })).toBe('ac');
    expect(ids({ client: 'c1', state: 'up' })).toBe('a');
    expect(ids({ client: 'c2', state: 'as' })).toBe('');
  });
  it('status, unassigned, and a search that reads name, email and the org facts', () => {
    expect(ids({ status: 'suspended' })).toBe('c');
    expect(ids({ unassigned: true })).toBe('d');
    expect(ids({ text: 'lab assoc' })).toBe('b');
    expect(ids({ text: 'QUALITY' })).toBe('b');
    expect(ids({ text: 'dev@' })).toBe('d');
    expect(ids({ text: '  ' })).toBe('abcd');
  });
  it('ticking and unticking a stage', () => {
    expect(stagesAfter(['procurement'], 'qc', true)).toEqual(['procurement', 'qc']);
    expect(stagesAfter(['procurement'], 'procurement', true)).toEqual(['procurement']);
    expect(stagesAfter(['procurement', 'qc'], 'procurement', false)).toEqual(['qc']);
    expect(stagesAfter([], 'qc', false)).toEqual([]);
  });
});

describe('which first screen a person gets', () => {
  const base = { status: 'active', external: false, hr: false, admin: false, assign: false, scopes: [] as { whole: boolean }[], current: null as { whole: boolean } | null };
  it('a joiner sees the checklist until active, whatever has been assigned already', () => {
    expect(firstScreen({ ...base, status: 'invited' })).toBe('joiner');
    expect(firstScreen({ ...base, status: 'onboarding', scopes: [{ whole: false }] })).toBe('joiner');
    expect(firstScreen({ ...base, status: 'onboarding', hr: true })).toBe('joiner');
  });
  it('an employee nobody has assigned is told to wait; HR goes to its pipeline; a manager or a client login gets the overview', () => {
    expect(firstScreen(base)).toBe('unassigned');
    expect(firstScreen({ ...base, hr: true })).toBe('hr');
    expect(firstScreen({ ...base, assign: true })).toBe('overall');
    expect(firstScreen({ ...base, admin: true, hr: true })).toBe('overall');
    expect(firstScreen({ ...base, external: true })).toBe('overall');
    expect(firstScreen({ ...base, external: true, status: 'invited' })).toBe('overall');              // a client login has no checklist
  });
  it('someone who only holds stages in several scopes picks one; in one scope, the stages; whoever reads a scope whole, its screen', () => {
    expect(firstScreen({ ...base, scopes: [{ whole: false }, { whole: false }] })).toBe('pick');
    expect(firstScreen({ ...base, scopes: [{ whole: false }], current: { whole: false } })).toBe('stages');
    expect(firstScreen({ ...base, scopes: [{ whole: true }, { whole: false }] })).toBe('overall');
    expect(firstScreen({ ...base, scopes: [{ whole: true }], current: { whole: true } })).toBe('scope');
    expect(firstScreen({ ...base, hr: true, scopes: [{ whole: false }], current: { whole: false } })).toBe('stages');   // HR who also holds a stage
  });
});

describe('the scopes a person works in', () => {
  const scope = (id: string, over: Record<string, unknown> = {}) => ({ scope_id: id, client_id: 'c', client_name: 'Client', crop_name: 'Rice', season_code: 'KH26', geography: id,
    status: 'active', chain: ['procurement', 'qc', 'qr_activation'] as never[], ...over });
  it('the server says per scope whether the person manages it and reads it whole', () => {
    const got = scopeChoices({ user: { role: 'operator' }, slots: [], scopes: [scope('a', { manage: false, whole: false }), scope('b', { manage: true, whole: true, state_name: 'Assam' }),
      scope('c', { manage: false, whole: true }), scope('z', { status: 'closed', manage: true, whole: true })] });
    expect(got.map((s) => [s.id, s.manage, s.whole])).toEqual([['a', false, false], ['b', true, true], ['c', false, true]]);
    expect(got[1].state_name).toBe('Assam');
    expect(worksInOneScope(got)).toBe(false);
    expect(worksInOneScope(got.slice(0, 1))).toBe(true);
    expect(worksInOneScope([])).toBe(false);
  });
  it('a server from before migration 32 says neither: the one role decides, as it did then', () => {
    const of = (role: string) => scopeChoices({ user: { role }, slots: [], scopes: [scope('a')] })[0];
    expect([of('client_manager').manage, of('client_manager').whole]).toEqual([true, true]);
    expect([of('client_view').manage, of('client_view').whole]).toEqual([false, true]);
    expect([of('operator').manage, of('operator').whole]).toEqual([false, false]);
  });
  it('nobody signed in: nothing', () => {
    expect(scopeChoices(null)).toEqual([]);
    expect(scopeChoices({ user: null, slots: [], scopes: [scope('a')] })).toEqual([]);
  });
});

describe('the menu follows what the server says a person may do', () => {
  const links = (w: Omit<Partial<NavWho>, 'can'> & { can?: Partial<Can> }) =>
    NAV.filter((n) => n.show({ role: 'operator', farmerSlot: false, joiner: false, employee: true, ...w, can: { ...NO_RIGHTS, ...(w.can ?? {}) } })).map((n) => n.to);
  it('someone who only holds stages: the dashboard, and Farmers only with a stage that needs them', () => {
    expect(links({})).toEqual(['/']);
    expect(links({ farmerSlot: true })).toEqual(['/', '/farmers']);
  });
  it('a joiner gets the checklist', () => {
    expect(links({ joiner: true })).toEqual(['/', '/onboarding']);
  });
  it('HR makes people and assigns nobody: HR and People, nothing of scopes, flags, seats', () => {
    expect(links({ can: { hr: true } })).toEqual(['/', '/hr', '/people']);
    expect(links({ can: { hr: true, hr_admin: true } })).toEqual(['/', '/hr', '/people', '/system/audit']);
  });
  it('a manager assigns and makes nobody: People without HR', () => {
    const cm = links({ role: 'client_manager', can: { assign: true } });
    expect(cm).toContain('/people');
    expect(cm).not.toContain('/hr');
    expect(cm).not.toContain('/state');
    expect(cm).not.toContain('/system/seats');
    const sm = links({ role: 'state_manager', can: { assign: true, state_lens: true } });
    expect(sm).toEqual(expect.arrayContaining(['/people', '/state', '/clients', '/health']));
    expect(sm).not.toContain('/hr');
  });
  it('the admin has every entry; the old Users page is gone from the menu', () => {
    const admin = links({ role: 'admin', can: { admin: true, hr: true, hr_admin: true, assign: true, state_lens: true } });
    expect(admin).toEqual(NAV.filter((n) => n.to !== '/onboarding' && n.to !== '/help').map((n) => n.to));   // a joiner's two entries
    expect(NAV.map((n) => n.to)).not.toContain('/users');
  });
  it('every menu entry has its words in both languages', () => {
    for (const n of NAV) { expect((en as Record<string, string>)[n.key], n.key).toBeTruthy(); expect((hi as Record<string, string>)[n.key], n.key).toBeTruthy(); }
  });
  it('the word beside a name: the seat when there is one, "Joining" for a joiner, else the summary role', () => {
    const t = (k: string, _v?: unknown, f?: string) => (en as Record<string, string>)[k] ?? f ?? k;
    expect(roleWord({ role: 'operator', system_role: 'hr_admin', status: 'active' }, t)).toBe('HR Admin');
    expect(roleWord({ role: 'operator', system_role: 'hr_resource', status: 'active' }, t)).toBe('HR');
    expect(roleWord({ role: 'operator', system_role: 'operational', status: 'onboarding' }, t)).toBe('Joining');
    expect(roleWord({ role: 'operator', system_role: 'operational', status: 'invited' }, t)).toBe('Joining');
    expect(roleWord({ role: 'client_view', system_role: 'operational', status: 'invited', external: true }, t)).toBe(t('role.client_view'));
    expect(roleWord({ role: 'admin', system_role: 'admin', status: 'active' }, t)).toBe(t('role.admin'));
    expect(roleWord({ role: 'client_manager' }, t)).toBe(t('role.client_manager'));                  // a server before migration 32
  });
});

describe('how long a sign-in lasts on this device', () => {
  const at = (hoursAgo: number) => new Date(Date.now() - hoursAgo * 3600_000).toISOString();
  it('the long session is for people who only hold stages; HR and the admin read people\'s records and get the short one', () => {
    expect(sessionExpired('operator', at(SESSION_HOURS.manager + 1))).toBe(false);
    expect(sessionExpired('operator', at(SESSION_HOURS.operator + 1))).toBe(true);
    // HR's summary role is "operator" (no scope of its own): the system role decides
    expect(sessionExpired('operator', at(SESSION_HOURS.manager + 1), Date.now(), 'hr_resource')).toBe(true);
    expect(sessionExpired('operator', at(SESSION_HOURS.manager + 1), Date.now(), 'hr_admin')).toBe(true);
    expect(sessionExpired('operator', at(SESSION_HOURS.manager - 1), Date.now(), 'hr_admin')).toBe(false);
    expect(sessionExpired('client_manager', at(SESSION_HOURS.manager + 1))).toBe(true);
    expect(sessionExpired('operator', null)).toBe(false);
  });
});
