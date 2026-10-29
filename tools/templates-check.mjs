#!/usr/bin/env node
// Dependency-free validator for docs/templates/*.json using Node >=18.
// Uses backend/src/protocol.ts via node --experimental-strip-types not available; 
// so this just parses JSON. The actual schema validation uses backend's validateTaskCard.
// Run via: cd backend && npx vitest run (or add a temp test) - see quickstart.
import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const templatesDir = join(__dirname, "../docs/templates");
const files = readdirSync(templatesDir).filter(f => f.endsWith(".json")).sort();
for (const f of files) {
  const p = join(templatesDir, f);
  try {
    JSON.parse(readFileSync(p, "utf8"));
    console.log(`ok: ${f}`);
  } catch (e) {
    console.error(`bad: ${f} ${e.message}`);
    process.exit(1);
  }
}
console.log(`All ${files.length} templates parsed OK.`);
