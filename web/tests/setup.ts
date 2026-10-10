import '@testing-library/dom';

// Every word, as the signed-in app has them (the public page alone loads only lib/i18n.public.ts).
import { registerDictionary } from '../src/lib/i18n';
import { en } from '../src/lib/i18n.en';
import { hi } from '../src/lib/i18n.hi';
registerDictionary('en', en);
registerDictionary('hi', hi);
