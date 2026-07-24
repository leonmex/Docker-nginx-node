#!/usr/bin/env python3
"""
TypeScript 7 Migration & Compatibility Audit Tool

Audits project sub-applications (`server` and `dashboard`) for compatibility
with TypeScript 7 toolchain upgrades. Checks compiler options, framework type
definitions, module resolution settings, and source code syntax patterns.
"""

import json
import os
import re
import sys
from pathlib import Path

# Paths relative to repository root
WORKSPACE_ROOT = Path(__file__).resolve().parent.parent
SERVER_DIR = WORKSPACE_ROOT / "server"
DASHBOARD_DIR = WORKSPACE_ROOT / "dashboard"

# Target TypeScript Compatibility Rules
DEPRECATED_TS_FLAGS = {
    "target": ["es3", "es5"],
    "moduleResolution": ["node10", "classic"],
    "importsNotUsedAsValues": ["remove", "preserve", "error"],
    "preserveValueImports": [True, False],
    "suppressImplicitAnyIndexErrors": [True],
    "noImplicitAny": [False],
}

RECOMMENDED_FLAGS = {
    "strict": True,
    "skipLibCheck": True,
    "forceConsistentCasingInFileNames": True,
}


def load_json_file(file_path: Path):
    """Load JSON or JSONC file safely ignoring single-line comments."""
    if not file_path.exists():
        return None
    try:
        content = file_path.read_text(encoding="utf-8")
        # Strip simple JS comments for JSONC support
        lines = [line for line in content.splitlines() if not line.strip().startswith("//")]
        return json.loads("\n".join(lines))
    except Exception as e:
        return {"_error": str(e)}


def audit_tsconfig(app_name: str, app_dir: Path):
    """Audit tsconfig.json against TypeScript 7 recommendations."""
    issues = []
    tsconfig_path = app_dir / "tsconfig.json"
    data = load_json_file(tsconfig_path)

    if not data or "_error" in data:
        return {
            "status": "ERROR",
            "issues": [f"Failed to parse tsconfig.json: {data.get('_error') if data else 'File missing'}"],
        }

    opts = data.get("compilerOptions", {})

    # Check deprecated flags
    for flag, bad_values in DEPRECATED_TS_FLAGS.items():
        if flag in opts:
            val = opts[flag]
            if str(val).lower() in [str(bv).lower() for bv in bad_values]:
                issues.append(
                    f"Compiler flag '{flag}: {val}' is deprecated or unsupported in modern TypeScript."
                )

    # Check Decorators configuration (dashboard legacy decorators vs stage 3)
    if opts.get("experimentalDecorators") is True:
        issues.append(
            "Flag 'experimentalDecorators: true' detected. TypeScript 7 enforces ECMA Stage 3 decorators by default."
        )

    # Check verbatimModuleSyntax vs type imports
    if not opts.get("verbatimModuleSyntax"):
        issues.append(
            "Flag 'verbatimModuleSyntax' is disabled or missing. TS7 requires strict type-only import syntax."
        )

    # Check module resolution
    mod_res = str(opts.get("moduleResolution", "")).lower()
    if mod_res not in ["bundler", "nodenext"]:
        issues.append(
            f"Module resolution '{opts.get('moduleResolution')}' may cause package import failures in TS7. Recommend 'bundler' or 'nodenext'."
        )

    return {
        "status": "WARNING" if issues else "PASS",
        "compilerOptions": opts,
        "issues": issues,
    }


def audit_package_json(app_name: str, app_dir: Path):
    """Audit dependencies and @types/ compatibility in package.json."""
    pkg_path = app_dir / "package.json"
    data = load_json_file(pkg_path)

    if not data or "_error" in data:
        return {"status": "ERROR", "issues": ["package.json missing or invalid"]}

    deps = data.get("dependencies", {})
    dev_deps = data.get("devDependencies", {})
    all_deps = {**deps, **dev_deps}

    issues = []
    framework_notes = []

    # Check TypeScript version
    ts_version = dev_deps.get("typescript") or deps.get("typescript")
    framework_notes.append(f"Current TypeScript version: {ts_version or 'Not specified'}")

    # Check framework specific risks
    if "@umijs/max" in all_deps:
        framework_notes.append(
            f"@umijs/max ({all_deps['@umijs/max']}): UmiJS auto-generates types in src/.umi/. Requires testing against TS7 compiler API."
        )
    if "react" in all_deps:
        react_ver = all_deps.get("react")
        types_react = all_deps.get("@types/react")
        framework_notes.append(f"React version: {react_ver}, @types/react: {types_react}")
    if "fastify" in all_deps:
        framework_notes.append(f"Fastify version: {all_deps['fastify']}")

    # Check for outdated @types packages that might break under TS7 strict inference
    for pkg, ver in all_deps.items():
        if pkg.startswith("@types/"):
            if "15." in ver or "16." in ver or "17." in ver:
                issues.append(f"Legacy type declaration '{pkg}: {ver}' may cause type checking errors under TS7.")

    return {
        "status": "WARNING" if issues else "PASS",
        "framework_notes": framework_notes,
        "issues": issues,
    }


