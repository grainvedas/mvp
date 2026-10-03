import { execSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

console.log('[build] Building GrainVeda web application...');
execSync('npm --prefix web run build', { stdio: 'inherit' });

const webDist = resolve('web/dist');
const rootDist = resolve('dist');
if (existsSync(webDist)) {
  mkdirSync(rootDist, { recursive: true });
  cpSync(webDist, rootDist, { recursive: true });
  console.log('[build] Output prepared at both ./dist and ./web/dist.');
}
