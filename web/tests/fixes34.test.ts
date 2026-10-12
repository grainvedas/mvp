// Open item 34 (13 Oct 2026, seen on staging after migration 39): the base-location audit line said no state; an HR
// resource's state filter listed every state; "1 people"; the offboard exit date was the UTC date (a day early from
// 00:00 to 05:30 IST). The pure rules the screens follow.
import { describe, expect, it } from 'vitest';
import { fromTo, todayIST } from '../src/lib/format';
import { translate } from '../src/lib/i18n';
import { stateChoices } from '../src/pages/hr/Geo';
import { hi } from '../src/lib/i18n.hi';

describe('open item 34', () => {
  it('today is the date in India, not the UTC date', () => {
    expect(todayIST(Date.parse('2026-10-12T21:45:00Z'))).toBe('2026-10-13');   // 03:15 IST on 13 Oct: the staging case
    expect(todayIST(Date.parse('2026-10-12T18:29:00Z'))).toBe('2026-10-12');   // 23:59 IST
    expect(todayIST(Date.parse('2026-10-12T18:30:00Z'))).toBe('2026-10-13');   // midnight IST
  });
  it('an audit line shows where a person was based and where now, a dash for nothing before', () => {
    expect(fromTo('', 'Uttar Pradesh')).toBe('— → Uttar Pradesh');            // the first base location (the staging case)
    expect(fromTo('Bihar · Patna', 'Uttar Pradesh · Gorakhpur')).toBe('Bihar · Patna → Uttar Pradesh · Gorakhpur');
    expect(fromTo('—', 'Uttar Pradesh')).toBe('— → Uttar Pradesh');           // HR states, as before
    expect(fromTo('hr_resource', 'operational')).toBe('Hr Resource → Operational');
    expect(fromTo(undefined, 'Uttar Pradesh')).toBe('');                       // entries without a "from" say nothing, as before
    expect(fromTo('Bihar', '')).toBe('');
    expect(fromTo('Bihar', undefined)).toBe('');
  });
  it('an HR resource is offered only her states to filter by; the HR Admin and a manager every state', () => {
    const all = [{ id: 'b', name: 'Bihar' }, { id: 'u', name: 'Uttar Pradesh' }, { id: 'k', name: 'Uttarakhand' }];
    expect(stateChoices(all, { full: false, hr: true, states: [{ id: 'u', name: 'Uttar Pradesh' }] }).map((s) => s.name)).toEqual(['Uttar Pradesh']);
    expect(stateChoices(all, { full: true, hr: true, states: [] })).toEqual(all);
    expect(stateChoices(all, { full: false, hr: false, states: [] })).toEqual(all);
    expect(stateChoices(all, null)).toEqual(all);
  });
  it('one person, not "1 people", in both languages; other counts unchanged', () => {
    for (const k of ['seats.code_refused', 'open.not_linked', 'imp.done', 'imp.invite', 'jl.count']) {
      for (const lang of ['en', 'hi'] as const) {
        expect(translate(lang, k, { n: 1 }), `${lang} ${k}`).not.toMatch(/1 (people|लोग)/);
        expect(translate(lang, k, { n: 2 }), `${lang} ${k}`).toBe(translate(lang, k, { n: 2 }).replace('{n}', '2'));
      }
      expect((hi as Record<string, string>)[`${k}.one`], k).toBeTruthy();
    }
    expect(translate('en', 'jl.count', { n: 1 })).toBe('1 person');
    expect(translate('en', 'jl.count', { n: 2 })).toBe('2 people');
    expect(translate('hi', 'jl.count', { n: 1 })).toBe('1 व्यक्ति');
    expect(translate('en', 'open.not_linked', { n: '1' })).toMatch(/^1 person joining or joined is on no opening/);
    expect(translate('en', 'jl.count', { n: 0 })).toBe('0 people');
  });
});
