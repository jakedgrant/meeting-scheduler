// Generates the web client's `Database` type from supabase/migrations.
//
// The migrations run in PGlite, so no Docker, server or hosted project is
// needed, and the result describes this checkout rather than whatever a
// hosted project has deployed. The output follows the shape `supabase gen
// types typescript` produces for the `public` schema, which supabase-js
// accepts as its schema parameter.
//
//   node scripts/generate-database-types.mjs           rewrite the file
//   node scripts/generate-database-types.mjs --check   fail if it is stale
import { PGlite } from '@electric-sql/pglite';
import { readFile, writeFile } from 'node:fs/promises';
import { bootstrapCreationDatabase } from '../tests/helpers/creation-database.mjs';

const output = new URL('../apps/web/src/lib/database.types.ts', import.meta.url);
const check = process.argv.includes('--check');

const db = new PGlite();
await bootstrapCreationDatabase(db);
const rows = async (sql) => (await db.query(sql)).rows;

const enums = await rows(`
  SELECT t.typname AS name, array_agg(e.enumlabel ORDER BY e.enumsortorder) AS labels
  FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' GROUP BY t.typname ORDER BY t.typname`);
const enumNames = new Set(enums.map(e => e.name));

const columns = await rows(`
  SELECT c.relname AS relation, a.attname AS name, a.attnotnull AS not_null,
         a.atthasdef AS has_default, a.attidentity <> '' AS identity, a.attgenerated <> '' AS generated,
         t.typname AS type, t.typcategory = 'A' AS is_array, et.typname AS element_type
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
  JOIN pg_type t ON t.oid = a.atttypid
  LEFT JOIN pg_type et ON et.oid = t.typelem AND t.typcategory = 'A'
  WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
  ORDER BY c.relname, a.attname`);

const relationships = await rows(`
  SELECT c.relname AS relation, con.conname AS name, r.relname AS referenced,
         ARRAY(SELECT attname FROM unnest(con.conkey) WITH ORDINALITY k(num, i)
               JOIN pg_attribute ON attrelid = con.conrelid AND attnum = k.num ORDER BY i) AS columns,
         ARRAY(SELECT attname FROM unnest(con.confkey) WITH ORDINALITY k(num, i)
               JOIN pg_attribute ON attrelid = con.confrelid AND attnum = k.num ORDER BY i) AS referenced_columns,
         EXISTS (SELECT FROM pg_constraint u WHERE u.conrelid = con.conrelid AND u.contype IN ('p', 'u')
                 AND u.conkey::int[] @> con.conkey::int[] AND u.conkey::int[] <@ con.conkey::int[]) AS one_to_one
  FROM pg_constraint con
  JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_class r ON r.oid = con.confrelid JOIN pg_namespace rn ON rn.oid = r.relnamespace
  WHERE con.contype = 'f' AND n.nspname = 'public' AND rn.nspname = 'public'
  ORDER BY c.relname, con.conname`);

// Only functions a client role may call: the rest are triggers or
// service-role entry points the web app cannot reach.
const functions = await rows(`
  SELECT p.proname AS name, p.proretset AS returns_set, rt.typname AS return_type,
         p.pronargdefaults AS defaults,
         coalesce(p.proargnames, '{}') AS arg_names,
         coalesce(p.proargmodes::text[], '{}') AS arg_modes,
         ARRAY(SELECT t.typname FROM unnest(coalesce(p.proallargtypes, p.proargtypes::oid[])) WITH ORDINALITY a(oid, i)
               JOIN pg_type t ON t.oid = a.oid ORDER BY i) AS arg_types
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN pg_type rt ON rt.oid = p.prorettype
  WHERE n.nspname = 'public' AND p.prokind = 'f' AND rt.typname <> 'trigger'
    AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  ORDER BY p.proname, p.oid`);
await db.close();

const scalar = {
  bool: 'boolean',
  int2: 'number', int4: 'number', int8: 'number', float4: 'number', float8: 'number', numeric: 'number',
  json: 'Json', jsonb: 'Json',
  text: 'string', varchar: 'string', bpchar: 'string', citext: 'string', uuid: 'string', bytea: 'string',
  date: 'string', time: 'string', timetz: 'string', timestamp: 'string', timestamptz: 'string', interval: 'string',
  void: 'undefined',
};
function tsType(type) {
  if (enumNames.has(type)) return `Database["public"]["Enums"]["${type}"]`;
  const mapped = scalar[type];
  if (!mapped) throw new Error(`No TypeScript mapping for Postgres type ${type}; add one to scalar.`);
  return mapped;
}
const columnType = col => {
  const base = col.is_array ? `${tsType(col.element_type)}[]` : tsType(col.type);
  return col.not_null ? base : `${base} | null`;
};
const indent = (text, depth) => text.split('\n').map(line => line && '  '.repeat(depth) + line).join('\n');
const record = (entries, empty = '{ [_ in never]: never }') =>
  entries.length ? `{\n${entries.join('\n')}\n}` : empty;

