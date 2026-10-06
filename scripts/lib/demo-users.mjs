// The demo logins, keyed by the last three digits of their app_users id (seeds 02, 03, 04, 05, 06).
// Managers sign in by email + password, operators by phone + password (development only: no SMS needed).
// Production operators will use phone OTP once DLT registration is done (execution plan, workstream D).
export const DEMO_USERS = [
  { key: '301', role: 'admin',          name: 'Veda (Admin)',               email: 'grainvedas+admin@gmail.com' },
  { key: '302', role: 'state_manager',  name: 'UP State Manager',           email: 'grainvedas+statemanager@gmail.com' },
  { key: '303', role: 'client_manager', name: 'Prasaadam Client Manager',   email: 'grainvedas+clientmanager@gmail.com' },
  { key: '304', role: 'client_view',    name: 'Prasaadam Client View',      email: 'grainvedas+clientview@gmail.com' },
  { key: '305', role: 'operator',       name: 'Procurement Op (field)',     phone: '+910000000005' },
  { key: '306', role: 'operator',       name: 'QC Technician',              phone: '+910000000006' },
  { key: '307', role: 'operator',       name: 'QR Sealer',                  phone: '+910000000007' },
  { key: '308', role: 'operator',       name: 'Mill Operator',              phone: '+910000000008' },
  { key: '309', role: 'operator',       name: 'Sorting Operator',           phone: '+910000000009' },
  { key: '310', role: 'operator',       name: 'Grading Operator',           phone: '+910000000010' },
  { key: '311', role: 'operator',       name: 'Commercial Manager',         phone: '+910000000011' },
  { key: '312', role: 'operator',       name: 'Demo Exporter Op (other client)', phone: '+910000000012' },
  { key: '313', role: 'operator',       name: 'Lot Inward Operator',        phone: '+910000000013' },
  { key: '314', role: 'operator',       name: 'Shipment Operator',          phone: '+910000000014' },
  { key: '315', role: 'operator',       name: 'Village Batch Operator',     phone: '+910000000015' },
  // Identity layer (seed 06): the HR seats, an employee with no assignment yet, a joiner on the way in.
  { key: '316', role: 'hr_admin',       name: 'Asha (HR Admin)',            email: 'grainvedas+hradmin@gmail.com' },
  { key: '317', role: 'hr_resource',    name: 'Imran (HR)',                 email: 'grainvedas+hr@gmail.com' },
  { key: '318', role: 'unassigned',     name: 'Ravi Kumar',                 email: 'grainvedas+ravi@gmail.com' },
  { key: '319', role: 'joiner',         name: 'Meera Joshi',                email: 'grainvedas+meera@gmail.com' },
];

export const appUserId = (key) => `00000000-0000-4000-8000-000000000${key}`;
export const demoUser = (key) => DEMO_USERS.find((u) => u.key === key);
