import { useEnvironment } from '../lib/environment';
import { useI18n } from '../lib/i18n';

/** Shown on every screen of a system that is not production (staging, the local stack, a developer's project). */
export function PracticeStrip() {
  const env = useEnvironment();
  const { t } = useI18n();
  if (env !== 'staging') return null;
  return <div className="practice" role="note" data-testid="practice-strip"><span className="long">{t('env.practice')}</span><span className="short">{t('env.practice_short')}</span></div>;
}