const tableNames = [...new Set(columns.map(c => c.relation))];
const tables = tableNames.map(table => {
  const cols = columns.filter(c => c.relation === table);
  const row = cols.map(c => `  ${c.name}: ${columnType(c)}`);
  const insert = cols.map(c => c.generated
    ? `  ${c.name}?: never`
    : `  ${c.name}${!c.not_null || c.has_default || c.identity ? '?' : ''}: ${columnType(c)}`);
  const update = cols.map(c => `  ${c.name}?: ${c.generated ? 'never' : columnType(c)}`);
  const rels = relationships.filter(r => r.relation === table).map(r => indent([
    '{',
    `  foreignKeyName: "${r.name}"`,
    `  columns: [${r.columns.map(c => `"${c}"`).join(', ')}]`,
    `  isOneToOne: ${r.one_to_one}`,
    `  referencedRelation: "${r.referenced}"`,
    `  referencedColumns: [${r.referenced_columns.map(c => `"${c}"`).join(', ')}]`,
    '},',
  ].join('\n'), 1));
  return indent([
    `${table}: {`,
    `  Row: ${indent(record(row), 1).trimStart()}`,
    `  Insert: ${indent(record(insert), 1).trimStart()}`,
    `  Update: ${indent(record(update), 1).trimStart()}`,
    `  Relationships: ${rels.length ? `[\n${indent(rels.join('\n'), 1)}\n  ]` : '[]'}`,
    '}',
  ].join('\n'), 1);
});

function functionEntry(fn) {
  const total = fn.arg_types.length;
  const modes = fn.arg_modes.length ? fn.arg_modes : Array(total).fill('i');
  const inputs = [], outputs = [];
  modes.forEach((mode, i) => {
    const arg = { name: fn.arg_names[i], type: fn.arg_types[i] };
    if (mode === 'i' || mode === 'b') inputs.push(arg);
    if (mode === 'o' || mode === 'b' || mode === 't') outputs.push(arg);
  });
  if (inputs.some(arg => !arg.name)) throw new Error(`${fn.name} has an unnamed argument; PostgREST cannot call it by name.`);
  const firstDefault = inputs.length - fn.defaults;
  // Postgres passes NULL to any argument and the function body decides what
  // it means, so every argument accepts null; a missing required one doesn't
  // compile. Result columns have no NOT NULL either.
  const args = inputs.map((arg, i) => `  ${arg.name}${i >= firstDefault ? '?' : ''}: ${tsType(arg.type)} | null`);
  let returns;
  if (outputs.length) {
    returns = `{\n${outputs.map(arg => `  ${arg.name}: ${tsType(arg.type)} | null`).join('\n')}\n}`;
    if (fn.returns_set) returns += '[]';
  } else {
    returns = tsType(fn.return_type) + (fn.returns_set ? '[]' : '');
  }
  return [`Args: ${record(args, 'Record<PropertyKey, never>')}`, `Returns: ${returns}`];
}
const byName = Map.groupBy(functions, fn => fn.name);
const functionTypes = [...byName].map(([name, overloads]) => {
  const bodies = overloads.map(fn => `{\n${indent(functionEntry(fn).join('\n'), 1)}\n}`);
  return indent(`${name}: ${bodies.join(' | ')}`, 1);
});

const enumTypes = enums.map(e => `  ${e.name}: ${e.labels.map(l => `"${l}"`).join(' | ')}`);

const source = `// Generated by scripts/generate-database-types.mjs from supabase/migrations.
// Do not edit. Regenerate with \`npm run generate:database-types\` at the repository root.

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  public: {
    Tables: ${indent(record(tables), 2).trimStart()}
    Views: { [_ in never]: never }
    Functions: ${indent(record(functionTypes), 2).trimStart()}
    Enums: ${indent(record(enumTypes), 2).trimStart()}
    CompositeTypes: { [_ in never]: never }
  }
}

type PublicSchema = Database["public"]

export type Tables<T extends keyof PublicSchema["Tables"]> = PublicSchema["Tables"][T]["Row"]
export type TablesInsert<T extends keyof PublicSchema["Tables"]> = PublicSchema["Tables"][T]["Insert"]
export type TablesUpdate<T extends keyof PublicSchema["Tables"]> = PublicSchema["Tables"][T]["Update"]
export type Enums<T extends keyof PublicSchema["Enums"]> = PublicSchema["Enums"][T]
export type FunctionName = keyof PublicSchema["Functions"]
export type FunctionArgs<T extends FunctionName> = PublicSchema["Functions"][T]["Args"]
export type FunctionReturns<T extends FunctionName> = PublicSchema["Functions"][T]["Returns"]
`;

if (check) {
  const current = await readFile(output, 'utf8').catch(() => '');
  if (current !== source) {
    console.error('apps/web/src/lib/database.types.ts does not match supabase/migrations.');
    console.error('Run `npm run generate:database-types` and commit the result.');
    process.exitCode = 1;
  } else {
    console.log('apps/web/src/lib/database.types.ts matches supabase/migrations.');
  }
} else {
  await writeFile(output, source);
  console.log('Wrote apps/web/src/lib/database.types.ts.');
}
