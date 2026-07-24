# TypeScript 7 Migration & Zero-Breakage Compatibility Plan

## Goal Description

Establish a comprehensive validation strategy and auditing framework to evaluate the readiness of `node-nginx-clean` (`server` Fastify backend and `dashboard` React/@umijs/max frontend) for upgrading to TypeScript 7.

This plan details:
1. Architectural risk analysis across both sub-applications.
2. The standalone Python audit engine script designed to detect compiler flag deprecations, framework type conflicts, and syntax breaking changes without modifying source code or executing invasive installs.
3. Step-by-step pre-migration verification procedures to ensure 100% build immutability and runtime stability.

---

## 1. Architectural Stack & Language Choice Rationale

### Why Python for the Audit Script?
We have chosen **Python 3** for the migration validation tool (`scripts/validate_ts7_compatibility.py`) for the following technical reasons:
- **Zero Runtime Side-Effects**: Runs completely outside `node_modules` and Node.js process memory. It inspects configuration files and AST patterns statically without triggering package resolution side-effects or build executions.
- **Cross-Package Parsing**: Efficiently parses JSONC (`tsconfig.json`, `package.json`) and regex-audits source files across multiple workspace directories (`server` and `dashboard`).
- **Automated Report Generation**: Formats findings into Markdown and JSON reports for developer code review.

---

## 2. Cross-Application Compatibility Risk Matrix

| Risk Area | `server` (Fastify / Node 22) | `dashboard` (React 19 / @umijs/max) | Severity & Mitigation Strategy |
|---|---|---|---|
| **TypeScript Base Version** | Current: `^5.7.2` | Current: `^6.0.3` | **Medium**: Align compiler target versions. TS7 strict type inference may surface hidden parameter types. |
| **Module Resolution** | `Bundler` | `bundler` | **Low**: Both applications use `bundler`. Verify package exports under TS7 `nodenext` strict checking. |
| **Decorators Specification** | Standard ES Stage 3 | `experimentalDecorators: true` | **High (Dashboard)**: UmiJS & MobX/AntD legacy components relying on legacy decorators must be verified against Stage 3 decorator rules. |
| **Module Syntax Rules** | `verbatimModuleSyntax: true` | Disabled | **High (Dashboard)**: TS7 strictly enforces explicit `import type { ... }`. Dashboard needs `verbatimModuleSyntax` enabled to prevent type elision bugs. |
| **Framework Type Generation** | Standard Node/Fastify types | `@umijs/max` auto-generated `src/.umi/` types | **Critical (Dashboard)**: UmiJS auto-generates runtime types (`@@/plugin-request/request`). Umi's internal code generator must be dry-run tested against TS7 compiler API. |
| **JSON Imports Syntax** | ES2022 import assertions | ESNext import assertions | **Medium**: Verify any `import data from './file.json' assert { type: 'json' }` uses modern `with { type: 'json' }` syntax. |

---

## 3. Python Audit Script Capabilities

The python validator located at `scripts/validate_ts7_compatibility.py` performs automated non-invasive checks:

1. **`tsconfig.json` Compiler Audit**:
   - Detects deprecated flags (e.g. `importsNotUsedAsValues`, `preserveValueImports`, legacy `target` levels).
   - Identifies mismatches in decorator configuration between `server` and `dashboard`.
   - Checks for `verbatimModuleSyntax` and `skipLibCheck` consistency.

2. **Package & `@types` Dependency Audit**:
   - Scans `package.json` for framework versions (`@umijs/max`, `antd`, `@ant-design/pro-components`, `fastify`, `vitest`).
   - Identifies outdated `@types/*` declarations that could cause ambient type conflicts under TS7.

3. **Source Code AST & Syntax Audit**:
   - Recursively scans `.ts` and `.tsx` source files in `server/src` and `dashboard/src`.
   - Counts explicit `as any` type assertions to measure type safety debt.
   - Detects deprecated JSON import assertions (`assert { type: "json" }`).
   - Identifies legacy class decorators `@decorator` requiring conversion.

---

## 4. Phased Migration Execution Plan

```
+-----------------------------------------------------------------------------------+
|                           PHASE 1: STATIC AUDIT & REPORT                           |
|  1. Run Python validator: `python3 scripts/validate_ts7_compatibility.py`         |
|  2. Review generated Markdown report for tsconfig warnings & deprecated syntax    |
+------------------------------------------+----------------------------------------+
                                           |
                               Audit Clean Pass
                                           |
+------------------------------------------v----------------------------------------+
|                       PHASE 2: DRY-RUN COMPILER VERIFICATION                       |
|  1. Create temporary branch for TS7 testing                                       |
|  2. Test server typecheck: `npx tsc --noEmit`                                     |
|  3. Test dashboard Umi setup: `npx max setup` & `npx tsc --noEmit`                 |
+------------------------------------------+----------------------------------------+
                                           |
                              Zero Type Errors Verified
                                           |
+------------------------------------------v----------------------------------------+
|                       PHASE 3: CI/CD INTEGRATION & LOCK                           |
|  1. Update package.json typescript version across server & dashboard               |
|  2. Execute Vitest test suites (`npm run test`) across both applications          |
|  3. Lock package-lock.json files and commit                                       |
+-----------------------------------------------------------------------------------+
```

---

## 5. Verification Checklist

- [ ] Execute `python3 scripts/validate_ts7_compatibility.py` and inspect report output.
- [ ] Ensure `dashboard/tsconfig.json` is updated to include `verbatimModuleSyntax: true`.
- [ ] Confirm `@umijs/max` internal plugin generator compiles without type error under target TypeScript version.
- [ ] Verify both `server` and `dashboard` unit test suites pass completely (`npm run test`).
