// FIX_LIST fault 35 (6 October 2026; it was open item 5, "fails now and then", since 3 October).
// The farmer list under the tab "Active" showed the "Ready to verify" list, without the farmer just verified.
// The State Manager taps "Verify and issue Farmer ID" and, before the answer is back, the tab "Active". The verify
// button's "reload the list" was the one made for the old tab: when the answer came it loaded the old tab's list
// and put it under the new tab's name. Two browser tests did exactly this and failed whenever the server was slow.
import { describe, expect, it, vi } from 'vitest';
import { act, renderHook, waitFor } from '@testing-library/react';
import { useAsync } from '../src/lib/useAsync';

describe('a list reloaded by an action that finishes after the person moved on', () => {
  it('loads what is on screen now, not what was on screen when the action began', async () => {
    const load = vi.fn(async (tab: string) => `${tab} list`);
    const { result, rerender } = renderHook(({ tab }) => useAsync(() => load(tab), [tab]), { initialProps: { tab: 'ready to verify' } });
    await waitFor(() => expect(result.current.data).toBe('ready to verify list'));
    const reloadHeldByTheButton = result.current.reload;            // handed to the row while "ready to verify" is shown
    rerender({ tab: 'active' });                                    // the person taps the other tab
    await waitFor(() => expect(result.current.data).toBe('active list'));
    await act(async () => { await reloadHeldByTheButton(); });      // the action's answer arrives: "reload the list"
    expect(load.mock.calls.at(-1)).toEqual(['active']);
    expect(result.current.data).toBe('active list');
  });

  it('an answer that arrives late does not replace a newer one', async () => {
    const waiting: Record<string, (v: string) => void> = {};
    const load = (tab: string) => new Promise<string>((resolve) => { waiting[tab] = resolve; });
    const { result, rerender } = renderHook(({ tab }) => useAsync(() => load(tab), [tab]), { initialProps: { tab: 'slow' } });
    rerender({ tab: 'fast' });
    await act(async () => { waiting.fast('fast list'); });
    await waitFor(() => expect(result.current.data).toBe('fast list'));
    await act(async () => { waiting.slow('slow list'); });          // the first request answers last
    expect(result.current.data).toBe('fast list');
    expect(result.current.loading).toBe(false);
  });
});