def audit_source_code(app_name: str, app_dir: Path):
    """Scan source code for syntax patterns affected by TypeScript 7."""
    src_dir = app_dir / ("src" if (app_dir / "src").exists() else "")
    if not src_dir.exists():
        src_dir = app_dir

    deprecated_import_assert = re.compile(r"import\s+.*\s+assert\s*\{\s*type\s*:")
    legacy_decorator_pattern = re.compile(r"@\w+(\(.*\))?\s*\n\s*(class|export class)")
    any_cast_pattern = re.compile(r"\bas\s+any\b")

    import_assert_matches = []
    decorator_matches = []
    any_cast_count = 0

    for root, _, files in os.walk(src_dir):
        if "node_modules" in root or ".umi" in root or "dist" in root:
            continue
        for file in files:
            if file.endswith((".ts", ".tsx")):
                file_path = Path(root) / file
                try:
                    text = file_path.read_text(encoding="utf-8")

                    # Check import assertions vs attributes
                    if deprecated_import_assert.search(text):
                        rel_path = file_path.relative_to(WORKSPACE_ROOT)
                        import_assert_matches.append(str(rel_path))

                    # Check legacy decorators
                    if legacy_decorator_pattern.search(text):
                        rel_path = file_path.relative_to(WORKSPACE_ROOT)
                        decorator_matches.append(str(rel_path))

                    # Count explicit any casts
                    any_cast_count += len(any_cast_pattern.findall(text))

                except Exception:
                    pass

    issues = []
    if import_assert_matches:
        issues.append(
            f"Found {len(import_assert_matches)} files using deprecated 'assert {{ type: \"json\" }}'. Must upgrade to 'with {{ type: \"json\" }}'."
        )
    if decorator_matches:
        issues.append(
            f"Found {len(decorator_matches)} files using experimental class decorators. Verify compatibility with Stage 3 decorators."
        )

    return {
        "status": "WARNING" if issues else "PASS",
        "import_assert_files": import_assert_matches,
        "decorator_files": decorator_matches,
        "any_cast_count": any_cast_count,
        "issues": issues,
    }


def generate_report():
    """Run full validation suite and produce compatibility report."""
    report = {
        "title": "TypeScript 7 Migration & Compatibility Audit",
        "apps": {},
    }

    for app_name, app_dir in [("server", SERVER_DIR), ("dashboard", DASHBOARD_DIR)]:
        tsconfig_res = audit_tsconfig(app_name, app_dir)
        package_res = audit_package_json(app_name, app_dir)
        code_res = audit_source_code(app_name, app_dir)

        report["apps"][app_name] = {
            "tsconfig": tsconfig_res,
            "package": package_res,
            "code": code_res,
        }

    return report


def format_markdown_report(report: dict) -> str:
    """Format report dict into clean Markdown for documentation."""
    lines = []
    lines.append("# TypeScript 7 Migration & Compatibility Audit Report")
    lines.append("")
    lines.append("## Executive Summary")
    lines.append(
        "This report assesses the readiness of `server` and `dashboard` for upgrading to TypeScript 7."
    )
    lines.append("")

    for app_name, results in report["apps"].items():
        lines.append(f"### Application: `{app_name}`")
        lines.append("")

        # tsconfig status
        tc = results["tsconfig"]
        lines.append(f"#### Compiler Configuration (tsconfig.json): Status {tc['status']}")
        if tc["issues"]:
            for issue in tc["issues"]:
                lines.append(f"- Warning: {issue}")
        else:
            lines.append("- Compiler options align with modern TypeScript standards.")
        lines.append("")

        # Package status
        pkg = results["package"]
        lines.append(f"#### Dependencies & Frameworks: Status {pkg['status']}")
        for note in pkg.get("framework_notes", []):
            lines.append(f"- Info: {note}")
        for issue in pkg.get("issues", []):
            lines.append(f"- Warning: {issue}")
        lines.append("")

        # Code scan status
        code = results["code"]
        lines.append(f"#### Source Code Audit: Status {code['status']}")
        lines.append(f"- Explicit `as any` casts detected: {code['any_cast_count']}")
        if code["issues"]:
            for issue in code["issues"]:
                lines.append(f"- Warning: {issue}")
        else:
            lines.append("- Source code syntax clean of deprecated TS patterns.")
        lines.append("")

    return "\n".join(lines)


if __name__ == "__main__":
    rep = generate_report()
    md = format_markdown_report(rep)
    print(md)
