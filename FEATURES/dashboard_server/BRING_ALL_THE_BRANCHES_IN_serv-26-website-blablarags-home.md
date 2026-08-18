# Task Prompt for Claude: Consolidate Branches into `serv-26-website-blablarags-home`

## Context & Objective
We need to merge all updates and features from the following branches into a single target branch: `serv-26-website-blablarags-home`.

### Target Branch
- `serv-26-website-blablarags-home`

### Source Branches to Integrate
1. `serv-24-add-shopping-carts`
2. `serv-25-website-shop`
3. `serv-26-website-blablarags-home`

---

## Directives & Instructions for Claude

1. **Checkout & Branch Verification**:
   - Ensure working directory is clean before switching branches (`git status`).
   - Checkout or create the target branch `serv-26-website-blablarags-home`.
   - Ensure local or remote tracking references for `serv-24-add-shopping-carts` and `serv-25-website-shop` are fetched and available.

2. **Integration Strategy (No Data Loss & Conflict Resolution)**:
   - Carefully merge or rebase the changes from `serv-24-add-shopping-carts` and `serv-25-website-shop` into `serv-26-website-blablarags-home`.
   - Pay critical attention to avoid overwriting, loss, or silent regressions of existing logic in any of the three branches.
   - Audit diffs during merge/rebase resolutions line by line to preserve features, utility methods, types, domain models, and documentation across all branches.

3. **Validation & Verification**:
   - Verify that all components, routes, database schemas/repositories, services, and tests introduced across `serv-24`, `serv-25`, and `serv-26` build cleanly and pass without errors.
   - Run available build, lint, and test scripts to confirm application stability.

4. **Final Deliverable**:
   - All combined work must reside cleanly on branch `serv-26-website-blablarags-home`.
