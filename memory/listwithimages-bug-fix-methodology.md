---
name: listwithimages_bug_fix_methodology
description: Systematic approach to debugging data flow issues using telemetry, not guessing
metadata:
  type: feedback
---

From ItemsGrid "no items showing" bug fix (2026-07-23):

## Key Learnings

1. Don't guess - trace the entire data flow with telemetry
2. Add console.log at each pipeline stage: SERVER → SERVICE → COMPONENT → RENDER
3. Compare expected vs. actual at each stage

## Systematic Trace Process

**Stage 1: Network Layer**
- DevTools Network tab: Check HTTP status, response size, response body JSON
- Log actual response: `console.log('API response:', response)`

**Stage 2: Service Layer**
- Log what fetch function returns: `console.log('Service returns:', result)`
- Verify keys match expected interface: `console.log('Keys:', Object.keys(result))`

**Stage 3: Component Layer**
- Log what component receives from service: `console.log('Component received:', responseData)`
- Log state updates: `console.log('State after update:', responseData)`

**Stage 4: Render Layer**
- Log extracted data: `console.log('Items to render:', items.length)`
- Check if render logic is extracting correctly: `items?.length > 0`

## Common Break Points (and how to spot them with telemetry)

1. **errorThrower throwing on undefined success**
   - Symptom: API returns 200 but service gets undefined
   - Trace: API response exists (Network tab) but service logs undefined

2. **useRequest not updating data state**
   - Symptom: Service returns correct data but component receives undefined
   - Trace: Service logs show data, but component logs show undefined responseData
   - Fix: Switch to useEffect + useState

3. **Environment variable misconfiguration (MINIO_PUBLIC_URL_BASE)**
   - Symptom: Images fail to load (404 or ERR_CONNECTION_REFUSED)
   - Trace: Network tab shows image URLs pointing to localhost instead of actual domain
   - Fix: Update env var to correct domain

4. **Missing i18n keys**
   - Symptom: Console warnings about missing i18n keys
   - Trace: Browser console shows "[React Intl] Missing message: xxx"
   - Fix: Add key to locale files and register in aggregator

## Why This Matters

Telemetry-based debugging is faster than guessing because:
- Each log pinpoints where data flow breaks
- No need to try random fixes
- Evidence-based decisions
- Can be replayed for future debugging

## Apply This To

- List-with-images feature: itemsGrid.tsx already has telemetry structure
- Any API integration: Add logs at service and component boundaries
- Performance issues: Use telemetry span timing to identify bottlenecks
