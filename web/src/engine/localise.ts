// Stage and field labels come from the database in English (stage_definitions). The operator's language is applied
// here, by key, from the same dictionary as the rest of the UI (stage.<type>, field.<key>, check.<English text>,
// qp.<param>, opt.<value>). Anything without a translation stays in English.
import type { StageForm } from '../lib/types';

type T = (key: string, vars?: Record<string, string | number>, fallback?: string) => string;

export function localiseForm(f: StageForm, t: T): StageForm {
  const stage = (type: string, label: string) => t(`stage.${type}`, undefined, label);
  const check = (c: string) => t(`check.${c}`, undefined, c);
  return {
    ...f,
    stage: {
      ...f.stage,
      label: stage(f.stage.stage_type, f.stage.label),
      form_schema: f.stage.form_schema.map((fd) => ({
        ...fd, label: t(`field.${f.stage.stage_type}.${fd.key}`, undefined, t(`field.${fd.key}`, undefined, fd.label)),
      })),
      handoff_checks: f.stage.handoff_checks.map(check),
    },
    prev_stage: f.prev_stage && { ...f.prev_stage, label: stage(f.prev_stage.stage_type, f.prev_stage.label), handoff_checks: f.prev_stage.handoff_checks.map(check) },
    next_stage: f.next_stage && { ...f.next_stage, label: stage(f.next_stage.stage_type, f.next_stage.label) },
    quality_params: f.quality_params.map((q) => ({ ...q, label: t(`qp.${q.param}`, undefined, q.label) })),
  };
}
