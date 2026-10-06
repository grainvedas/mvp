// "My account": who am I signed in as, change my password, which build and which system this is (for support calls).
import { useAuth } from '../auth/AuthProvider';
import { PasswordForm } from '../auth/SetPassword';
import { useI18n } from '../lib/i18n';
import { useEnvironment } from '../lib/environment';
import { BUILD_ID } from '../lib/errorLog';
import { humanise } from '../lib/format';
import { Link } from 'react-router-dom';
import { roleWord } from '../shell/Layout';

export function Account() {
  const { t } = useI18n();
  const { ctx } = useAuth();
  const me = ctx!.user!;
  const env = useEnvironment();
  return (
    <div style={{ maxWidth: 560 }}>
      <h1><span aria-hidden="true">🔑 </span>{t('account.title')}</h1>
      <div className="card">
        <dl className="kv" data-testid="account-me">
          <dt>{t('farmer.name')}</dt><dd>{me.display_name}</dd>
          <dt>{t('account.role')}</dt><dd>{roleWord(me, t)}</dd>
          <dt>{t('account.sign_in')}</dt><dd>{me.email ?? me.phone ?? '—'}</dd>
          {me.client_name && <><dt>{t('account.client')}</dt><dd>{me.client_name}</dd></>}
        </dl>
        {/* what opens what: the assignments, as the server lists them */}
        {(ctx!.assignments?.length ?? 0) > 0 && <>
          <div className="section-title">{t('axis.assignments')}</div>
          <ul data-testid="my-assignments">{ctx!.assignments!.map((a) => (
            <li key={a.id}>{t(`oprole.${a.op_role}`)} · {a.label}{a.stages.length > 0 && <> · {a.stages.map((s) => t(`stage.${s}`, undefined, humanise(s))).join(', ')}</>}
              {a.ends_on && <span className="muted small"> · {t('assign.ends_on', { d: a.ends_on })}</span>}</li>))}</ul></>}
        {(ctx!.onboarding?.total ?? 0) > 0 && !me.external && <p><Link to="/onboarding">{t('nav.onboarding')}</Link> · {t('mine.progress', { done: ctx!.onboarding!.total - ctx!.onboarding!.open, total: ctx!.onboarding!.total })}</p>}
      </div>
      <div className="card">
        <h2>{t('account.change_password')}</h2>
        <PasswordForm />
      </div>
      <p className="muted small" data-testid="account-build">
        {t('account.build', { build: BUILD_ID })}{env && <> · {t(env === 'production' ? 'health.env_production' : 'health.env_staging')}</>}
      </p>
    </div>
  );
}
