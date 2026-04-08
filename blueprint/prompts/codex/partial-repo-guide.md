# Codex Build Guide: Partial Repos
# Read this alongside the main build prompt when the blueprint contains
# items with status "partial", "refactor", or "extend"

## Handling Different Work Types

### status: "not_started"
Standard generation. Create the file from scratch following project patterns.

### status: "extend"
The file ALREADY EXISTS. You must:
1. READ the existing file completely first
2. UNDERSTAND what it already does
3. ADD the missing functionality described in partial_notes
4. PRESERVE everything in the `preserve` array - do NOT break existing behavior
5. Keep the file's existing structure/organization where possible
6. If the existing code has tests, make sure they still pass

Example: A React component exists but is missing responsive breakpoints.
- Read the existing component
- Add the media queries / responsive logic
- Don't change the existing props, state, or data flow
- Match the Figma design for the new responsive states

### status: "refactor"
The file ALREADY EXISTS but uses WRONG PATTERNS. You must:
1. READ the existing file completely - understand its behavior
2. READ what the `preserve` array requires you to keep
3. REWRITE the implementation using correct patterns
4. The external contract (interface, props, route, etc.) stays THE SAME
5. Internal implementation changes to match project standards

Example: A repository using Entity Framework must switch to Dapper + stored procs.
- Read the EF implementation to understand every method
- Keep the IRepository interface identical
- Rewrite every method to call stored procedures via Dapper
- Create the stored procedures that the new code needs
- Keep the DI registration the same (just new class implementing same interface)

### status: "completed"
SKIP THIS ITEM. Do not touch the file. It already meets all criteria.

## Critical Rules for Partial Repos

1. **NEVER delete a file without creating its replacement first**
2. **NEVER break an interface contract** - other code depends on it
3. **Always read existing code before modifying** - understand dependencies
4. **If unsure about a dependency**, err on the side of preserving it
5. **For refactors**, create the stored procedure BEFORE rewriting the repository
   (the new code needs the stored proc to exist)
6. **Test awareness**: if the project has tests, your changes should not break them

## Import / Dependency Awareness

Before modifying any file, check:
- What imports THIS file? (search for the filename in other files)
- What does this file import? (check its import statements)
- Is this file registered in DI? (check Program.cs / Startup.cs)
- Is this file in a route? (check routing config)

If you change a file's exports, you must update all files that import from it.
