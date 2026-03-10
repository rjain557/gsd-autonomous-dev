# Phase 4a: Execute - Skeleton Pass

Generate type signatures, interfaces, function stubs, class structure, and imports ONLY. No implementation bodies.

## Requirement: {{REQ_ID}}

## Plan

{{PLAN}}

## Instructions

1. Create ALL files listed in the plan.
2. For each file, generate:
   - All import/using statements
   - Type definitions and interfaces
   - Function signatures with parameter types and return types
   - Class structure with property declarations
   - No implementation bodies — use `// FILL` comment as placeholder
3. Use the `--- FILE: path/to/file ---` marker format.
4. Follow the coding conventions provided in the system prompt.

## Example Output

```
--- FILE: src/shared/types/patient.ts ---
export interface Patient {
  id: string;
  firstName: string;
  lastName: string;
  email: string;
  dateOfBirth: string;
}

export interface PatientSearchParams {
  query: string;
  page: number;
  pageSize: number;
}

export interface PatientSearchResult {
  patients: Patient[];
  totalCount: number;
}

--- FILE: src/shared/hooks/usePatientSearch.ts ---
import { useQuery } from '@tanstack/react-query';
import type { PatientSearchParams, PatientSearchResult } from '../types/patient';
import { apiClient } from '../api/client';

export function usePatientSearch(params: PatientSearchParams) {
  // FILL
}

--- FILE: src/web/pages/PatientSearch.tsx ---
import { useState } from 'react';
import { usePatientSearch } from '../../shared/hooks/usePatientSearch';
import type { PatientSearchParams } from '../../shared/types/patient';

export function PatientSearch() {
  // FILL
}
```

Generate the skeleton now. Output ONLY file contents with `--- FILE: path ---` markers.
