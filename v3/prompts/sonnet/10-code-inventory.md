# Phase: Code Inventory

Scan the existing codebase and build a complete inventory of what exists.

## Scan Instructions
For each interface, identify all existing files and their implementation status:
- REAL: File has complete, functional implementation
- STUB: File exists but has TODO/FILL/NotImplementedException placeholders
- PARTIAL: File has some real code but missing key features

## Output (JSON)
```json
{
  "interfaces": {
    "backend": { "files": [], "real": 0, "stub": 0, "partial": 0 },
    "web": { "files": [], "real": 0, "stub": 0, "partial": 0 },
    "database": { "files": [], "real": 0, "stub": 0, "partial": 0 },
    "mcp": { "files": [], "real": 0, "stub": 0, "partial": 0 }
  },
  "stubs_detected": [{"file": "...", "line": 0, "pattern": "// TODO"}],
  "total_files": 0,
  "total_real": 0,
  "total_stub": 0
}
```

Respond with ONLY the JSON object. No markdown, no explanation.
